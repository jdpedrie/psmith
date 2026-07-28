package plugins

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// stubGameStore stands in for Postgres so these stay pure Go. Captures
// what it was asked to do so scoping can be asserted.
type stubGameStore struct {
	state   json.RawMessage
	version int64
	loadErr error

	savedState   json.RawMessage
	savedVersion int64
	savedTo      uuid.UUID
}

func (s *stubGameStore) LoadNearest(context.Context) (json.RawMessage, int64, uuid.UUID, error) {
	if s.loadErr != nil {
		return nil, 0, uuid.Nil, s.loadErr
	}
	if len(s.state) == 0 {
		return nil, 0, uuid.Nil, ErrNoGameState
	}
	return s.state, s.version, uuid.New(), nil
}

func (s *stubGameStore) Save(_ context.Context, messageID uuid.UUID, state json.RawMessage, version int64) error {
	s.savedTo, s.savedState, s.savedVersion = messageID, state, version
	return nil
}

func newGameForTest(t *testing.T, cfg string) *strategyGame {
	t.Helper()
	var raw json.RawMessage
	if cfg != "" {
		raw = json.RawMessage(cfg)
	}
	pl, err := newStrategyGame(raw)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	g, ok := pl.(*strategyGame)
	if !ok {
		t.Fatalf("unexpected type %T", pl)
	}
	return g
}

func gameCtx(store GameStore) context.Context {
	ctx := WithGameStore(context.Background(), store)
	return WithCallerInfo(ctx, CallerInfo{
		UserID:          uuid.New(),
		ConversationID:  uuid.New(),
		ActiveContextID: uuid.New(),
	})
}

const initInput = `{
  "kind": "initialize",
  "scenario": {
    "title": "The Lean Winter",
    "role": "Margrave",
    "premise": "A border march one bad harvest from collapse.",
    "date_label": "Late Autumn",
    "resources": [
      {"id":"treasury","label":"Treasury","start":60,"min":0,"max":200},
      {"id":"unrest","label":"Unrest","start":20,"min":0,"max":100}
    ],
    "ratings": [
      {"id":"guile","label":"Guile","start":4,"min":0,"max":10},
      {"id":"standing","label":"Standing","start":5,"min":0,"max":10}
    ],
    "loss_when": [{"stat":"treasury","op":"<=","value":0,"label":"The treasury is empty"}],
    "turn_limit": 12,
    "hidden_facts": ["The reeve is skimming the grain tithe."],
    "opening_situation": {
      "id":"granary","title":"The Empty Granary","body":"The winter stores were overstated.",
      "choices":[
        {"id":"A","label":"Buy grain from the guild","rating":"guile","difficulty":"moderate","stakes":"standard","advances":"standing","costs":"treasury"},
        {"id":"B","label":"Seize the stores","rating":"standing","difficulty":"hard","stakes":"major","advances":"treasury","costs":"standing"}
      ]
    }
  }
}`

// nextTurn models what actually happens between turns: the pipeline is
// rebuilt per send, so turn N+1 runs on a brand-new plugin instance
// whose only knowledge of turn N is what was written to the store.
func nextTurn(t *testing.T, prev *strategyGame) (*strategyGame, *stubGameStore) {
	t.Helper()
	state, version, ok := prev.PendingPluginState()
	if !ok {
		t.Fatal("previous turn committed no state to carry forward")
	}
	return newGameForTest(t, ""), &stubGameStore{state: state, version: version}
}

func TestStrategyGame_Descriptor(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")

	if g.Name() != StrategyGameName {
		t.Errorf("name: %q", g.Name())
	}
	if g.DisplayName() == "" || g.Description() == "" {
		t.Error("display name and description must be non-empty")
	}
	tp, ok := Plugin(g).(ToolProvider)
	if !ok {
		t.Fatal("must implement ToolProvider")
	}
	tools := tp.Tools()
	got := map[string]bool{}
	for _, tool := range tools {
		got[tool.Name] = true
	}
	for _, want := range []string{"game_commit_turn", "game_price_action", "game_inspect"} {
		if !got[want] {
			t.Errorf("missing tool %q (have %v)", want, got)
		}
	}
	if len(tools) != 3 {
		t.Errorf("tool surface should stay small; got %d tools", len(tools))
	}
	for _, tool := range tools {
		var schema map[string]any
		if err := json.Unmarshal(tool.InputSchema, &schema); err != nil {
			t.Errorf("tool %s has invalid schema JSON: %v", tool.Name, err)
		}
	}
	// The capability gate depends on this being auto-derived.
	desc, err := Describe(StrategyGameName)
	if err != nil {
		t.Fatalf("describe: %v", err)
	}
	if !desc.RequiredModelCapabilities.ToolUse {
		t.Error("a tool-providing plugin must require tool_use")
	}
}

