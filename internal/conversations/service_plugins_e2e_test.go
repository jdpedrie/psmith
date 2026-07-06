package conversations

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
)

// attachLetteredChoicesPlugin writes a single profile_plugins row referencing
// the lettered_choices plugin with default config.
func attachLetteredChoicesPlugin(t *testing.T, q *store.Queries, profileID uuid.UUID) {
	t.Helper()
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID:       profileID,
		Ordinal:         0,
		PluginName:      plugins.LetteredChoicesName,
		ConfigEncrypted: []byte(`{"keep_last_n": 1}`),
	}); err != nil {
		t.Fatalf("InsertProfilePlugin: %v", err)
	}
}

// TestPlugins_E2E_LetteredChoicesAppliesEverywhere walks the full pipeline:
//  1. Attach lettered_choices to the profile.
//  2. Insert two assistant turns whose content includes <choices>...</choices>.
//  3. Confirm SendMessage's history.Build:
//     - prepends the lettered_choices system instruction onto the system slot
//     - keeps the most recent assistant's choices intact (KeepLastN=1)
//     - strips the older assistant's choices block
//  4. Confirm ListMessages populates display_content with the tags stripped.
func TestPlugins_E2E_LetteredChoicesAppliesEverywhere(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	// Three scripts: two for seeding history, one for the SendMessage we'll inspect.
	for _, txt := range []string{"a1 body <choices>A) one</choices>", "a2 body <choices>X) other</choices>", "ok"} {
		fake.Enqueue(fakellm.Script{
			Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}},
		})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	attachLetteredChoicesPlugin(t, q, f.profile.ID)

	// Drive two turns to seed real assistant history.
	_, _ = runOneTurn(t, svc, sup, q, f, "first")
	_, _ = runOneTurn(t, svc, sup, q, f, "second")

	// SendMessage a third time: this is the turn we inspect on the wire.
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "third",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status=%q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}

	// Inspect what the SDK sent on the wire for the third turn. We decode the
	// JSON body so the assertions can match literal "<choices>" rather than
	// the JSON-escaped "<choices>" the wire format produces.
	reqs := fake.Requests()
	if len(reqs) != 3 {
		t.Fatalf("captured %d requests, want 3", len(reqs))
	}
	type wireMsg struct {
		Role    string `json:"role"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	type wireBody struct {
		System []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"system"`
		Messages []wireMsg `json:"messages"`
	}
	var body wireBody
	if err := json.Unmarshal(reqs[2].Body, &body); err != nil {
		t.Fatalf("decode body: %v (raw=%s)", err, truncate(string(reqs[2].Body), 400))
	}

	systemText := ""
	for _, blk := range body.System {
		systemText += blk.Text
	}
	// (1) System instruction was appended to the system slot. The
	// lettered_choices plugin's default prose talks about "choices" and
	// shows the `<choices>` delimiter pair — anchor on the delimiter so
	// the assertion survives prose tweaks.
	if !strings.Contains(systemText, "<choices>") {
		t.Errorf("system message should contain the lettered_choices instruction; got %q", systemText)
	}

	// Stitch each message's content blocks for assertion convenience.
	contentByOrder := make([]string, 0, len(body.Messages))
	for _, m := range body.Messages {
		var sb strings.Builder
		for _, blk := range m.Content {
			sb.WriteString(blk.Text)
		}
		contentByOrder = append(contentByOrder, sb.String())
	}

	// (2) The MORE RECENT assistant turn (a2) keeps its choices intact.
	// (3) The OLDER assistant turn (a1) ALSO keeps its choices intact —
	// this provider is Anthropic, and stripping a message inside the
	// cached prefix would bust the prompt cache every turn. The strip is
	// suppressed on Anthropic (see lettered_choices.TransformHistoryMessage);
	// the openai-compatible strip path is covered by the plugin unit tests.
	var sawRecentWithTags, sawOlderWithTags bool
	for _, c := range contentByOrder {
		if strings.Contains(c, "X) other") {
			if !strings.Contains(c, "<choices>") {
				t.Errorf("recent assistant content lost its tags: %q", c)
			} else {
				sawRecentWithTags = true
			}
		}
		if strings.HasPrefix(c, "a1 body") {
			if !strings.Contains(c, "<choices>") || !strings.Contains(c, "A) one") {
				t.Errorf("older assistant choices should be PRESERVED on Anthropic (cache); got %q", c)
			}
			sawOlderWithTags = true
		}
	}
	if !sawRecentWithTags {
		t.Errorf("did not find the recent-assistant message with intact tags; messages=%v", contentByOrder)
	}
	if !sawOlderWithTags {
		t.Errorf("did not find the older-assistant message; messages=%v", contentByOrder)
	}

	// (4) ListMessages populates display_content with tags stripped.
	listResp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId: f.contextID.String(),
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	var sawAssistantWithStrippedDisplay bool
	for _, m := range listResp.Msg.Messages {
		if m.Role != psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT {
			continue
		}
		if !strings.Contains(m.Content, "<choices>") {
			// Some assistant rows may have empty/unrelated content; skip.
			continue
		}
		// display_content should have neither delimiter, but should preserve the choice text.
		if strings.Contains(m.DisplayContent, "<choices>") || strings.Contains(m.DisplayContent, "</choices>") {
			t.Errorf("display_content still contains tags: %q", m.DisplayContent)
		}
		// Should still contain the actual choice text post-display-transform.
		if !strings.Contains(m.DisplayContent, "body") {
			t.Errorf("display_content unexpectedly empty / lost body text: %q", m.DisplayContent)
		}
		sawAssistantWithStrippedDisplay = true
	}
	if !sawAssistantWithStrippedDisplay {
		t.Error("expected at least one assistant message to have had its display_content tag-stripped")
	}
}

