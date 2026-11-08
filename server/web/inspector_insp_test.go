package web

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/store"
)

// --- pure parts ---

func TestBuildSetRows_Provenance(t *testing.T) {
	t.Parallel()
	f := func(v float64) *float64 { return &v }
	i := func(v int32) *int32 { return &v }
	b := func(v bool) *bool { return &v }
	own := &psmithv1.CallSettings{Temperature: f(0.7)}
	layers := []layer{
		{"From the Demo profile", &psmithv1.CallSettings{Temperature: f(1), TopP: f(0.95)}},
		{"From Opus", &psmithv1.CallSettings{MaxOutputTokens: i(16384), TopP: f(0.5)}},
		{"From the Anthropic provider", &psmithv1.CallSettings{StopSequences: []string{"a", "b"}, Anthropic: &psmithv1.AnthropicExtras{CacheEnabled: b(true)}}},
	}
	rows, extras, title := buildSetRows(own, layers, nil, &psmithv1.ProfileDefaults{IncludeThinkingInHistory: b(true)}, "Demo", "anthropic")
	by := map[string]setRowVM{}
	for _, r := range append(rows, extras...) {
		by[r.Name] = r
	}
	cases := []struct{ name, sub, placeholder string }{
		{"temperature", "Set here. Inherits 1.0", ""},
		{"top_p", "From the Demo profile", "0.95"}, // the profile outranks the model
		{"max_output_tokens", "From Opus", "16,384"},
		{"top_k", "Not set at any layer", "Default"},
		{"stop_sequences", "From the Anthropic provider", "2 inherited"},
		{"include_thinking_in_history", "From the Demo profile", ""},
		{"anth_cache_enabled", "From the Anthropic provider", ""},
		{"anth_cache_ttl", "Not set at any layer", ""},
	}
	for _, c := range cases {
		r, ok := by[c.name]
		if !ok {
			t.Errorf("%s: missing row", c.name)
			continue
		}
		if r.Sub() != c.sub {
			t.Errorf("%s: sub = %q want %q", c.name, r.Sub(), c.sub)
		}
		if c.placeholder != "" && r.Placeholder != c.placeholder {
			t.Errorf("%s: placeholder = %q want %q", c.name, r.Placeholder, c.placeholder)
		}
	}
	if title != "anthropic" {
		t.Errorf("extras title = %q", title)
	}
	if got := by["include_thinking_in_history"].Options[0].Label; got != "Inherit (on)" {
		t.Errorf("thinking in history inherit = %q", got)
	}
	if got := by["anth_cache_ttl"].Options[0].Label; got != "Inherit (5 min)" {
		t.Errorf("cache lifetime falls back to the driver default, got %q", got)
	}
	dirty := by["temperature"]
	dirty.Dirty = true
	if dirty.Sub() != "Set here, unsaved. Inherits 1.0" {
		t.Errorf("dirty sub = %q", dirty.Sub())
	}
	if _, extras, _ := buildSetRows(nil, nil, nil, nil, "Demo", "google"); len(extras) != 1 || extras[0].Name != "goog_candidate_count" {
		t.Errorf("google extras = %+v", extras)
	}
}

func TestFitOf(t *testing.T) {
	t.Parallel()
	if f := fitOf(82140, 200000); !f.OK || f.Label != "Fits its 200k window" {
		t.Errorf("fits = %+v", f)
	}
	if f := fitOf(82140, 40960); f.OK || f.Label != "82,140 of a 40,960 window" {
		t.Errorf("too big = %+v", f)
	}
	if f := fitOf(1, 0); !f.OK {
		t.Errorf("unknown window should not block: %+v", f)
	}
}

func TestSummaryUsage(t *testing.T) {
	t.Parallel()
	cost := 0.0321
	n := func(v int32) *int32 { return &v }
	got := summaryUsage(&psmithv1.MessageUsage{InputTokens: n(17240), CacheReadTokens: n(64900), OutputTokens: n(1684), TotalCostUsd: &cost})
	if want := "In 82,140 (64,900 cached) · out 1,684 · $0.0321"; got != want {
		t.Errorf("usage = %q want %q", got, want)
	}
	if summaryUsage(nil) != "" {
		t.Error("nil usage should be empty")
	}
}