// TestStrategyGame_NilConfigIsUsable matters because Describe builds
// every registered plugin with a nil config to introspect it — an
// erroring constructor would break ListPluginTypes for the whole
// registry, not just this plugin.
func TestStrategyGame_NilConfigIsUsable(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if !g.cfg.ShowOdds || !g.cfg.ShowRolls {
		t.Errorf("defaults should be on: %+v", g.cfg)
	}
}

func TestStrategyGame_RequiresStore(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	_, err := g.ExecuteTool(context.Background(), "game_commit_turn", json.RawMessage(initInput))
	if err == nil || !strings.Contains(err.Error(), "no GameStore") {
		t.Errorf("unwired store should produce a clean tool error; got %v", err)
	}
}

func TestStrategyGame_InitializeStartsCampaign(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	store := &stubGameStore{}

	res, err := g.ExecuteTool(gameCtx(store), "game_commit_turn", json.RawMessage(initInput))
	if err != nil {
		t.Fatalf("initialize: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(res.Output, &out); err != nil {
		t.Fatalf("tool output: %v", err)
	}
	if out["committed"] != true {
		t.Errorf("expected committed=true; got %v", out)
	}
	// State is pending, not yet stored — there is no assistant message
	// to bind it to until materialization.
	state, version, ok := g.PendingPluginState()
	if !ok || version != 1 {
		t.Fatalf("expected pending state at version 1; got ok=%v v=%d", ok, version)
	}
	if store.savedState != nil {
		t.Error("the plugin must not write state itself; binding happens at materialization")
	}
	if !strings.Contains(string(state), "granary") {
		t.Error("pending state should carry the opening situation")
	}
}

// TestStrategyGame_RejectsSecondInitialize is the phase gate: the model
// does not get to decide whether a campaign exists.
func TestStrategyGame_RejectsSecondInitialize(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("first initialize: %v", err)
	}
	// A later send, with the campaign already on the branch.
	g2, store2 := nextTurn(t, g)
	_, err := g2.ExecuteTool(gameCtx(store2), "game_commit_turn", json.RawMessage(initInput))
	if err == nil || !strings.Contains(err.Error(), "already underway") {
		t.Errorf("second initialize should be refused; got %v", err)
	}
}

func TestStrategyGame_ResolveRequiresCampaign(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	_, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn",
		json.RawMessage(`{"kind":"resolve","choice_id":"A"}`))
	if err == nil || !strings.Contains(err.Error(), "no campaign yet") {
		t.Errorf("resolve before initialize should be refused; got %v", err)
	}
}

func TestStrategyGame_RejectsUnknownKind(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	_, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn",
		json.RawMessage(`{"kind":"cheat"}`))
	if err == nil || !strings.Contains(err.Error(), "kind must be") {
		t.Errorf("unknown kind should be refused; got %v", err)
	}
}

// TestStrategyGame_RejectsModelInventedDifficulty verifies the tag
// vocabulary is enforced server-side rather than merely requested in the
// prompt — the whole reason the model picks bands instead of integers.
func TestStrategyGame_RejectsModelInventedDifficulty(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	bad := strings.Replace(initInput, `"difficulty":"moderate"`, `"difficulty":"basically impossible"`, 1)
	_, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(bad))
	if err == nil || !strings.Contains(err.Error(), "unknown difficulty") {
		t.Errorf("invented difficulty should be refused; got %v", err)
	}
}

