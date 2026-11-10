package web

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
)

// --- the run charts ---

func TestTurnSamples_GrowthCostAndCacheMiss(t *testing.T) {
	t.Parallel()
	i32 := func(v int32) *int32 { return &v }
	f64 := func(v float64) *float64 { return &v }
	reply := func(in, read, out int32, cost *float64) *psmithv1.Message {
		return &psmithv1.Message{Role: psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT, Usage: &psmithv1.MessageUsage{InputTokens: i32(in), CacheReadTokens: i32(read), OutputTokens: i32(out), TotalCostUsd: cost}}
	}
	msgs := []*psmithv1.Message{
		{Role: psmithv1.MessageRole_MESSAGE_ROLE_USER},
		reply(5000, 0, 200, f64(0.01)),   // first reply: nothing to hit yet
		reply(500, 6000, 300, f64(0.02)), // cached: prompt is input + read
		reply(9000, 100, 400, nil),       // missed on a large prompt, unpriced
	}
	s := turnSamples(msgs)
	if len(s) != 3 || s[0].Tokens != 5200 || s[1].Tokens != 6800 || s[2].Tokens != 9400 {
		t.Fatalf("samples = %+v", s)
	}
	if s[0].CacheMiss || s[1].CacheMiss || !s[2].CacheMiss || s[2].Priced {
		t.Errorf("miss/priced wrong: %+v", s)
	}
	ch := runCharts(s, 8000)
	if ch == nil || ch.Replies != 3 || !ch.Warn || len(ch.Bars) != 2 || ch.AnyMiss {
		t.Fatalf("charts = %+v", ch)
	}
	if runCharts(s[:1], 0) != nil {
		t.Error("one reply drew a chart")
	}
}

// The Context tab draws both charts and says which models it can't price,
// from the replies on the page.
func TestContextTab_RunChartsAndUnpriced(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	conv, _ := f.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.conv}))
	cx := uuid.MustParse(conv.Msg.GetActiveContext().GetId())
	model := f.fx.modelID
	var parent *uuid.UUID
	for i, price := range []string{"0.01", "0.02", ""} {
		var cost pgtype.Numeric
		if price != "" {
			_ = cost.Scan(price)
		}
		uid, aid := uuid.New(), uuid.New()
		if _, err := f.q.CreateMessage(f.ctx, store.CreateMessageParams{ID: uid, ContextID: cx, ParentID: parent, Role: "user", Content: "q"}); err != nil {
			t.Fatal(err)
		}
		in, out := int32(1000*(i+1)), int32(100)
		if _, err := f.q.CreateAssistantMessageWithUsage(f.ctx, store.CreateAssistantMessageWithUsageParams{ID: aid, ContextID: cx, ParentID: &uid, Role: "assistant", Content: "a",
			ProviderID: &f.fx.providerID, ModelID: &model, InputTokens: &in, OutputTokens: &out, TotalCostUsd: cost}); err != nil {
			t.Fatal(err)
		}
		parent = &aid
		time.Sleep(2 * time.Millisecond)
	}
	if _, err := f.q.UpdateContextCurrentLeaf(f.ctx, store.UpdateContextCurrentLeafParams{ID: cx, CurrentLeafMessageID: parent}); err != nil {
		t.Fatal(err)
	}
	body := f.get(t, f.h.handleConversation, "/c/"+f.conv, nil).Body.String()
	for _, want := range []string{"Context over this run", "3 replies", "Cost per reply", "No pricing for Claude Fake, so the cost leaves those turns out."} {
		if !strings.Contains(body, want) {
			t.Errorf("context tab lacks %q", want)
		}
	}
}

// --- the Plugins tab ---

func TestPluginsTab_EmptyState(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	body := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=plugins", nil).Body.String()
	if !strings.Contains(body, "No plugins are running for this conversation.") || strings.Contains(body, "0 plugins") {
		t.Error("an empty pipeline reads \"0 plugins\" instead of saying nothing runs")
	}
	if strings.Contains(body, "Clear conversation changes") {
		t.Error("Clear shows with nothing to clear")
	}
}

