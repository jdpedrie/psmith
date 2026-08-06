package contextpacks

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/pluginapi/host"
)

// stubStore is an in-memory PluginStateStore. Branch semantics are the real
// store's job and are covered against Postgres in server/conversations; what
// matters here is what the plugin does with whatever it reads back.
type stubStore struct {
	state     json.RawMessage
	convState json.RawMessage
	version   int64
	leaf      uuid.UUID
	saved     int
}

func newStubStore() *stubStore { return &stubStore{leaf: uuid.New()} }

func (s *stubStore) LoadNearest(context.Context) (json.RawMessage, int64, uuid.UUID, error) {
	if len(s.state) == 0 {
		return nil, 0, uuid.Nil, host.ErrNoPluginState
	}
	return s.state, s.version, s.leaf, nil
}

func (s *stubStore) Save(_ context.Context, _ uuid.UUID, state json.RawMessage, version int64) error {
	s.state, s.version, s.saved = state, version, s.saved+1
	return nil
}

func (s *stubStore) LoadConversation(context.Context) (json.RawMessage, int64, error) {
	if len(s.convState) == 0 {
		return nil, 0, host.ErrNoPluginState
	}
	return s.convState, s.version, nil
}

func (s *stubStore) SaveConversation(_ context.Context, state json.RawMessage, _ int64) error {
	s.convState = state
	return nil
}

func (s *stubStore) Leaf() uuid.UUID { return s.leaf }

func (s *stubStore) queue(t *testing.T) queue {
	t.Helper()
	var q queue
	if len(s.convState) == 0 {
		return q
	}
	if err := json.Unmarshal(s.convState, &q); err != nil {
		t.Fatalf("unmarshal stored queue: %v", err)
	}
	return q
}

func (s *stubStore) ledger(t *testing.T) ledger {
	t.Helper()
	var l ledger
	if len(s.state) == 0 {
		return l
	}
	if err := json.Unmarshal(s.state, &l); err != nil {
		t.Fatalf("unmarshal stored ledger: %v", err)
	}
	return l
}

const twoPacks = `{"packs":[
  {"id":"runbook","name":"Deploy runbook","description":"Release steps","body":"RUNBOOK BODY"},
  {"id":"schema","name":"Schema notes","description":"Table layout","body":"SCHEMA BODY"}
]}`

func build(t *testing.T, cfg string) *contextPacks {
	t.Helper()
	p, err := newContextPacks(json.RawMessage(cfg))
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	return p.(*contextPacks)
}

func ctxWith(s host.PluginStateStore) context.Context {
	return host.WithPluginStateStore(context.Background(), s)
}

// --- config -----------------------------------------------------------------

// Duplicate ids would make the ledger ambiguous: delivering one would mark the
// other delivered, and the second pack could never be sent.
func TestConfig_RejectsDuplicateIDs(t *testing.T) {
	t.Parallel()
	_, err := newContextPacks(json.RawMessage(`{"packs":[{"id":"a","name":"A"},{"id":"a","name":"B"}]}`))
	if err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("expected a duplicate-id rejection, got %v", err)
	}
}

func TestConfig_RejectsPackWithoutID(t *testing.T) {
	t.Parallel()
	if _, err := newContextPacks(json.RawMessage(`{"packs":[{"name":"No id"}]}`)); err == nil {
		t.Fatal("a pack with no id cannot be armed or recorded; expected rejection")
	}
}

// Describe introspects plugins with an empty config, so the constructor has to
// tolerate one.
func TestConfig_EmptyIsUsable(t *testing.T) {
	t.Parallel()
	if _, err := newContextPacks(nil); err != nil {
		t.Fatalf("empty config must build: %v", err)
	}
	d, err := pluginapi.Describe(Name)
	if err != nil {
		t.Fatalf("Describe: %v", err)
	}
	if !d.Capabilities.PanelProvider || !d.Capabilities.ActionHandler {
		t.Errorf("panel and action capabilities should be reported: %+v", d.Capabilities)
	}
	if d.Panel.Title == "" {
		t.Error("a panel provider must describe its menu entry")
	}
}

// --- system prompt ----------------------------------------------------------

// The catalog is advertised so the model can ask for a pack; the bodies are
// the whole thing being deferred and must not leak into the prompt.
func TestSystemPrompt_AnnouncesNamesNotBodies(t *testing.T) {
	t.Parallel()
	out := build(t, twoPacks).AppendSystemMessage()

	if !strings.Contains(out, "Deploy runbook") || !strings.Contains(out, "Release steps") {
		t.Errorf("expected names and descriptions: %q", out)
	}
	if strings.Contains(out, "RUNBOOK BODY") || strings.Contains(out, "SCHEMA BODY") {
		t.Error("pack bodies leaked into the system prompt, defeating the point of deferring them")
	}
}