func TestApplyPluginForm(t *testing.T) {
	t.Parallel()
	resolved := []*psmithv1.ResolvedPipelineEntry{
		{PluginName: "memory", Ordinal: 1, Source: psmithv1.ResolvedPipelineSource_RESOLVED_PIPELINE_SOURCE_PROFILE},
		{PluginName: "mcp", Ordinal: 2, Source: psmithv1.ResolvedPipelineSource_RESOLVED_PIPELINE_SOURCE_PROFILE},
		{PluginName: "brave", Ordinal: 5, Source: psmithv1.ResolvedPipelineSource_RESOLVED_PIPELINE_SOURCE_CONVERSATION},
	}
	overrides := []*psmithv1.ConversationPlugin{
		{PluginName: "brave", Ordinal: 5},
		{PluginName: "lettered", Ordinal: 3, Disabled: true},
	}
	out := applyPluginForm(resolved, overrides, url.Values{
		"on_memory": {"true"}, "on_mcp": {"false"}, "on_lettered": {"true"}, "add": {"imagegen"},
	})
	names := map[string]*psmithv1.ConversationPlugin{}
	for _, p := range out {
		names[p.GetPluginName()] = p
	}
	if p := names["mcp"]; p == nil || !p.GetDisabled() || p.GetOrdinal() != 2 {
		t.Errorf("mcp should be switched off at its ordinal: %+v", p)
	}
	if _, ok := names["lettered"]; ok {
		t.Error("switching an inherited plugin back on should drop its override")
	}
	if _, ok := names["memory"]; ok {
		t.Error("an inherited plugin left on needs no override")
	}
	if p := names["imagegen"]; p == nil || p.GetDisabled() || p.GetOrdinal() != 6 {
		t.Errorf("added plugin = %+v", p)
	}
	out = applyPluginForm(resolved, overrides, url.Values{"remove": {"brave"}})
	for _, p := range out {
		if p.GetPluginName() == "brave" {
			t.Error("remove left the conversation plugin")
		}
	}
}

func TestPanelParts(t *testing.T) {
	t.Parallel()
	cards, _ := json.Marshal(map[string]any{"items": []map[string]any{
		{"title": "A", "badges": []string{"Sends next"}, "action": "plugin:disarm?id=a"},
		{"title": "B", "action": "plugin:arm?id=b"},
		{"title": "C", "badges": []string{"Delivered"}},
	}})
	parts := panelParts([]*psmithv1.UIFragment{
		{Component: "text", Props: []byte(`{"text":"**hi**"}`)},
		{Component: "card_list", Props: cards},
		{Component: "mystery", Props: []byte(`{"x":1}`)},
	})
	if len(parts) != 3 || parts[0].Kind != "text" || !strings.Contains(parts[0].HTML, "<strong>hi</strong>") {
		t.Fatalf("parts = %+v", parts)
	}
	c := parts[1].Cards
	if !c[0].Chosen || c[0].Action != "disarm" || c[0].Params["id"] != "a" {
		t.Errorf("chosen card = %+v", c[0])
	}
	if c[1].Chosen || actionValue(c[1]) != "arm?id=b" {
		t.Errorf("open card = %+v value %q", c[1], actionValue(c[1]))
	}
	if c[2].Action != "" {
		t.Errorf("static card has an action: %+v", c[2])
	}
	if parts[2].Kind != "raw" {
		t.Errorf("unknown component kind = %q", parts[2].Kind)
	}
}

func TestBuildPicker(t *testing.T) {
	t.Parallel()
	p := buildPicker(boardPickerData(), "", capsVM{ToolUse: true}, "Demo")
	if len(p.Favorites) != 2 || len(p.Groups) != 3 {
		t.Fatalf("favorites=%d groups=%d", len(p.Favorites), len(p.Groups))
	}
	if !strings.Contains(p.Foot, "Demo needs tool use") {
		t.Errorf("foot = %q", p.Foot)
	}
	q := buildPicker(boardPickerData(), "gemini", capsVM{}, "Demo")
	if len(q.Groups) != 1 || len(q.Groups[0].Models) != 1 || q.Foot != "Applies from the next message." {
		t.Errorf("filtered = %+v", q)
	}
	if got := badges(capsVM{Vision: true, ToolUse: true, Thinking: true}); strings.Join(got, ",") != "Vision,Tools,Thinking" {
		t.Errorf("badges = %v", got)
	}
	if needs([]string{"tool use", "vision"}) != "Needs tool use and vision" {
		t.Error("needs wording")
	}
}

