package web

import (
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"

	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/conversations"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
	"github.com/jdpedrie/psmith/server/testutil"
)

func TestParseElicitFields(t *testing.T) {
	t.Parallel()
	schema := json.RawMessage(`{
		"type": "object",
		"properties": {
			"api_key": {"type": "string", "format": "password", "title": "API Key"},
			"count":   {"type": "integer"},
			"enabled": {"type": "boolean"},
			"name":    {"type": "string"}
		}
	}`)
	fields := parseElicitFields(schema)
	// Sorted by name: api_key, count, enabled, name.
	want := []elicitField{
		{Name: "api_key", Label: "API Key", Type: "password"},
		{Name: "count", Label: "count", Type: "number"},
		{Name: "enabled", Label: "enabled", Type: "checkbox"},
		{Name: "name", Label: "name", Type: "text"},
	}
	if len(fields) != len(want) {
		t.Fatalf("got %d fields, want %d: %+v", len(fields), len(want), fields)
	}
	for i, f := range fields {
		if f != want[i] {
			t.Errorf("field %d = %+v, want %+v", i, f, want[i])
		}
	}
}

// The elicitation card lands in the composer's place with a field per
// schema property, a password kept as a password, and both answers.
func TestElicitCardRender(t *testing.T) {
	t.Parallel()
	payload := []byte(`{"elicitation_id":"eid1","message":"Enter your key","requested_schema":{"type":"object","properties":{"api_key":{"type":"string","format":"password","title":"API Key"}},"required":["api_key"]}}`)
	out := elicitEvent(context.Background(), "conv1", payload, "create_issue")
	for _, want := range []string{
		"Enter your key",
		`name="field_api_key"`,
		`type="password"`,
		`hx-post="/c/conv1/elicit/eid1"`,
		`name="action" value="accept"`,
		`name="action" value="decline"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("elicit card missing %q\ngot: %s", want, out)
		}
	}
}

// TestElicitRespond_OwnershipNotFound proves the respond handler refuses a
// conversation the caller doesn't own (no panic, clean 404).
func TestElicitRespond_OwnershipNotFound(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Supervisor: sup, Logger: slog.Default()})

	userCtx, _ := seedUserCtx(t, q)
	cid, eid := uuid.New().String(), uuid.New().String()
	req := httptest.NewRequest("POST", "/c/"+cid+"/elicit/"+eid+"?action=decline", nil).WithContext(userCtx)
	req.SetPathValue("id", cid)
	req.SetPathValue("eid", eid)
	rec := do(h.handleElicitRespond, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status=%d want 404", rec.Code)
	}
}

// The card names who is asking when the stream says.
func TestElicitCard_NamesTheSource(t *testing.T) {
	t.Parallel()
	payload := []byte(`{"elicitation_id":"e","message":"Which repo?","requested_schema":{"properties":{"repo":{"type":"string"}}},"source":"GitHub","tool":"create_issue"}`)
	out := elicitEvent(context.Background(), "c", payload, "")
	if !strings.Contains(out, "GitHub needs input") || !strings.Contains(out, "create_issue") {
		t.Errorf("card doesn't name the source and tool:\n%s", out)
	}
}

// A plugin action in a reply only works when the fragment names its plugin;
// without one, the row shows but does nothing.
func TestFragments_PluginActionsNeedAnAuthor(t *testing.T) {
	t.Parallel()
	props := []byte(`{"items":[{"label":"Arm it","value":"A","action":"plugin:arm?id=x"}]}`)
	cards := []byte(`{"items":[{"title":"Runbook","action":"plugin:arm?id=runbook"}]}`)
	owned := fragmentsOf([]*psmithv1.UIFragment{{Component: "choice_list", Props: props, Plugin: "context_packs"}, {Component: "card_list", Props: cards, Plugin: "context_packs"}})
	if owned[0].Choices[0].Action != "plugin:arm?id=x" || owned[1].Cards[0].Action != "plugin:arm?id=runbook" {
		t.Fatalf("owned fragment lost its actions: %+v", owned)
	}
	orphan := fragmentsOf([]*psmithv1.UIFragment{{Component: "choice_list", Props: props}, {Component: "card_list", Props: cards}})
	if orphan[0].Choices[0].Action != "" || orphan[1].Cards[0].Action != "" {
		t.Errorf("orphan fragment kept a plugin action: %+v", orphan)
	}

	out := renderString(t, fragment(msgItem{ConvID: "c1"}, owned[1]))
	for _, want := range []string{`<input type="hidden" name="plugin" value="context_packs">`, `<button class="card card-act" type="submit" name="choice" value="plugin:arm?id=runbook">`, `hx-post="/c/c1/choice"`} {
		if !strings.Contains(out, want) {
			t.Errorf("card missing %q\n%s", want, out)
		}
	}
}
