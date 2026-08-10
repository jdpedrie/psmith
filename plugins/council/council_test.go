package council

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/providers"
)

func build(t *testing.T, cfg string) *council {
	t.Helper()
	p, err := newCouncil(json.RawMessage(cfg))
	if err != nil {
		t.Fatalf("newCouncil: %v", err)
	}
	return p.(*council)
}

const threeMembers = `{"members":[
  {"id":"a","name":"Skeptic","stance":"looks for what breaks"},
  {"id":"b","name":"Optimist","stance":"looks for what works"},
  {"id":"c","name":"Historian","stance":"remembers the last time"}
]}`

// --- Config ---------------------------------------------------------------

func TestConfig_RejectsDuplicateMemberIDs(t *testing.T) {
	_, err := newCouncil(json.RawMessage(`{"members":[{"id":"a","name":"A"},{"id":"a","name":"B"}]}`))
	if err == nil {
		t.Fatal("duplicate ids must be rejected: they make the ledger ambiguous")
	}
}

func TestConfig_RejectsMemberWithoutName(t *testing.T) {
	if _, err := newCouncil(json.RawMessage(`{"members":[{"id":"a"}]}`)); err == nil {
		t.Fatal("a member with no name must be rejected")
	}
}

// A council needs a panel. One member is an ordinary conversation and every
// hook has to no-op, or attaching the plugin half-configured would corrupt an
// otherwise normal chat.
func TestInactive_WithFewerThanTwoMembers(t *testing.T) {
	for _, cfg := range []string{`{}`, `{"members":[{"id":"a","name":"Solo"}]}`} {
		c := build(t, cfg)
		if c.active() {
			t.Errorf("config %s should be inactive", cfg)
		}
		if got := c.AppendSystemMessage(); got != "" {
			t.Errorf("inactive council contributed a system prompt: %q", got)
		}
		if d := c.route(&discussion{}); !d.End {
			t.Error("inactive council should not route a hop")
		}
	}
}

// --- Routing --------------------------------------------------------------

func TestRoute_RoundRobinInRosterOrder(t *testing.T) {
	c := build(t, threeMembers)
	d := &discussion{}
	want := []string{"a", "b", "c", "a", "b", "c"}
	for i, w := range want {
		got := c.route(d)
		if got.End {
			t.Fatalf("hop %d ended early", i)
		}
		if got.MemberID != w {
			t.Fatalf("hop %d: got %q want %q", i, got.MemberID, w)
		}
		d.Hops = append(d.Hops, hop{MemberID: got.MemberID, Direction: got.Direction})
	}
}

// The opener is long and everything after it is short. That shape is the
// feature: one real answer, then the panel arguing about it.
func TestRoute_LongOpenerThenShort(t *testing.T) {
	c := build(t, threeMembers)
	d := &discussion{}

	opener := c.route(d)
	if opener.MaxTokens != defaultOpeningTokens {
		t.Errorf("opener max tokens = %d want %d", opener.MaxTokens, defaultOpeningTokens)
	}
	if !strings.Contains(opener.Direction, "at length") {
		t.Errorf("opener should ask for length: %q", opener.Direction)
	}

	d.Hops = append(d.Hops, hop{MemberID: opener.MemberID, Direction: opener.Direction})
	second := c.route(d)
	if second.MaxTokens != defaultDiscussionTokens {
		t.Errorf("discussion max tokens = %d want %d", second.MaxTokens, defaultDiscussionTokens)
	}
	if !strings.Contains(second.Direction, "Two sentences at most") {
		t.Errorf("discussion turn should ask for brevity: %q", second.Direction)
	}
}

// The cap is the only thing between a council and an overnight bill, so it is
// enforced rather than requested.
func TestRoute_StopsAtMaxExchanges(t *testing.T) {
	c := build(t, `{"members":[{"id":"a","name":"A"},{"id":"b","name":"B"}],"max_exchanges":3}`)
	d := &discussion{}
	for i := 0; i < 3; i++ {
		got := c.route(d)
		if got.End {
			t.Fatalf("ended at hop %d, before the cap", i)
		}
		d.Hops = append(d.Hops, hop{MemberID: got.MemberID, Direction: got.Direction})
	}
	if !c.route(d).End {
		t.Fatal("router must stop once the cap is reached")
	}
}

func TestRoute_ClosedDiscussionNeverResumes(t *testing.T) {
	c := build(t, threeMembers)
	if !c.route(&discussion{Closed: true}).End {
		t.Fatal("a closed discussion must not produce another hop")
	}
}

