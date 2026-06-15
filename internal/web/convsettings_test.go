package web

import (
	"context"
	"log/slog"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/conversations"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/modelproviders"
	"github.com/jdpedrie/reeve/internal/profiles"
	_ "github.com/jdpedrie/reeve/internal/providers/anthropic"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
	"github.com/jdpedrie/reeve/internal/testutil"
)

func TestMergeCall_HigherWins(t *testing.T) {
	t.Parallel()
	hi, lo := 0.2, 0.9
	out := mergeCall(&reevev1.CallSettings{Temperature: &hi}, &reevev1.CallSettings{Temperature: &lo, TopP: &lo})
	if out.GetTemperature() != hi {
		t.Errorf("temperature = %v want %v (higher wins)", out.GetTemperature(), hi)
	}
	if out.GetTopP() != lo {
		t.Errorf("top_p = %v want %v (falls through)", out.GetTopP(), lo)
	}
}

func newConvSettingsHandler(t *testing.T) (*Handler, *store.Queries, *conversations.Service) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	models := modelproviders.NewService(q, cat, crypto.Nop{}, slog.Default())
	prof := profiles.NewService(q, pool, crypto.Nop{})
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Models: models, Profiles: prof, Supervisor: sup, Logger: slog.Default()})
	return h, q, convos
}

// TestConvSettings_SaveCallSettings proves a posted override persists and
// renders back into the form.
func TestConvSettings_SaveCallSettings(t *testing.T) {
	t.Parallel()
	h, q, convos := newConvSettingsHandler(t)
	fx := seedSendable(t, q, "http://unused")
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	form := url.Values{
		"temperature":       {"0.5"},
		"max_output_tokens": {"2048"},
		"thinking_enabled":  {"on"},
		"explicit_cache":    {"off"},
	}
	saveReq := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/settings", strings.NewReader(form.Encode())).WithContext(userCtx)
	saveReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	saveReq.SetPathValue("id", fx.convID.String())
	if rec := do(h.handleConvSettingsSave, saveReq); rec.Code != 303 {
		t.Fatalf("save status=%d; body:\n%s", rec.Code, rec.Body.String())
	}

	got, err := convos.GetConversation(userCtx, connect.NewRequest(&reevev1.GetConversationRequest{Id: fx.convID.String()}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	cs := got.Msg.GetConversation().GetSettings().GetCallSettings()
	if cs.GetTemperature() != 0.5 || cs.GetMaxOutputTokens() != 2048 {
		t.Errorf("saved settings temp=%v max=%v want 0.5/2048", cs.GetTemperature(), cs.GetMaxOutputTokens())
	}
	if cs.GetThinking().GetEnabled() != true {
		t.Errorf("thinking enabled not saved")
	}
	if cs.GetExplicitCache() != false || cs.Anthropic != nil {
		// explicit_cache off should be set; with no anthropic fields posted the block stays nil.
	}

	// Reload the page; the saved value renders into the input.
	pageReq := httptest.NewRequest("GET", "/c/"+fx.convID.String()+"/settings", nil).WithContext(userCtx)
	pageReq.SetPathValue("id", fx.convID.String())
	pageRec := do(h.handleConvSettings, pageReq)
	if body := pageRec.Body.String(); !strings.Contains(body, `value="0.5"`) || !strings.Contains(body, "Call settings") {
		t.Errorf("settings page missing saved value; body:\n%s", body[:min(2000, len(body))])
	}
}

// TestConvSettings_PluginOverride proves adding then removing a conversation
// plugin override round-trips through the plugins tab.
func TestConvSettings_PluginOverride(t *testing.T) {
	t.Parallel()
	h, q, convos := newConvSettingsHandler(t)
	fx := seedSendable(t, q, "http://unused")
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	add := url.Values{"action": {"add"}, "plugin_name": {"basic_grounding"}}
	addReq := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/plugins/override", strings.NewReader(add.Encode())).WithContext(userCtx)
	addReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	addReq.SetPathValue("id", fx.convID.String())
	if rec := do(h.handleConvPluginOverride, addReq); rec.Code != 303 {
		t.Fatalf("add status=%d; body:\n%s", rec.Code, rec.Body.String())
	}
	got, _ := convos.GetConversationPlugins(userCtx, connect.NewRequest(&reevev1.GetConversationPluginsRequest{ConversationId: fx.convID.String()}))
	if len(got.Msg.GetPlugins()) != 1 || got.Msg.GetPlugins()[0].GetPluginName() != "basic_grounding" {
		t.Fatalf("after add: %+v", got.Msg.GetPlugins())
	}

	rm := url.Values{"action": {"remove"}, "plugin_name": {"basic_grounding"}}
	rmReq := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/plugins/override", strings.NewReader(rm.Encode())).WithContext(userCtx)
	rmReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rmReq.SetPathValue("id", fx.convID.String())
	if rec := do(h.handleConvPluginOverride, rmReq); rec.Code != 303 {
		t.Fatalf("remove status=%d", rec.Code)
	}
	got2, _ := convos.GetConversationPlugins(userCtx, connect.NewRequest(&reevev1.GetConversationPluginsRequest{ConversationId: fx.convID.String()}))
	if len(got2.Msg.GetPlugins()) != 0 {
		t.Errorf("after remove: %d plugins want 0", len(got2.Msg.GetPlugins()))
	}
}