func TestPluginsTab_ClearConversationChanges(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	if rec := f.post(t, f.h.handleConvPluginsSave, "/", url.Values{"add": {"basic_grounding"}}, nil); rec.Code != 303 {
		t.Fatalf("add: %d", rec.Code)
	}
	body := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=plugins", nil).Body.String()
	if !strings.Contains(body, `name="clear"`) || !strings.Contains(body, "Clear conversation changes") {
		t.Fatal("no Clear conversation changes with an override in place")
	}
	if rec := f.post(t, f.h.handleConvPluginsSave, "/", url.Values{"clear": {"1"}, "add": {""}}, nil); rec.Code != 303 {
		t.Fatalf("clear: %d %s", rec.Code, rec.Body.String())
	}
	got, err := f.h.convos.GetConversationPlugins(f.ctx, connect.NewRequest(&psmithv1.GetConversationPluginsRequest{ConversationId: f.conv}))
	if err != nil || len(got.Msg.GetPlugins()) != 0 {
		t.Errorf("overrides after clear = %v (%v)", got.Msg.GetPlugins(), err)
	}
}

// --- a list setting ---

func (f inspFx) packs(t *testing.T) []map[string]any {
	t.Helper()
	got, err := f.h.convos.GetConversationPlugins(f.ctx, connect.NewRequest(&psmithv1.GetConversationPluginsRequest{ConversationId: f.conv}))
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range got.Msg.GetPlugins() {
		if p.GetPluginName() == "context_packs" {
			var cfg struct {
				Packs []map[string]any `json:"packs"`
			}
			_ = json.Unmarshal(p.GetConfig(), &cfg)
			return cfg.Packs
		}
	}
	t.Fatal("context_packs isn't on the conversation")
	return nil
}

func TestPluginConfig_ListEditor(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	if rec := f.post(t, f.h.handleConvPluginsSave, "/", url.Values{"add": {"context_packs"}}, nil); rec.Code != 303 {
		t.Fatalf("add plugin: %d", rec.Code)
	}
	pv := map[string]string{"name": "context_packs"}
	page := f.get(t, f.h.handlePluginConfig, "/c/"+f.conv+"/plugin/context_packs", pv).Body.String()
	if strings.Contains(page, "Settings (JSON)") || !strings.Contains(page, `name="add_row" value="packs"`) || !strings.Contains(page, "None yet.") {
		t.Fatal("Context packs' packs still edit as JSON, not rows")
	}

	// Add saves what's typed and comes back with a blank row open.
	rec := f.post(t, f.h.handlePluginConfigSave, "/", url.Values{"lst_packs_n": {"0"}, "cfg_announce_to_model": {"true"}, "add_row": {"packs"}}, pv)
	if loc := rec.Header().Get("Location"); rec.Code != 303 || loc != "/c/"+f.conv+"/plugin/context_packs?add=packs" {
		t.Fatalf("add row: %d %q", rec.Code, loc)
	}
	page = f.get(t, f.h.handlePluginConfig, "/c/"+f.conv+"/plugin/context_packs?add=packs", pv).Body.String()
	if !strings.Contains(page, `name="lst_packs_0_name"`) || !strings.Contains(page, `<details open`) {
		t.Fatal("the added row isn't drawn open")
	}

	form := url.Values{"lst_packs_n": {"2"}, "cfg_announce_to_model": {"false"},
		"lst_packs_0_id": {"p1"}, "lst_packs_0_name": {"Swift style guide"}, "lst_packs_0_body": {"Views stay small."},
		"lst_packs_1_id": {"p2"}, "lst_packs_1_name": {""}, "lst_packs_1_body": {""}}
	if rec := f.post(t, f.h.handlePluginConfigSave, "/", form, pv); rec.Code != 303 {
		t.Fatalf("save: %d %s", rec.Code, rec.Body.String())
	}
	packs := f.packs(t)
	if len(packs) != 1 || packs[0]["id"] != "p1" || packs[0]["name"] != "Swift style guide" || packs[0]["body"] != "Views stay small." {
		t.Fatalf("packs = %v (a blank row should drop)", packs)
	}

	// Delete drops the row and stays on the page.
	rec = f.post(t, f.h.handlePluginConfigSave, "/", url.Values{"lst_packs_n": {"1"}, "lst_packs_0_id": {"p1"}, "lst_packs_0_name": {"Swift style guide"}, "del": {"packs.0"}}, pv)
	if rec.Code != 303 || rec.Header().Get("Location") != "/c/"+f.conv+"/plugin/context_packs" || len(f.packs(t)) != 0 {
		t.Fatalf("delete: %d %q %v", rec.Code, rec.Header().Get("Location"), f.packs(t))
	}

	// Paste replaces the rows and gives each an id; a bad paste keeps the
	// text and says why.
	rec = f.post(t, f.h.handlePluginConfigSave, "/", url.Values{"lst_packs_n": {"0"}, "paste": {"packs"}, "paste_packs": {"not json"}}, pv)
	if body := rec.Body.String(); rec.Code != 422 || !strings.Contains(body, "Expected a JSON array of rows.") || !strings.Contains(body, "not json") {
		t.Fatalf("bad paste: %d", rec.Code)
	}
	rec = f.post(t, f.h.handlePluginConfigSave, "/", url.Values{"lst_packs_n": {"0"}, "paste": {"packs"}, "paste_packs": {`{"packs":[{"name":"A","body":"x"}]}`}}, pv)
	if packs := f.packs(t); rec.Code != 303 || len(packs) != 1 || packs[0]["name"] != "A" || packs[0]["id"] == "" {
		t.Fatalf("paste: %d %v", rec.Code, packs)
	}
}