func TestSystemPrompt_SilentWhenAnnounceDisabled(t *testing.T) {
	t.Parallel()
	cfg := `{"announce_to_model":false,"packs":[{"id":"a","name":"A","body":"X"}]}`
	if out := build(t, cfg).AppendSystemMessage(); out != "" {
		t.Errorf("expected silence, got %q", out)
	}
}

// --- delivery ---------------------------------------------------------------

func TestEnvelope_DeliversOnlyArmedPacks(t *testing.T) {
	t.Parallel()
	p := build(t, twoPacks)
	store := newStubStore()
	store.convState = json.RawMessage(`{"armed":["runbook"]}`)

	header, trailer := p.OutgoingMessageEnvelope(ctxWith(store), nil)

	if !strings.Contains(header, "RUNBOOK BODY") {
		t.Errorf("armed pack missing from the envelope: %q", header)
	}
	if strings.Contains(header, "SCHEMA BODY") {
		t.Error("an unarmed pack was delivered")
	}
	if trailer != "" {
		t.Errorf("packs are headers, not trailers: %q", trailer)
	}
}

// The ledger is the guard against re-delivery. Without it a stale arm would
// push a large block into the prefix on every subsequent turn.
func TestEnvelope_SkipsAlreadyDelivered(t *testing.T) {
	t.Parallel()
	p := build(t, twoPacks)
	store := newStubStore()
	store.state = json.RawMessage(`{"delivered":["runbook"]}`)
	store.convState = json.RawMessage(`{"armed":["runbook"]}`)

	header, _ := p.OutgoingMessageEnvelope(ctxWith(store), nil)

	if header != "" {
		t.Errorf("a pack already on this branch must not be sent again: %q", header)
	}
	if _, _, ok := p.PendingPluginState(); ok {
		t.Error("nothing was delivered, so the ledger must not be rebound")
	}
}

// A quiet turn must not rewrite the ledger, or every assistant message would
// carry a redundant copy of unchanged state.
func TestEnvelope_NoArmedPacksLeavesLedgerAlone(t *testing.T) {
	t.Parallel()
	p := build(t, twoPacks)
	store := newStubStore()

	header, _ := p.OutgoingMessageEnvelope(ctxWith(store), nil)

	if header != "" {
		t.Errorf("expected no delivery: %q", header)
	}
	if _, _, ok := p.PendingPluginState(); ok {
		t.Error("an untouched turn must report no pending state")
	}
}

// Delivering has to record, or the same pack ships on every following turn.
func TestEnvelope_RecordsDeliveryForBinding(t *testing.T) {
	t.Parallel()
	p := build(t, twoPacks)
	store := newStubStore()
	store.state = json.RawMessage(`{"delivered":["schema"]}`)
	store.convState = json.RawMessage(`{"armed":["runbook"]}`)

	p.OutgoingMessageEnvelope(ctxWith(store), nil)

	blob, version, ok := p.PendingPluginState()
	if !ok {
		t.Fatal("a delivery must produce state to bind to the assistant message")
	}
	if version != ledgerVersion {
		t.Errorf("version: got %d want %d", version, ledgerVersion)
	}
	var l ledger
	if err := json.Unmarshal(blob, &l); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !l.has("runbook") || !l.has("schema") {
		t.Errorf("the new ledger must keep prior deliveries and add this one: %+v", l)
	}
	if q := store.queue(t); len(q.Armed) != 0 {
		t.Errorf("a delivered pack must be cleared from the queue, or the panel says "+
			"\"sends next\" forever against something already sent: %+v", q.Armed)
	}
}

// Without a store the plugin cannot know what is armed OR record what it sent.
// Delivering anyway would re-send it forever, so silence is the safe answer.
func TestEnvelope_SilentWithoutStore(t *testing.T) {
	t.Parallel()
	header, _ := build(t, twoPacks).OutgoingMessageEnvelope(context.Background(), nil)
	if header != "" {
		t.Errorf("expected no delivery without a store: %q", header)
	}
}

// --- actions ----------------------------------------------------------------

func TestAction_ArmThenDisarm(t *testing.T) {
	t.Parallel()
	p := build(t, twoPacks)
	store := newStubStore()
	ctx := ctxWith(store)

	if err := p.HandleAction(ctx, "arm", map[string]string{"id": "runbook"}); err != nil {
		t.Fatalf("arm: %v", err)
	}
	if !contains(store.queue(t).Armed, "runbook") {
		t.Fatalf("arm did not persist: %+v", store.queue(t))
	}

	if err := p.HandleAction(ctx, "disarm", map[string]string{"id": "runbook"}); err != nil {
		t.Fatalf("disarm: %v", err)
	}
	if contains(store.queue(t).Armed, "runbook") {
		t.Errorf("disarm did not clear: %+v", store.queue(t))
	}
}