func TestStrategyGame_ResolveAppliesTurn(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	g2, store2 := nextTurn(t, g)
	ctx := gameCtx(store2)
	g = g2

	resolveInput := `{
	  "kind":"resolve","choice_id":"A",
	  "next_situation":{"id":"tithe","title":"The Reeve's Books","body":"The tithe rolls do not add up.",
	    "choices":[
	      {"id":"A","label":"Audit quietly","rating":"guile","difficulty":"easy","stakes":"minor","advances":"treasury","costs":"standing"},
	      {"id":"B","label":"Hang the reeve","rating":"standing","difficulty":"moderate","stakes":"major","advances":"standing","costs":"unrest"}
	    ]}
	}`
	res, err := g.ExecuteTool(ctx, "game_commit_turn", json.RawMessage(resolveInput))
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(res.Output, &out); err != nil {
		t.Fatalf("output: %v", err)
	}
	if out["outcome"] == nil || out["outcome"] == "" {
		t.Error("resolve should report an outcome band")
	}
	if out["turn"] != float64(2) {
		t.Errorf("turn should advance to 2; got %v", out["turn"])
	}
	_, version, ok := g.PendingPluginState()
	if !ok || version != 2 {
		t.Errorf("state version should advance; got ok=%v v=%d", ok, version)
	}
}

// TestStrategyGame_AppendsAuthoritativeBlock is the heart of the "model
// never publishes a number" guarantee: the model's prose goes in
// untouched and the engine's own figures are appended before persist.
func TestStrategyGame_AppendsAuthoritativeBlock(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}

	prose := "The granary doors stand open on empty flagstones."
	got := g.TransformAssistantContent(prose)
	if !strings.HasPrefix(got, prose) {
		t.Error("the model's prose must survive verbatim")
	}
	if !strings.Contains(got, gameOpenTag) || !strings.Contains(got, gameCloseTag) {
		t.Fatalf("expected an appended game block; got %q", got)
	}
	body := got[strings.Index(got, gameOpenTag)+len(gameOpenTag) : strings.Index(got, gameCloseTag)]
	var block gameBlock
	if err := json.Unmarshal([]byte(body), &block); err != nil {
		t.Fatalf("block is not valid JSON: %v", err)
	}
	if len(block.Stats) != 4 {
		t.Errorf("expected 4 stats in the panel; got %d", len(block.Stats))
	}
	if len(block.Choices) != 2 {
		t.Errorf("expected 2 choices; got %d", len(block.Choices))
	}
	for _, c := range block.Choices {
		if c.Favorable <= 0 || c.Favorable >= 100 {
			t.Errorf("choice %s has implausible odds %d", c.ID, c.Favorable)
		}
	}
	// Director-only facts must never reach the rendered payload.
	if strings.Contains(body, "skimming") {
		t.Error("hidden director facts leaked into the client block")
	}
}

// TestStrategyGame_NoPendingLeavesContentAlone covers ordinary turns
// where the tool was never called — the plugin must not decorate them.
func TestStrategyGame_NoPendingLeavesContentAlone(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	const prose = "Just talking, no game move."
	if got := g.TransformAssistantContent(prose); got != prose {
		t.Errorf("content should be untouched; got %q", got)
	}
	if _, _, ok := g.PendingPluginState(); ok {
		t.Error("no tool call means no pending state to bind")
	}
}

func TestStrategyGame_StripsBlockFromDisplay(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	raw := "Prose here.\n\n" + gameOpenTag + `{"turn":1,"stats":[]}` + gameCloseTag
	if got := g.TransformForDisplay(raw); got != "Prose here." {
		t.Errorf("machine block should not reach the reader; got %q", got)
	}
}

// TestStrategyGame_RendersNativeComponents verifies the block becomes
// real UI rather than JSON in the transcript, using the existing
// component vocabulary so no client change is needed.
func TestStrategyGame_RendersNativeComponents(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	content := g.TransformAssistantContent("The granary is empty.")

	parts := g.RenderContent([]ContentPart{NewTextPart(content)}, "assistant")
	var components []string
	for _, p := range parts {
		if p.Fragment != nil {
			components = append(components, p.Fragment.Component)
		}
	}
	if len(components) != 2 || components[0] != "key_value" || components[1] != "choice_list" {
		t.Fatalf("expected key_value then choice_list; got %v", components)
	}

	// The choice buttons must carry a send action so tapping one plays
	// the turn, and the odds must be on the label.
	var choiceProps struct {
		Items []struct {
			Label  string `json:"label"`
			Value  string `json:"value"`
			Action string `json:"action"`
		} `json:"items"`
	}
	for _, p := range parts {
		if p.Fragment != nil && p.Fragment.Component == "choice_list" {
			if err := json.Unmarshal(p.Fragment.Props, &choiceProps); err != nil {
				t.Fatalf("choice props: %v", err)
			}
		}
	}
	if len(choiceProps.Items) != 2 {
		t.Fatalf("expected 2 choice items; got %d", len(choiceProps.Items))
	}
	for _, it := range choiceProps.Items {
		if it.Action != "send:"+it.Value {
			t.Errorf("choice %q should send its id; got action %q", it.Value, it.Action)
		}
		if !strings.Contains(it.Label, "favorable") || !strings.Contains(it.Label, "disaster") {
			t.Errorf("choice label should carry both odds; got %q", it.Label)
		}
	}
	// Non-assistant roles are left alone.
	userParts := g.RenderContent([]ContentPart{NewTextPart(content)}, "user")
	for _, p := range userParts {
		if p.Fragment != nil {
			t.Error("renderer should only fire on assistant messages")
		}
	}
}