// --- a stopped summary ---

func TestReview_StoppedSummary(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	conv, _ := f.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.conv}))
	cx := uuid.MustParse(conv.Msg.GetActiveContext().GetId())
	uid, sid := uuid.New(), uuid.New()
	if _, err := f.q.CreateMessage(f.ctx, store.CreateMessageParams{ID: uid, ContextID: cx, Role: "user", Content: "q"}); err != nil {
		t.Fatal(err)
	}
	model := f.fx.modelID
	if _, err := f.q.CreateAssistantMessageWithUsage(f.ctx, store.CreateAssistantMessageWithUsageParams{ID: sid, ContextID: cx, ParentID: &uid, Role: "compression_summary", Content: "**Topic.** Paging, and", ProviderID: &f.fx.providerID, ModelID: &model}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.q.UpdateContextCurrentLeaf(f.ctx, store.UpdateContextCurrentLeafParams{ID: cx, CurrentLeafMessageID: &sid}); err != nil {
		t.Fatal(err)
	}
	body := f.get(t, f.h.handleConversation, "/c/"+f.conv, nil).Body.String()
	if !strings.Contains(body, "Summary ready for review") {
		t.Fatal("a finished summary isn't up for review")
	}
	rid, _ := uuid.NewV7()
	if _, err := f.q.CreateStreamRun(context.Background(), store.CreateStreamRunParams{ID: rid, ConversationID: uuid.MustParse(f.conv), ContextID: cx, ModelID: model, Status: "running", Purpose: string(stream.PurposeCompression)}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.q.FinalizeStreamRun(context.Background(), store.FinalizeStreamRunParams{ID: rid, Status: "cancelled", ResultMessageID: &sid}); err != nil {
		t.Fatal(err)
	}
	body = f.get(t, f.h.handleConversation, "/c/"+f.conv, nil).Body.String()
	if !strings.Contains(body, "Summary stopped") || !strings.Contains(body, "You stopped the summary before it finished.") || strings.Contains(body, "Summary ready for review") {
		t.Error("a summary Esc stopped reads as ready for review")
	}
}

// --- the title in the info view ---

func TestInfo_TitleSaveError(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	if err := f.q.SetConversationArchived(f.ctx, store.SetConversationArchivedParams{ID: uuid.MustParse(f.conv), Archived: true}); err != nil {
		t.Fatal(err)
	}
	rec := f.post(t, f.h.handleTitleSave, "/", url.Values{"title": {"Paging decision"}}, nil)
	body := rec.Body.String()
	if rec.Code != 422 || !strings.Contains(body, `id="info-title-err"`) || !strings.Contains(body, "Couldn’t save the title.") {
		t.Fatalf("failed save: code %d, no error under the title", rec.Code)
	}
	if !strings.Contains(body, `value="Paging decision"`) || !strings.Contains(body, `aria-invalid="true"`) {
		t.Error("the typed title is lost")
	}
}

// Generation fails only on server faults a test can't cause, so this
// drives the shared path with generation's message.
func TestInfo_TitleGenerateErrorRenders(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	rec := f.post(t, func(w http.ResponseWriter, r *http.Request) {
		f.h.renderTitleError(w, r, f.conv, "", "Couldn’t generate a title. Timed out.")
	}, "/", nil, nil)
	if body := rec.Body.String(); rec.Code != 422 || !strings.Contains(body, "Couldn’t generate a title. Timed out.") || !strings.Contains(body, "Generate title") {
		t.Errorf("generate error: %d", rec.Code)
	}
}

// --- locked call settings ---

func TestLockRows(t *testing.T) {
	t.Parallel()
	one := 1.0
	rows := []setRowVM{{Name: "temperature", Label: "Temperature", Value: "0.7", Dirty: true}, {Name: "oai_seed", Value: "4"}, {Name: "top_p"}}
	lockRows(rows, &psmithv1.ModelConstraints{Temperature: &psmithv1.Range{LockedAt: &one}, Unsupported: []string{"openai.seed"}}, "GPT-5")
	if rows[0].Sub() != "Locked at 1.0 by GPT-5" || rows[0].Value != "1.0" || rows[0].Dirty {
		t.Errorf("temperature = %+v", rows[0])
	}
	if rows[1].Sub() != "Not supported by GPT-5" || rows[1].Value != "" {
		t.Errorf("seed = %+v", rows[1])
	}
	if rows[2].Locked != "" {
		t.Error("an unconstrained row locked")
	}
}

func TestSettingsTab_LockedTemperature(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	if _, err := f.q.UpsertUserModel(f.ctx, store.UpsertUserModelParams{UserModelProviderID: f.fx.providerID, ModelID: "claude-opus-4-8", DisplayName: "Claude Opus 4.8",
		MetadataSource: "manual", MetadataSnapshotAt: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	f.h.setConversationModel(f.ctx, f.conv, f.fx.providerID.String(), "claude-opus-4-8")
	body := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=settings", nil).Body.String()
	i := strings.Index(body, `id="cs-temperature"`)
	if i < 0 {
		t.Fatal("no temperature row")
	}
	tag := body[strings.LastIndex(body[:i], "<"):][:300]
	if !strings.Contains(body, "Locked at 1.0 by Claude Opus 4.8") || !strings.Contains(tag, "disabled") || !strings.Contains(tag, `value="1.0"`) {
		t.Errorf("a locked temperature is editable: %s", tag)
	}
}

// --- the model picker without a profile model ---

func TestModelPicker_NoProfileModelChecksTheSendsModel(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	body := f.get(t, f.h.handleModelPicker, "/c/"+f.conv+"/model", nil).Body.String()
	i := strings.Index(body, "Use the profile's model")
	if i < 0 {
		t.Fatal("no profile row")
	}
	row := body[strings.LastIndex(body[:i], "<button"):i]
	if strings.Contains(row, "aria-current") || !strings.Contains(row, "disabled") {
		t.Errorf("with no profile model the profile row is checked or offered: %s", row)
	}
	j := strings.Index(body, `data-pick-name="Claude Fake"`)
	if j < 0 {
		t.Fatal("no Claude Fake row")
	}
	fake := body[strings.LastIndex(body[:j], "<button"):j]
	if !strings.Contains(fake, `aria-current="true"`) {
		t.Errorf("the model the send uses isn't checked: %s", fake)
	}
}