func TestContextRowsHelpers(t *testing.T) {
	t.Parallel()
	day := func(d int) *timestamppb.Timestamp {
		return timestamppb.New(time.Date(2026, 10, d, 9, 0, 0, 0, time.UTC))
	}
	c1 := &psmithv1.Context{Id: "1", CreatedAt: day(22), CumulativeCostUsd: 1.92}
	c2 := &psmithv1.Context{Id: "2", CreatedAt: day(30), ParentContextId: ptr("1"), LastMessageTotalTokens: 82140}
	r1, r2 := ctxRow(1, c1, c2, false, 46), ctxRow(2, c2, nil, true, 18)
	if r1.Detail != "46 turns · compressed Oct 30 · $1.92" {
		t.Errorf("r1 detail = %q", r1.Detail)
	}
	if r2.Detail != "From a summary · 18 turns · 82k" || r2.Summary != "Context 2 · active · 18 turns" {
		t.Errorf("r2 = %q / %q", r2.Detail, r2.Summary)
	}
	rows := []ctxRowVM{r1, r2}
	if got := newestFirst(rows); got[0].ID != "2" {
		t.Errorf("newest first = %v", got)
	}
	if got := deleteContextNote(rows, r1); got != "Its 46 turns are deleted for good. The summary that started Context 2 stays." {
		t.Errorf("delete note = %q", got)
	}
	if got := deleteContextNote(rows, r2); got != "Its 18 turns are deleted for good." {
		t.Errorf("newest delete note = %q", got)
	}
	msgs := []*psmithv1.Message{{CreatedAt: day(22), Role: psmithv1.MessageRole_MESSAGE_ROLE_USER}, {CreatedAt: day(30)}}
	if got := ctxRange("Context 1", msgs, 46); got != "Context 1 · Oct 22 to Oct 30 · 46 turns" {
		t.Errorf("range = %q", got)
	}
}

func TestElicitFieldsAndEvent(t *testing.T) {
	t.Parallel()
	f := parseElicitFields(json.RawMessage(`{"properties":{"token":{"type":"string","format":"password","default":"x"},"remember":{"type":"boolean","default":true}},"required":["token"]}`))
	if len(f) != 2 || f[0].Name != "remember" || f[0].Default != "true" || !f[1].Required || f[1].Default != "x" {
		t.Fatalf("fields = %+v", f)
	}
	payload := []byte(`{"elicitation_id":"e1","message":"Need a token","requested_schema":{"properties":{"token":{"type":"string","format":"password"}},"required":["token"]}}`)
	out := elicitEvent(context.Background(), "c1", payload, "create_issue")
	for _, want := range []string{`id="composer-slot"`, `hx-swap-oob="outerHTML"`, "A tool needs input", "Need a token", `name="field_token"`, `type="password"`, `value="decline"`, `value="accept"`, "create_issue"} {
		if !strings.Contains(out, want) {
			t.Errorf("elicit event missing %q", want)
		}
	}
}

func TestSentenceAndWhen(t *testing.T) {
	t.Parallel()
	if sentence("deliver background") != "Deliver background." || sentence("Done.") != "Done." {
		t.Error("sentence")
	}
	now := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	if got := fmtWhen(now, now.Add(-time.Hour)); got != "Today, 11:00 AM" {
		t.Errorf("today = %q", got)
	}
	if got := fmtWhen(now, time.Date(2026, 10, 22, 16, 12, 0, 0, time.UTC)); got != "Oct 22, 2026, 4:12 PM" {
		t.Errorf("past = %q", got)
	}
}