// TestStrategyGame_OddsCanBeHidden verifies the presentation config
// actually reaches the rendered label.
func TestStrategyGame_OddsCanBeHidden(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, `{"show_odds":false}`)
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	content := g.TransformAssistantContent("Prose.")
	if strings.Contains(content, `"show_odds":true`) {
		t.Error("config not honoured in the block")
	}
	parts := g.RenderContent([]ContentPart{NewTextPart(content)}, "assistant")
	for _, p := range parts {
		if p.Fragment != nil && p.Fragment.Component == "choice_list" {
			if strings.Contains(string(p.Fragment.Props), "favorable") {
				t.Error("odds should be omitted when disabled")
			}
		}
	}
}

// TestStrategyGame_PlainProseSurvivesRendering guards a nasty failure
// mode: WalkText splices the callback's return in place of the part, so
// a renderer that returns nil for "nothing to do" deletes the message.
// With this plugin attached to a profile that would silently erase every
// ordinary assistant turn in the conversation.
func TestStrategyGame_PlainProseSurvivesRendering(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	const prose = "No game block in this message at all."

	parts := g.RenderContent([]ContentPart{NewTextPart(prose)}, "assistant")
	if len(parts) != 1 || parts[0].Text != prose {
		t.Fatalf("plain prose must survive rendering intact; got %+v", parts)
	}
}

// TestStrategyGame_MalformedBlockSurvivesAsText follows the house rule
// that a renderer never silently drops model output.
func TestStrategyGame_MalformedBlockSurvivesAsText(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	raw := "Prose.\n\n" + gameOpenTag + `{not json` + gameCloseTag
	parts := g.RenderContent([]ContentPart{NewTextPart(raw)}, "assistant")
	if len(parts) != 1 || parts[0].Fragment != nil {
		t.Fatalf("malformed block should pass through as text; got %+v", parts)
	}
}

// TestPipeline_CollectsPendingState covers the handoff the runtime
// relies on: a tool ran mid-generation with no assistant row to key
// state to, so the plugin holds it and the pipeline surfaces it at
// materialization. Plugins that did nothing this turn must stay silent
// rather than rebinding stale state.
func TestPipeline_CollectsPendingState(t *testing.T) {
	t.Parallel()
	played := newGameForTest(t, "")
	if _, err := played.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	idle := newGameForTest(t, "")
	quiet, err := newBasicGrounding(nil)
	if err != nil {
		t.Fatalf("build grounding: %v", err)
	}

	pending := Pipeline{quiet, idle, played}.PendingPluginStates()
	if len(pending) != 1 {
		t.Fatalf("only the plugin that played should report state; got %d", len(pending))
	}
	if pending[0].PluginName != StrategyGameName {
		t.Errorf("plugin name: got %q", pending[0].PluginName)
	}
	if pending[0].Version != 1 {
		t.Errorf("version: got %d want 1", pending[0].Version)
	}
	if !json.Valid(pending[0].State) {
		t.Error("pending state must be valid JSON — it goes straight into JSONB")
	}
}