// The panel is told how much room is left so it can wind down, rather than
// being cut off mid-thought by the token cap.
func TestDirection_CarriesRemainingCount(t *testing.T) {
	c := build(t, `{"members":[{"id":"a","name":"A"},{"id":"b","name":"B"}],"max_exchanges":3}`)
	d := &discussion{}

	first := c.route(d)
	if !strings.Contains(first.Direction, "2 exchanges remain") {
		t.Errorf("first direction should say 2 remain: %q", first.Direction)
	}
	d.Hops = append(d.Hops, hop{MemberID: first.MemberID, Direction: first.Direction})

	second := c.route(d)
	if !strings.Contains(second.Direction, "1 exchange remains") {
		t.Errorf("second direction should say 1 remains (singular): %q", second.Direction)
	}
	d.Hops = append(d.Hops, hop{MemberID: second.MemberID, Direction: second.Direction})

	last := c.route(d)
	if !strings.Contains(last.Direction, "last turn") {
		t.Errorf("final direction should say it is the last: %q", last.Direction)
	}
}

func TestDirection_NamesTheSpeaker(t *testing.T) {
	c := build(t, threeMembers)
	got := c.route(&discussion{}).Direction
	if !strings.Contains(got, "Skeptic") {
		t.Errorf("direction should name the member: %q", got)
	}
	if !strings.HasPrefix(got, "[panel]") {
		t.Errorf("direction should be recognisable as moderator framing: %q", got)
	}
}

// --- System prompt --------------------------------------------------------

// One shared block, identical for every member. Per-member system prompts
// thrash the provider cache when two members share a model.
func TestSystemPrompt_ListsTheRosterAndIsMemberIndependent(t *testing.T) {
	c := build(t, threeMembers)
	got := c.AppendSystemMessage()
	for _, name := range []string{"Skeptic", "Optimist", "Historian"} {
		if !strings.Contains(got, name) {
			t.Errorf("roster missing %q", name)
		}
	}
	if !strings.Contains(got, "looks for what breaks") {
		t.Error("stance should be included so members know who is who")
	}
	// Calling it twice must produce identical bytes: it is the cached prefix.
	if c.AppendSystemMessage() != got {
		t.Error("system prompt must be byte-stable across calls")
	}
}

func TestSystemPrompt_ForbidsWritingTheFraming(t *testing.T) {
	got := build(t, threeMembers).AppendSystemMessage()
	for _, want := range []string{"[panel]", "speaker", "cannot see"} {
		if !strings.Contains(got, want) {
			t.Errorf("system prompt should explain %q: %q", want, got)
		}
	}
}

// Models copy shape from examples far more reliably than they follow
// instructions about length.
func TestSystemPrompt_ShowsShortTurnExamples(t *testing.T) {
	got := build(t, threeMembers).AppendSystemMessage()
	if !strings.Contains(got, `"Agreed."`) {
		t.Errorf("expected a one-word example turn: %q", got)
	}
}

// --- History expansion ----------------------------------------------------

func TestTransform_InsertsDirectionBeforeItsMessage(t *testing.T) {
	c := build(t, threeMembers)
	id := uuid.New()
	c.SetDirections(map[uuid.UUID]string{id: "[panel] Optimist, your turn."})

	got := c.TransformHistoryMessage(
		providers.WireMessage{Role: "assistant", Content: "reply"},
		pluginapi.HistoryPos{MessageID: id},
	)
	if len(got) != 2 {
		t.Fatalf("expected direction + message, got %d", len(got))
	}
	if got[0].Role != "user" || !strings.Contains(got[0].Content, "Optimist") {
		t.Errorf("first message should be the direction: %+v", got[0])
	}
	if got[1].Role != "assistant" || got[1].Content != "reply" {
		t.Errorf("second message should be the reply: %+v", got[1])
	}
}

// An assistant message with no recorded direction predates the council or is a
// welcome message. Inventing a direction for it would both lie and move bytes.
func TestTransform_LeavesUnknownAssistantMessagesAlone(t *testing.T) {
	c := build(t, threeMembers)
	c.SetDirections(map[uuid.UUID]string{uuid.New(): "[panel] someone else"})
	got := c.TransformHistoryMessage(
		providers.WireMessage{Role: "assistant", Content: "old reply"},
		pluginapi.HistoryPos{MessageID: uuid.New()},
	)
	if len(got) != 1 || got[0].Content != "old reply" {
		t.Fatalf("unexpected rewrite: %+v", got)
	}
}