// The probe fixtures render every view, so a template panic shows up here
// even without the probe environment.
func TestInspectorViewsRender(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	for name, c := range map[string]convVM{
		"settings": boardInspSettings(), "plugins": boardInspPlugins(), "model": boardInspModel(),
		"contexts": boardInspContexts(), "panel": boardPluginPanel(), "info": boardInspInfo(),
		"compress": boardCompress("compress"), "compacting": boardCompress("compacting"), "review": boardCompress("review"),
		"edit": boardCompress("edit"), "failed": boardCompress("failed"), "elicit": boardElicit(),
	} {
		if out := renderComp(ctx, conversationScreen(boardList(), c)); !strings.Contains(out, `id="inspector"`) && name != "archived" {
			t.Errorf("%s: no inspector", name)
		}
	}
	l, c, v := boardContextView()
	if out := renderComp(ctx, contextViewScreen(l, c, v)); !strings.Contains(out, "Context 1 is read-only") || !strings.Contains(out, "/context/x1/activate") {
		t.Error("context view lacks the read-only card")
	}
	al, ac := boardArchived()
	if out := renderComp(ctx, conversationScreen(al, ac)); !strings.Contains(out, "/unarchive") {
		t.Error("archived card lacks Unarchive")
	}
}

// --- handlers against a database ---

type inspFx struct {
	h      *Handler
	q      *store.Queries
	ctx    context.Context
	conv   string
	fx     sendFixture
	convos interface {
		GetConversation(context.Context, *connect.Request[psmithv1.GetConversationRequest]) (*connect.Response[psmithv1.GetConversationResponse], error)
	}
}

func newInspFx(t *testing.T) inspFx {
	t.Helper()
	h, q, convos := newConvSettingsHandler(t)
	fx := seedSendable(t, q, "http://unused")
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})
	return inspFx{h: h, q: q, ctx: userCtx, conv: fx.convID.String(), fx: fx, convos: convos}
}

func (f inspFx) get(t *testing.T, fn http.HandlerFunc, path string, pv map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("GET", path, nil).WithContext(f.ctx)
	req.SetPathValue("id", f.conv)
	for k, v := range pv {
		req.SetPathValue(k, v)
	}
	return do(fn, req)
}

func (f inspFx) post(t *testing.T, fn http.HandlerFunc, path string, form url.Values, pv map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("POST", path, strings.NewReader(form.Encode())).WithContext(f.ctx)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetPathValue("id", f.conv)
	for k, v := range pv {
		req.SetPathValue(k, v)
	}
	return do(fn, req)
}

func TestInspectorTabs(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	for tab, want := range map[string]string{
		"context":  "Context size",
		"settings": "Call settings",
		"plugins":  "Pipeline",
		"contexts": "Open a past context to read it",
		"info":     "Generate title",
	} {
		rec := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab="+tab, nil)
		body := rec.Body.String()
		if rec.Code != 200 || !strings.Contains(body, want) {
			t.Errorf("tab %s: code=%d, missing %q", tab, rec.Code, want)
		}
		if !strings.Contains(body, "inspector as-page") {
			t.Errorf("tab %s: an asked-for inspector should be able to take the page", tab)
		}
	}
	if rec := f.get(t, f.h.handleConvSettings, "/c/"+f.conv+"/settings?tab=plugins", nil); rec.Header().Get("Location") != "/c/"+f.conv+"?tab=plugins" {
		t.Errorf("old settings URL redirect = %q", rec.Header().Get("Location"))
	}
}

func TestConvSettings_CacheTTL(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	rec := f.post(t, f.h.handleConvSettingsSave, "/c/"+f.conv+"/settings", url.Values{"anth_cache_ttl": {"1h"}}, nil)
	if rec.Code != 303 || rec.Header().Get("Location") != "/c/"+f.conv+"?tab=settings" {
		t.Fatalf("save: code=%d location=%q", rec.Code, rec.Header().Get("Location"))
	}
	got, _ := f.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.conv}))
	if ttl := got.Msg.GetConversation().GetSettings().GetCallSettings().GetAnthropic().GetCacheTtl(); ttl != psmithv1.CacheTTL_CACHE_TTL_1H {
		t.Errorf("cache ttl = %v", ttl)
	}
}

func TestPluginsTab_SaveAddRemove(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	if rec := f.post(t, f.h.handleConvPluginsSave, "/c/"+f.conv+"/plugins", url.Values{"add": {"basic_grounding"}}, nil); rec.Code != 303 {
		t.Fatalf("add: %d %s", rec.Code, rec.Body.String())
	}
	body := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=plugins", nil).Body.String()
	if !strings.Contains(body, "This conversation") || !strings.Contains(body, `name="remove" value="basic_grounding"`) {
		t.Fatalf("added plugin not listed as conversation-only")
	}
	if rec := f.post(t, f.h.handleConvPluginsSave, "/c/"+f.conv+"/plugins", url.Values{"remove": {"basic_grounding"}}, nil); rec.Code != 303 {
		t.Fatalf("remove: %d", rec.Code)
	}
	body = f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=plugins", nil).Body.String()
	if strings.Contains(body, `value="basic_grounding"`) && strings.Contains(body, "This conversation") {
		t.Error("plugin still listed after remove")
	}
}