// TestPlugins_E2E_NoPluginsDisplayEqualsContent — when the profile has no
// plugins, display_content equals content (the documented default), so
// clients can always read display_content.
func TestPlugins_E2E_NoPluginsDisplayEqualsContent(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "hello"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	_, _ = runOneTurn(t, svc, sup, q, f, "first")

	listResp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId: f.contextID.String(),
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	for _, m := range listResp.Msg.Messages {
		if m.DisplayContent != m.Content {
			t.Errorf("display_content (%q) != content (%q) without plugins", m.DisplayContent, m.Content)
		}
	}
}

// TestPlugins_PipelineResolverInheritsFromParentProfile — child profile has
// no plugin rows, parent does; the resolver should pick up the parent's.
func TestPlugins_PipelineResolverInheritsFromParentProfile(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "plugin-inherit", nil, nil)
	f := seedSendable(t, q, driverType)

	// Create a child profile inheriting from f.profile; attach plugin to
	// the PARENT only.
	cid, _ := uuid.NewV7()
	parentID := f.profile.ID
	if _, err := q.CreateProfile(context.Background(), store.CreateProfileParams{
		ID: cid, UserID: f.user.ID, ParentProfileID: &parentID, Name: "child",
	}); err != nil {
		t.Fatalf("CreateProfile child: %v", err)
	}
	attachLetteredChoicesPlugin(t, q, parentID)

	// Resolving on the CHILD should return the parent's pipeline.
	pipeline, err := svc.resolvePluginPipeline(context.Background(), cid)
	if err != nil {
		t.Fatalf("resolvePluginPipeline: %v", err)
	}
	if pipeline.Empty() {
		t.Fatal("expected parent's plugin to be inherited; got empty pipeline")
	}
	if pipeline[0].Name() != plugins.LetteredChoicesName {
		t.Errorf("first plugin = %q want %q", pipeline[0].Name(), plugins.LetteredChoicesName)
	}
}

// TestPlugins_PipelineResolverChildOverridesParent — child profile has its
// own plugin row; that completely replaces the parent's pipeline (all-or-
// nothing inheritance).
func TestPlugins_PipelineResolverChildOverridesParent(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "plugin-override", nil, nil)
	f := seedSendable(t, q, driverType)

	cid, _ := uuid.NewV7()
	parentID := f.profile.ID
	if _, err := q.CreateProfile(context.Background(), store.CreateProfileParams{
		ID: cid, UserID: f.user.ID, ParentProfileID: &parentID, Name: "child",
	}); err != nil {
		t.Fatalf("CreateProfile child: %v", err)
	}
	// Parent has 2 lettered_choices entries; child overrides with 1.
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID: parentID, Ordinal: 0, PluginName: plugins.LetteredChoicesName, ConfigEncrypted: []byte(`{"keep_last_n": 5}`),
	}); err != nil {
		t.Fatalf("InsertProfilePlugin parent[0]: %v", err)
	}
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID: parentID, Ordinal: 1, PluginName: plugins.LetteredChoicesName, ConfigEncrypted: []byte(`{"keep_last_n": 7}`),
	}); err != nil {
		t.Fatalf("InsertProfilePlugin parent[1]: %v", err)
	}
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID: cid, Ordinal: 0, PluginName: plugins.LetteredChoicesName, ConfigEncrypted: []byte(`{"keep_last_n": 1}`),
	}); err != nil {
		t.Fatalf("InsertProfilePlugin child: %v", err)
	}

	pipeline, err := svc.resolvePluginPipeline(context.Background(), cid)
	if err != nil {
		t.Fatalf("resolvePluginPipeline: %v", err)
	}
	if len(pipeline) != 1 {
		t.Errorf("expected 1 plugin (child overrides parent); got %d", len(pipeline))
	}
}