// TestStrategyGame_RefusesSecondCommitInOneTurn guards against a model
// that calls the tool twice — retry logic, a confused tool loop, or
// fishing for a better roll. Without the guard the campaign advances
// several turns behind a single narration and only the last state ever
// gets bound to a message.
func TestStrategyGame_RefusesSecondCommitInOneTurn(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	ctx := gameCtx(&stubGameStore{})
	if _, err := g.ExecuteTool(ctx, "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	// Same instance, same send — this is the double-commit the guard exists for.
	_, err := g.ExecuteTool(ctx, "game_commit_turn", json.RawMessage(
		`{"kind":"resolve","choice_id":"A","next_situation":{"id":"x","title":"X","body":"b","choices":[
		  {"id":"A","label":"one","rating":"guile","difficulty":"easy","stakes":"minor","advances":"treasury","costs":"treasury"},
		  {"id":"B","label":"two","rating":"guile","difficulty":"easy","stakes":"minor","advances":"treasury","costs":"treasury"}]}}`))
	if err == nil || !strings.Contains(err.Error(), "already committed") {
		t.Errorf("a second commit in one turn should be refused; got %v", err)
	}
}

// TestStrategyGame_StateVersionConflict verifies the optimistic
// concurrency check rejects a call acting on state that has since moved,
// rather than applying it on top of newer state.
func TestStrategyGame_StateVersionConflict(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	// A campaign already at version 7 on the branch.
	stored := `{"meta":{"schema_version":1,"state_version":7,"turn":4,"ruleset":"governance","seed":9},
	  "public":{"title":"t","role":"r","resources":{"treasury":50},"ratings":{"guile":3},
	    "limits":{"treasury":{"min":0,"max":100},"guile":{"min":0,"max":10}},
	    "loss_when":[{"stat":"treasury","op":"<=","value":0,"label":"broke"}],"turn_limit":20,
	    "situation":{"id":"s","title":"S","body":"b","choices":[
	      {"id":"A","label":"go","rating":"guile","difficulty":"easy","target":8,"modifier":3,
	       "odds":{"favorable":90,"disaster":0},"stakes":"minor","advances":"treasury","costs":"treasury"}]}},
	  "protocol":{"phase":"awaiting_player_action","allowed_commit_kind":"resolve","legal_choice_ids":["A"]}}`
	store := &stubGameStore{state: json.RawMessage(stored), version: 7}

	_, err := g.ExecuteTool(gameCtx(store), "game_commit_turn", json.RawMessage(
		`{"kind":"resolve","expected_state_version":3,"choice_id":"A"}`))
	if err == nil || !strings.Contains(err.Error(), "state conflict") {
		t.Errorf("a stale expected_state_version should be refused; got %v", err)
	}
}

// TestStrategyGame_MatchingVersionProceeds is the other half: the guard
// must not fire on a correct call.
func TestStrategyGame_MatchingVersionProceeds(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	ctx := gameCtx(&stubGameStore{})
	// A fresh campaign has no state, so an expected version cannot
	// conflict — initialize must go through.
	if _, err := g.ExecuteTool(ctx, "game_commit_turn",
		json.RawMessage(strings.Replace(initInput, `"kind": "initialize",`, `"kind": "initialize","expected_state_version":0,`, 1))); err != nil {
		t.Fatalf("initialize with a version hint should proceed: %v", err)
	}
	if _, version, ok := g.PendingPluginState(); !ok || version != 1 {
		t.Errorf("expected version 1 after initialize; got ok=%v v=%d", ok, version)
	}
}

// TestStrategyGame_PricesImprovisedActionWithoutCommitting covers the
// move that justifies running this on a language model: the player says
// something that is not on the list and gets a real, priced gamble.
// Quoting must not change anything — showing odds means committing to
// them, so the player has to see the price before paying it.
func TestStrategyGame_PricesImprovisedActionWithoutCommitting(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	g2, store2 := nextTurn(t, g)

	res, err := g2.ExecuteTool(gameCtx(store2), "game_price_action", json.RawMessage(`{
	  "summary":"Marry my daughter to the duke and buy his cavalry",
	  "rating":"standing","difficulty":"hard","stakes":"major",
	  "advances":"treasury","costs":"standing"}`))
	if err != nil {
		t.Fatalf("price: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(res.Output, &out); err != nil {
		t.Fatalf("output: %v", err)
	}
	if out["quoted"] != true {
		t.Errorf("expected a quote; got %v", out)
	}
	odds, ok := out["odds"].(map[string]any)
	if !ok || odds["favorable"] == nil {
		t.Fatalf("quote must carry real odds; got %v", out["odds"])
	}
	// Nothing was committed: quoting is read-only.
	if _, _, pending := g2.PendingPluginState(); pending {
		t.Error("pricing an action must not commit state")
	}
}

// TestStrategyGame_ImprovisedActionResolvesLikeAnyOther verifies free
// text goes through the same pricing, rolling and effects as a listed
// option. A separate, softer path for improvised play would make
// off-menu actions strictly better than the buttons, and the listed
// options would stop being decisions.
func TestStrategyGame_ImprovisedActionResolvesLikeAnyOther(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	g2, store2 := nextTurn(t, g)

	res, err := g2.ExecuteTool(gameCtx(store2), "game_commit_turn", json.RawMessage(`{
	  "kind":"resolve",
	  "improvised_action":{"label":"Marry into the duchy","rating":"standing","difficulty":"hard",
	    "stakes":"major","advances":"treasury","costs":"standing"},
	  "next_situation":{"id":"after","title":"After","body":"b","choices":[
	    {"id":"A","label":"one","rating":"guile","difficulty":"easy","stakes":"minor","advances":"treasury","costs":"treasury"},
	    {"id":"B","label":"two","rating":"guile","difficulty":"easy","stakes":"minor","advances":"treasury","costs":"treasury"}]}}`))
	if err != nil {
		t.Fatalf("resolve improvised: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(res.Output, &out); err != nil {
		t.Fatalf("output: %v", err)
	}
	if out["outcome"] == nil || out["outcome"] == "" {
		t.Error("an improvised action must resolve to a real outcome band")
	}
	if out["turn"] != float64(2) {
		t.Errorf("the turn should advance; got %v", out["turn"])
	}
}

func TestStrategyGame_ImprovisedRejectsBothForms(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	g2, store2 := nextTurn(t, g)
	_, err := g2.ExecuteTool(gameCtx(store2), "game_commit_turn", json.RawMessage(`{
	  "kind":"resolve","choice_id":"A",
	  "improvised_action":{"label":"both","rating":"guile","difficulty":"easy","stakes":"minor",
	    "advances":"treasury","costs":"treasury"}}`))
	if err == nil || !strings.Contains(err.Error(), "not both") {
		t.Errorf("passing both a choice id and an improvised action should be refused; got %v", err)
	}
}

// TestStrategyGame_ImprovisedRejectsInventedTags proves free text does
// not escape the vocabulary enforcement.
func TestStrategyGame_ImprovisedRejectsInventedTags(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(initInput)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	g2, store2 := nextTurn(t, g)
	_, err := g2.ExecuteTool(gameCtx(store2), "game_price_action", json.RawMessage(`{
	  "summary":"Something clever","rating":"guile","difficulty":"effortless",
	  "stakes":"minor","advances":"treasury","costs":"treasury"}`))
	if err == nil || !strings.Contains(err.Error(), "unknown difficulty") {
		t.Errorf("improvised actions must use the same tag vocabulary; got %v", err)
	}
}

// TestStrategyGame_ClocksSurfaceInTheStatusPanel verifies background
// pressure is visible next to the stats it is eating, at the moment of
// choosing rather than buried in prose.
func TestStrategyGame_ClocksSurfaceInTheStatusPanel(t *testing.T) {
	t.Parallel()
	g := newGameForTest(t, "")
	withClock := strings.Replace(initInput, `"kind": "initialize",`,
		`"kind": "initialize","start_clocks":[{"id":"debt","label":"The creditors call in","length":"medium","weight":"major","drains":"treasury","strikes":"standing","ominous":true}],`, 1)
	if _, err := g.ExecuteTool(gameCtx(&stubGameStore{}), "game_commit_turn", json.RawMessage(withClock)); err != nil {
		t.Fatalf("initialize with clock: %v", err)
	}
	content := g.TransformAssistantContent("The ledgers are grim.")
	parts := g.RenderContent([]ContentPart{NewTextPart(content)}, "assistant")

	var panel string
	for _, p := range parts {
		if p.Fragment != nil && p.Fragment.Component == "key_value" {
			panel = string(p.Fragment.Props)
		}
	}
	if !strings.Contains(panel, "creditors call in") {
		t.Errorf("a running clock should appear in the status panel; got %s", panel)
	}
	if !strings.Contains(panel, "4 turns") {
		t.Errorf("the clock's remaining turns should be visible; got %s", panel)
	}
}