func TestContexts_RenameActivateDelete(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	first, _ := f.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.conv}))
	oldID := first.Msg.GetActiveContext().GetId()
	if _, err := f.h.convos.CreateContextManual(f.ctx, connect.NewRequest(&psmithv1.CreateContextManualRequest{ConversationId: f.conv})); err != nil {
		t.Fatalf("CreateContextManual: %v", err)
	}
	pv := map[string]string{"cid": oldID}

	if rec := f.post(t, f.h.handleContextRename, "/", url.Values{"title": {"Paging by date"}}, pv); rec.Code != 303 {
		t.Fatalf("rename: %d %s", rec.Code, rec.Body.String())
	}
	page := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=contexts&rename="+oldID, nil).Body.String()
	if !strings.Contains(page, `value="Paging by date"`) {
		t.Error("rename form lacks the saved title")
	}

	view := f.get(t, f.h.handleContextView, "/", pv)
	if view.Code != 200 || !strings.Contains(view.Body.String(), "Context 1 is read-only") {
		t.Fatalf("read-only view: %d", view.Code)
	}

	confirm := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=contexts&confirm="+oldID, nil).Body.String()
	if !strings.Contains(confirm, "Delete Context 1?") {
		t.Error("delete confirm not rendered in place")
	}

	if rec := f.post(t, f.h.handleContextActivate, "/", nil, pv); rec.Code != 303 {
		t.Fatalf("activate: %d %s", rec.Code, rec.Body.String())
	}
	now, _ := f.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.conv}))
	if now.Msg.GetActiveContext().GetId() != oldID {
		t.Fatal("activate did not switch contexts")
	}

	// The active context can't be deleted; the other one can.
	if rec := f.post(t, f.h.handleContextDelete, "/", nil, pv); rec.Code == 303 {
		t.Error("deleting the active context should fail")
	}
	rows := f.h.contextRows(f.ctx, f.conv, oldID)
	var other string
	for _, r := range rows {
		if r.ID != oldID {
			other = r.ID
		}
	}
	if rec := f.post(t, f.h.handleContextDelete, "/", nil, map[string]string{"cid": other}); rec.Code != 303 {
		t.Fatalf("delete: %d %s", rec.Code, rec.Body.String())
	}
	if n := len(f.h.contextRows(f.ctx, f.conv, oldID)); n != 1 {
		t.Errorf("contexts after delete = %d", n)
	}

	// A context from another conversation is refused.
	if rec := f.post(t, f.h.handleContextActivate, "/", nil, map[string]string{"cid": "00000000-0000-0000-0000-000000000000"}); rec.Code != 404 {
		t.Errorf("foreign context: %d", rec.Code)
	}
}

func TestInfo_TitleAndDelete(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	if rec := f.post(t, f.h.handleTitleSave, "/", url.Values{"title": {"Scroll review"}}, nil); rec.Code != 303 {
		t.Fatalf("title: %d", rec.Code)
	}
	body := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=info", nil).Body.String()
	if !strings.Contains(body, `value="Scroll review"`) || !strings.Contains(body, "/title/generate") {
		t.Error("info view lacks the title or Generate title")
	}
	confirm := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=info&confirm=delete", nil).Body.String()
	if !strings.Contains(confirm, "Delete this conversation?") || !strings.Contains(confirm, "/info/delete") {
		t.Error("delete confirm missing")
	}
	if rec := f.post(t, f.h.handleInfoDelete, "/", nil, nil); rec.Code != 303 || rec.Header().Get("Location") != "/chats" {
		t.Fatalf("delete: %d %q", rec.Code, rec.Header().Get("Location"))
	}
	if _, err := f.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.conv})); err == nil {
		t.Error("conversation survived delete")
	}
}