func TestTransform_LeavesUserMessagesAlone(t *testing.T) {
	c := build(t, threeMembers)
	id := uuid.New()
	c.SetDirections(map[uuid.UUID]string{id: "[panel] x"})
	got := c.TransformHistoryMessage(
		providers.WireMessage{Role: "user", Content: "question"},
		pluginapi.HistoryPos{MessageID: id},
	)
	if len(got) != 1 {
		t.Fatalf("user messages must pass through: %+v", got)
	}
}

// The direction is replayed from state, never re-rendered. Re-rendering would
// change hop two's bytes on hop six's build and invalidate the cache from
// there on every send.
func TestTransform_ReplaysStoredTextVerbatim(t *testing.T) {
	c := build(t, threeMembers)
	id := uuid.New()
	const frozen = "[panel] Skeptic, your turn. Wording from an older build."
	c.SetDirections(map[uuid.UUID]string{id: frozen})

	got := c.TransformHistoryMessage(
		providers.WireMessage{Role: "assistant", Content: "x"},
		pluginapi.HistoryPos{MessageID: id},
	)
	if got[0].Content != frozen {
		t.Errorf("direction was re-rendered: got %q want %q", got[0].Content, frozen)
	}
}

// --- The invariant --------------------------------------------------------

// No provider reports this violation. Anthropic silently combines the turns,
// which erases the structure saying these were different speakers. So it has
// to be asserted directly.
func TestExpansion_NoTwoPersonaTurnsEndUpAdjacent(t *testing.T) {
	c := build(t, threeMembers)
	ids := []uuid.UUID{uuid.New(), uuid.New(), uuid.New()}
	dirs := map[uuid.UUID]string{}
	for i, id := range ids {
		dirs[id] = "[panel] member " + string(rune('A'+i))
	}
	c.SetDirections(dirs)

	// A user question followed by three persona replies, the shape a
	// discussion produces.
	var out []providers.WireMessage
	out = append(out, providers.WireMessage{Role: "user", Content: "q"})
	for _, id := range ids {
		out = append(out, c.TransformHistoryMessage(
			providers.WireMessage{Role: "assistant", Content: "reply"},
			pluginapi.HistoryPos{MessageID: id},
		)...)
	}
	out = MergeDirections(out)

	for i := 1; i < len(out); i++ {
		if out[i].Role == out[i-1].Role {
			t.Fatalf("adjacent %q turns at %d: %s", out[i].Role, i, roleList(out))
		}
	}
}

// --- MergeDirections ------------------------------------------------------

// The opening direction has to land inside the user's own message. Left as its
// own turn it would sit next to the user's question, and the provider would
// combine them on its own terms rather than ours.
func TestMergeDirections_FoldsIntoAPrecedingUserTurn(t *testing.T) {
	got := MergeDirections([]providers.WireMessage{
		{Role: "user", Content: "What should we do?"},
		{Role: "user", Content: "[panel] Skeptic, your turn."},
		{Role: "assistant", Content: "reply"},
	})
	if len(got) != 2 {
		t.Fatalf("expected the direction folded in, got %s", roleList(got))
	}
	if !strings.Contains(got[0].Content, "What should we do?") ||
		!strings.Contains(got[0].Content, "[panel]") {
		t.Errorf("merged content lost a side: %q", got[0].Content)
	}
}

func TestMergeDirections_LeavesToolAndAttachmentTurnsAlone(t *testing.T) {
	got := MergeDirections([]providers.WireMessage{
		{Role: "user", ToolResults: []providers.ToolResultBlock{{ToolUseID: "t"}}},
		{Role: "user", Content: "[panel] next"},
	})
	if len(got) != 2 {
		t.Fatalf("tool-result turns must not absorb a direction: %s", roleList(got))
	}
	got = MergeDirections([]providers.WireMessage{
		{Role: "user", Content: "look", Attachments: []providers.Attachment{{MimeType: "image/png"}}},
		{Role: "user", Content: "[panel] next"},
	})
	if len(got) != 2 {
		t.Fatalf("attachment turns must not absorb a direction: %s", roleList(got))
	}
}

func roleList(msgs []providers.WireMessage) string {
	parts := make([]string, len(msgs))
	for i, m := range msgs {
		parts[i] = m.Role
	}
	return strings.Join(parts, ",")
}

// The signature hazard that bit twice while widening the interface: a plugin
// that keeps the old shape silently stops satisfying it and gets skipped.
var _ pluginapi.HistoryTransformer = (*council)(nil)
var _ pluginapi.SystemPrompter = (*council)(nil)