// Tapping a row twice is a normal accident, not an error, and must not queue
// the pack twice.
func TestAction_ArmIsIdempotent(t *testing.T) {
	t.Parallel()
	p := build(t, twoPacks)
	store := newStubStore()
	ctx := ctxWith(store)

	for range 3 {
		if err := p.HandleAction(ctx, "arm", map[string]string{"id": "runbook"}); err != nil {
			t.Fatalf("arm: %v", err)
		}
	}
	if got := store.queue(t).Armed; len(got) != 1 {
		t.Errorf("expected one armed entry, got %v", got)
	}
}

func TestAction_RejectsUnknownPack(t *testing.T) {
	t.Parallel()
	err := build(t, twoPacks).HandleAction(ctxWith(newStubStore()), "arm", map[string]string{"id": "nope"})
	if err == nil {
		t.Fatal("arming a pack that does not exist must fail loudly")
	}
}

// Clients can be newer than servers, so an unrecognised action is version skew
// to report rather than something to guess at.
func TestAction_RejectsUnknownVerb(t *testing.T) {
	t.Parallel()
	err := build(t, twoPacks).HandleAction(ctxWith(newStubStore()), "explode", map[string]string{"id": "runbook"})
	if err == nil || !strings.Contains(err.Error(), "unknown plugin action") {
		t.Fatalf("expected an unknown-action error, got %v", err)
	}
}

// --- panel ------------------------------------------------------------------

// The panel is a card_list so clients render it with the fragment renderer
// they already have. If this stops emitting one, every client silently shows
// an empty sheet.
func TestPanel_RendersStatePerPack(t *testing.T) {
	t.Parallel()
	p := build(t, twoPacks)
	store := newStubStore()
	store.state = json.RawMessage(`{"delivered":["schema"]}`)
	store.convState = json.RawMessage(`{"armed":["runbook"]}`)

	parts, err := p.RenderPanel(ctxWith(store))
	if err != nil {
		t.Fatalf("RenderPanel: %v", err)
	}
	if len(parts) != 1 || parts[0].Fragment == nil || parts[0].Fragment.Component != "card_list" {
		t.Fatalf("expected one card_list fragment, got %+v", parts)
	}

	var props struct {
		Items []pluginapi.Card `json:"items"`
	}
	if err := json.Unmarshal(parts[0].Fragment.Props, &props); err != nil {
		t.Fatalf("unmarshal props: %v", err)
	}
	if len(props.Items) != 2 {
		t.Fatalf("expected a row per pack, got %d", len(props.Items))
	}

	byTitle := map[string]pluginapi.Card{}
	for _, c := range props.Items {
		byTitle[c.Title] = c
	}

	delivered := byTitle["Schema notes"]
	if len(delivered.Badges) == 0 || delivered.Badges[0] != "Delivered" {
		t.Errorf("a delivered pack should say so: %+v", delivered)
	}
	if delivered.Action != "" {
		t.Error("a delivered pack has nothing left to do and must not be actionable")
	}

	armed := byTitle["Deploy runbook"]
	if armed.Action == "" || !strings.Contains(armed.Action, "disarm") {
		t.Errorf("an armed pack should offer to disarm: %+v", armed)
	}
}

func TestPanel_EmptyCatalogRendersNothing(t *testing.T) {
	t.Parallel()
	parts, err := build(t, `{"packs":[]}`).RenderPanel(ctxWith(newStubStore()))
	if err != nil {
		t.Fatalf("an empty catalog is not an error: %v", err)
	}
	if len(parts) != 0 {
		t.Errorf("expected no parts, got %d", len(parts))
	}
}

// --- action encoding --------------------------------------------------------

func TestPanelAction_RoundTrips(t *testing.T) {
	t.Parallel()
	raw := pluginapi.BuildPanelAction("arm", map[string]string{"id": "a b&c"})
	action, params, ok := pluginapi.ParsePanelAction(raw)
	if !ok {
		t.Fatalf("failed to parse own output: %q", raw)
	}
	if action != "arm" {
		t.Errorf("action: %q", action)
	}
	if params["id"] != "a b&c" {
		t.Errorf("params did not survive escaping: %q", params["id"])
	}
}

func TestPanelAction_IgnoresOtherSchemes(t *testing.T) {
	t.Parallel()
	for _, raw := range []string{"compose:hello", "send:go", "external:https://x", "", "plugin:"} {
		if _, _, ok := pluginapi.ParsePanelAction(raw); ok {
			t.Errorf("%q should not parse as a plugin action", raw)
		}
	}
}