func TestCompress_PageAndWindowCheck(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	page := f.get(t, f.h.handleCompactPage, "/c/"+f.conv+"/compact", nil).Body.String()
	for _, want := range []string{"Compress into a new context", `name="guide"`, `name="model"`, defaultCompressionGuide, `aria-pressed="true"`} {
		if !strings.Contains(page, want) {
			t.Errorf("compress card missing %q", want)
		}
	}

	// Pretend the context is bigger than the model's window: the card fails
	// before anything runs.
	win := int32(10)
	if _, err := f.q.UpsertUserModel(f.ctx, store.UpsertUserModelParams{UserModelProviderID: f.fx.providerID, ModelID: "tiny", DisplayName: "Tiny",
		ContextWindow: &win, MetadataSource: "manual", MetadataSnapshotAt: time.Now().UTC()}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}
	conv, _ := f.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.conv}))
	in, out := int32(400), int32(100)
	if _, err := f.q.CreateAssistantMessageWithUsage(f.ctx, store.CreateAssistantMessageWithUsageParams{
		ID: uuid.New(), ContextID: uuid.MustParse(conv.Msg.GetActiveContext().GetId()), Role: "assistant", Content: "hi",
		InputTokens: &in, OutputTokens: &out,
	}); err != nil {
		t.Fatalf("CreateAssistantMessageWithUsage: %v", err)
	}
	rec := f.post(t, f.h.handleCompactRun, "/", url.Values{"model": {modelValue(f.fx.providerID.String(), "tiny")}, "guide": {"Sum."}}, nil)
	body := rec.Body.String()
	if rec.Code != 200 || !strings.Contains(body, "Compression failed") || !strings.Contains(body, "Tiny can&#39;t fit this context") {
		t.Errorf("window check: code=%d body=%s", rec.Code, body[strings.Index(body, "composer-slot"):][:1500])
	}
}

func TestCompactStop_RefusesUnknownRun(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	rec := f.post(t, f.h.handleCompactStop, "/", url.Values{"run": {"00000000-0000-0000-0000-000000000001"}}, nil)
	if rec.Code != 404 {
		t.Errorf("stop of a run that isn't this conversation's compaction = %d", rec.Code)
	}
}

func TestSummaryRoutes_RefuseOtherMessages(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	for name, fn := range map[string]http.HandlerFunc{"save": f.h.handleSummarySave, "discard": f.h.handleSummaryDiscard, "promote": f.h.handleCompactPromote} {
		rec := f.post(t, fn, "/", url.Values{"message_id": {"00000000-0000-0000-0000-000000000002"}, "content": {"x"}}, nil)
		if rec.Code != 404 {
			t.Errorf("%s with a foreign message = %d", name, rec.Code)
		}
	}
}

func TestPluginPanel_UnknownPlugin(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	if rec := f.get(t, f.h.handlePluginPanel, "/", map[string]string{"name": "nope"}); rec.Code != 404 {
		t.Errorf("panel for a plugin not in the pipeline = %d", rec.Code)
	}
	if rec := f.post(t, f.h.handlePluginAction, "/", url.Values{}, map[string]string{"name": "nope"}); rec.Code != 400 {
		t.Errorf("action without a name = %d", rec.Code)
	}
}

func TestModelPicker_SearchFilters(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	body := f.get(t, f.h.handleModelPicker, "/c/"+f.conv+"/model?q=zzz", nil).Body.String()
	if strings.Contains(body, `data-pick-name="Claude Fake"`) {
		t.Error("search did not filter the list")
	}
	body = f.get(t, f.h.handleModelPicker, "/c/"+f.conv+"/model?q=fake", nil).Body.String()
	if !strings.Contains(body, `data-pick-name="Claude Fake"`) {
		t.Error("search hid a match")
	}
}

// Answering the card from htmx swaps the composer back into its place.
func TestElicitRespond_ReturnsComposer(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	req := httptest.NewRequest("POST", "/c/"+f.conv+"/elicit/x", strings.NewReader("action=decline")).WithContext(f.ctx)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("HX-Request", "true")
	req.SetPathValue("id", f.conv)
	req.SetPathValue("eid", uuid.New().String())
	rec := do(f.h.handleElicitRespond, req)
	if body := rec.Body.String(); rec.Code != 200 || !strings.Contains(body, `id="composer-slot"`) || !strings.Contains(body, `id="composer"`) {
		t.Errorf("respond: code=%d body=%s", rec.Code, body)
	}
}