// TestPlugins_PipelineResolverNoPluginsAnywhere — neither child nor parent
// has plugin rows; resolver returns nil pipeline (which Pipeline.Empty
// reports true for).
func TestPlugins_PipelineResolverNoPluginsAnywhere(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "plugin-empty", nil, nil)
	f := seedSendable(t, q, driverType)

	pipeline, err := svc.resolvePluginPipeline(context.Background(), f.profile.ID)
	if err != nil {
		t.Fatalf("resolvePluginPipeline: %v", err)
	}
	if !pipeline.Empty() {
		t.Errorf("expected empty pipeline; got %d plugins", len(pipeline))
	}
}

// TestPlugins_E2E_BasicGroundingRewritesPersistedUser walks the
// OutgoingUserTransformer path:
//  1. Attach basic_grounding to the profile.
//  2. SendMessage with a plain user message.
//  3. Confirm the persisted user row contains the `<grounding>` block
//     and the stable wall-clock value (proves the transform ran at
//     write time, not at history-build time).
//  4. Confirm the wire body to the LLM contains the `<grounding>` block
//     (proves the rewritten content propagates onto the wire prefix).
//  5. Confirm SendMessage response's UserMessage.DisplayContent has the
//     block stripped (proves the DisplayTransformer fires for the just-
//     inserted user row).
//  6. Confirm ListMessages returns the same display-stripped content for
//     the user row.
//
// This guards against the regression where `pipeline.TransformOutgoingUser`
// was never called, leaving basic_grounding silently inert.
func TestPlugins_E2E_BasicGroundingRewritesPersistedUser(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}},
	})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID:       f.profile.ID,
		Ordinal:         0,
		PluginName:      plugins.BasicGroundingName,
		ConfigEncrypted: []byte(`{"include_date_time": true, "time_format": "datetime_iso"}`),
	}); err != nil {
		t.Fatalf("InsertProfilePlugin: %v", err)
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	const original = "what's the weather like?"
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        original,
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status=%q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}

	// (1) The persisted user row carries the grounding block + original text.
	userMsgID, _ := uuid.Parse(resp.Msg.UserMessage.Id)
	userRow, err := q.GetMessageByID(context.Background(), userMsgID)
	if err != nil {
		t.Fatalf("GetMessageByID(user): %v", err)
	}
	if !strings.Contains(userRow.Content, "<grounding>") || !strings.Contains(userRow.Content, "</grounding>") {
		t.Errorf("persisted user content missing grounding block: %q", userRow.Content)
	}
	if !strings.Contains(userRow.Content, "Current time:") {
		t.Errorf("persisted user content missing 'Current time:' line: %q", userRow.Content)
	}
	if !strings.Contains(userRow.Content, original) {
		t.Errorf("persisted user content lost original text %q: got %q", original, userRow.Content)
	}

	// (2) The wire body sent to the fake LLM contains the grounding block.
	reqs := fake.Requests()
	if len(reqs) != 1 {
		t.Fatalf("captured %d requests, want 1", len(reqs))
	}
	type wireMsg struct {
		Role    string `json:"role"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	type wireBody struct {
		Messages []wireMsg `json:"messages"`
	}
	var body wireBody
	if err := json.Unmarshal(reqs[0].Body, &body); err != nil {
		t.Fatalf("decode body: %v (raw=%s)", err, truncate(string(reqs[0].Body), 400))
	}
	var sawWireGrounding bool
	for _, m := range body.Messages {
		if m.Role != "user" {
			continue
		}
		for _, blk := range m.Content {
			if strings.Contains(blk.Text, "<grounding>") && strings.Contains(blk.Text, "Current time:") {
				sawWireGrounding = true
			}
		}
	}
	if !sawWireGrounding {
		t.Errorf("wire body did not include grounding block on a user message; messages=%+v", body.Messages)
	}

	// (3) The SendMessage response's display content has the block stripped.
	if strings.Contains(resp.Msg.UserMessage.DisplayContent, "<grounding>") ||
		strings.Contains(resp.Msg.UserMessage.DisplayContent, "</grounding>") {
		t.Errorf("response UserMessage.display_content still has grounding tags: %q", resp.Msg.UserMessage.DisplayContent)
	}
	if strings.TrimSpace(resp.Msg.UserMessage.DisplayContent) != original {
		t.Errorf("display_content = %q, want %q", resp.Msg.UserMessage.DisplayContent, original)
	}

	// (4) ListMessages returns the same display-stripped content.
	listResp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId: f.contextID.String(),
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	var sawUserStripped bool
	for _, m := range listResp.Msg.Messages {
		if m.Role != psmithv1.MessageRole_MESSAGE_ROLE_USER {
			continue
		}
		if strings.Contains(m.DisplayContent, "<grounding>") || strings.Contains(m.DisplayContent, "</grounding>") {
			t.Errorf("user display_content still has grounding tags: %q", m.DisplayContent)
		}
		if !strings.Contains(m.Content, "<grounding>") {
			t.Errorf("user content lost grounding tags between persist and list: %q", m.Content)
		}
		sawUserStripped = true
	}
	if !sawUserStripped {
		t.Error("expected at least one user message in ListMessages")
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
