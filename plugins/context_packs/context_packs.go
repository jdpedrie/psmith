package contextpacks

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/pluginapi/host"
)

// Name is the registered plugin name. Stable forever — it is a database value
// in profile_plugins and in plugin_state.plugin_name.
const Name = "context_packs"

// contextPacks defers chunks of a profile's context until they are wanted.
//
// The problem it solves: a profile that needs a lot of background has to put
// all of it in the system message, where it is paid for on every turn of every
// conversation whether or not it is relevant. Packs split that. The system
// message carries only what is always true; everything else becomes a named
// pack the user delivers when the conversation reaches it.
//
// A delivered pack rides in the user message's `message_headers`, not its
// content, so the transcript still shows what the user typed and the pack is
// composed into the wire text by the history builder. Envelope values are
// frozen at write time, so a delivered pack is byte-stable on every later
// prefix build and does not disturb the provider-side cache — which matters
// most here, since packs are exactly the large blocks you do not want
// re-sent under a different hash each turn.
//
// The model is told what packs EXIST (name and description) but not their
// contents, so it can say "I would need the deployment runbook for that"
// instead of guessing. Delivery stays a user decision.
type contextPacks struct {
	cfg packsConfig

	// pending carries the post-delivery ledger from the envelope to
	// materialization. A tool-free plugin still needs its write bound to the
	// assistant message rather than to a user row that does not exist yet when
	// the envelope runs. Safe on the instance because the pipeline is resolved
	// once per send and the same instance is asked later.
	pending      []string
	pendingDirty bool
}

type packsConfig struct {
	// Packs is the authored catalog. Stored as a JSON array in a textarea
	// because the plain ConfigField vocabulary cannot express a list of
	// records; a structured editor is a client concern and deliberately not
	// a per-plugin form baked into every app.
	Packs []pack `json:"packs"`
	// AnnounceToModel puts the catalog (names and descriptions only) in the
	// system prompt. On by default: a model that knows a pack exists can ask
	// for it, and that is the whole reason packs carry descriptions.
	AnnounceToModel *bool `json:"announce_to_model,omitempty"`
}

type pack struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Body        string `json:"body"`
}

// ledger is the per-BRANCH record of what has been delivered.
//
// Keyed to the assistant message that closed the turn, so it inherits branch
// scoping for free: fork a conversation before delivering a pack and the fork
// still considers it undelivered, which is the only answer that makes sense
// when the fork never saw the content.
type ledger struct {
	Delivered []string `json:"delivered"`
}

// queue is the per-CONVERSATION record of what the next send will deliver.
//
// Deliberately a different scope from the ledger. Queued-but-unsent intent is
// not branch history, and storing it per branch made it impossible to queue
// anything on a conversation with no messages — which is the first thing a
// user does: open a chat, load the context they know they need, then type.
//
// Server-side rather than client-side so a queued pack survives closing the
// app and a second client sees the same pending state.
type queue struct {
	Armed []string `json:"armed,omitempty"`
}

func (l ledger) has(id string) bool { return contains(l.Delivered, id) }

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

func newContextPacks(configBytes json.RawMessage) (pluginapi.Plugin, error) {
	cfg := packsConfig{}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("context_packs: parse config: %w", err)
		}
	}

	seen := map[string]bool{}
	for i, p := range cfg.Packs {
		if strings.TrimSpace(p.ID) == "" {
			return nil, fmt.Errorf("context_packs: pack %d has no id", i)
		}
		if seen[p.ID] {
			// Duplicate ids would make the ledger ambiguous: delivering one
			// would mark the other delivered too.
			return nil, fmt.Errorf("context_packs: duplicate pack id %q", p.ID)
		}
		seen[p.ID] = true
		if strings.TrimSpace(p.Name) == "" {
			return nil, fmt.Errorf("context_packs: pack %q has no name", p.ID)
		}
	}
	return &contextPacks{cfg: cfg}, nil
}

func init() { pluginapi.Register(Name, newContextPacks) }

func (p *contextPacks) Name() string        { return Name }
func (p *contextPacks) DisplayName() string { return "Context Packs" }

func (p *contextPacks) Description() string {
	return "Split a profile's background into named packs delivered on demand, " +
		"so a long briefing is not paid for on every turn of every conversation."
}

func (p *contextPacks) announces() bool {
	return p.cfg.AnnounceToModel == nil || *p.cfg.AnnounceToModel
}

func (p *contextPacks) find(id string) (pack, bool) {
	for _, pk := range p.cfg.Packs {
		if pk.ID == id {
			return pk, true
		}
	}
	return pack{}, false
}

// --- Configurable ---

func (p *contextPacks) ConfigFields() []pluginapi.ConfigField {
	return []pluginapi.ConfigField{
		{
			Name:    "packs",
			Display: "Packs",
			Description: "JSON array of packs. Each needs a unique `id`, a `name` shown in the " +
				"picker, a short `description` (the model sees this, so write it as a hint " +
				"about when the pack is relevant), and a `body` delivered verbatim. " +
				`e.g. [{"id":"runbook","name":"Deploy runbook","description":"Release steps and rollback","body":"…"}]`,
			Type: pluginapi.ConfigFieldTextarea,
		},
		{
			Name:    "announce_to_model",
			Display: "Tell the model which packs exist",
			Description: "Adds pack names and descriptions (never bodies) to the system prompt so " +
				"the model can say it needs one. Turn off to keep the catalog private.",
			Type:    pluginapi.ConfigFieldBoolean,
			Default: true,
		},
	}
}

// --- SystemPrompter ---

func (p *contextPacks) PrependSystemMessage() string { return "" }

// AppendSystemMessage advertises the catalog without spending the bodies.
//
// Byte-stable for a given config, so it costs one cached prefix rather than
// re-hashing every turn. Deliberately says the model cannot fetch a pack
// itself: without that, a model told a pack exists will invent a tool call for
// it and then narrate a failure.
func (p *contextPacks) AppendSystemMessage() string {
	if !p.announces() || len(p.cfg.Packs) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("\n\nAdditional context is available in packs the user can deliver on request. " +
		"You cannot load one yourself. If a pack would answer the question, say which one you need.\n")
	for _, pk := range p.cfg.Packs {
		b.WriteString("\n- ")
		b.WriteString(pk.Name)
		if d := strings.TrimSpace(pk.Description); d != "" {
			b.WriteString(": ")
			b.WriteString(d)
		}
	}
	return b.String()
}

// --- MessageEnvelope ---

// OutgoingMessageEnvelope delivers whatever is armed, once.
//
// Reads the branch ledger through the store on the context: the envelope runs
// before the user row exists, so the anchor is the branch leaf as it stood
// before this turn. A pack already delivered on this branch is skipped even if
// something armed it again, which makes double-arming harmless rather than
// duplicating a large block into the prefix.
func (p *contextPacks) OutgoingMessageEnvelope(ctx context.Context, _ map[string]string) (header, trailer string) {
	store := host.PluginStateStoreFrom(ctx)
	if store == nil {
		// No store means no way to know what is armed. Silence is right:
		// inventing a delivery here would put a pack in the prefix that the
		// ledger will never record, so it would deliver again on every turn.
		return "", ""
	}
	l := readLedger(ctx, store)
	q := readQueue(ctx, store)

	var blocks []string
	var delivered []string
	for _, id := range q.Armed {
		if l.has(id) {
			continue
		}
		pk, ok := p.find(id)
		if !ok {
			// Armed against a pack since removed from config. Drop it.
			continue
		}
		blocks = append(blocks, renderPack(pk))
		delivered = append(delivered, id)
	}
	if len(blocks) == 0 {
		return "", ""
	}

	// Record on the instance; PendingPluginState hands it to the runtime once
	// the assistant message exists to key it to. The pipeline is resolved once
	// per send, so this is the same instance the runtime asks later.
	p.pending = append(l.Delivered, delivered...)
	p.pendingDirty = true
	// Clear the queue: these are on the wire now, and leaving them armed
	// would show "sends next" forever against something already sent.
	if blob, err := json.Marshal(queue{}); err == nil {
		_ = store.SaveConversation(ctx, blob, ledgerVersion)
	}
	return strings.Join(blocks, "\n\n"), ""
}

func renderPack(pk pack) string {
	return fmt.Sprintf("<context_pack name=%q>\n%s\n</context_pack>", pk.Name, strings.TrimSpace(pk.Body))
}

// --- PendingStateProvider ---

func (p *contextPacks) PendingPluginState() (json.RawMessage, int64, bool) {
	if !p.pendingDirty {
		// The common case: this turn delivered nothing, so the branch ledger
		// must not be rebound. Rewriting it here would move an unchanged
		// ledger onto every assistant message for no reason.
		return nil, 0, false
	}
	blob, err := json.Marshal(ledger{Delivered: p.pending})
	if err != nil {
		return nil, 0, false
	}
	return blob, ledgerVersion, true
}

const ledgerVersion = 1

// readLedger returns what this branch has delivered. Absent state and
// unreadable state both mean "nothing delivered yet": the cost of being wrong
// is re-sending a pack, which is visible and recoverable, where treating a
// read failure as fatal would wedge the plugin entirely.
func readLedger(ctx context.Context, store host.PluginStateStore) ledger {
	raw, _, _, err := store.LoadNearest(ctx)
	if err != nil || len(raw) == 0 {
		return ledger{}
	}
	var l ledger
	if err := json.Unmarshal(raw, &l); err != nil {
		return ledger{}
	}
	return l
}

// readQueue returns what is armed for the next send on this conversation.
func readQueue(ctx context.Context, store host.PluginStateStore) queue {
	raw, _, err := store.LoadConversation(ctx)
	if err != nil || len(raw) == 0 {
		return queue{}
	}
	var q queue
	if err := json.Unmarshal(raw, &q); err != nil {
		return queue{}
	}
	return q
}

// --- PanelProvider ---

func (p *contextPacks) Panel() pluginapi.PanelDescriptor {
	return pluginapi.PanelDescriptor{
		Title:    "Context packs",
		SFSymbol: "shippingbox",
		Subtitle: "Deliver background the model does not have yet",
	}
}

// RenderPanel draws the catalog as a card_list.
//
// Undelivered packs carry an action; delivered ones do not, so the client
// renders them as static rows without a plugin-specific rule for it. Armed
// packs get a badge and a "disarm" action, which is the same verb with a
// different name rather than a second component.
func (p *contextPacks) RenderPanel(ctx context.Context) ([]pluginapi.ContentPart, error) {
	if len(p.cfg.Packs) == 0 {
		return nil, nil
	}
	var l ledger
	var q queue
	if store := host.PluginStateStoreFrom(ctx); store != nil {
		l = readLedger(ctx, store)
		q = readQueue(ctx, store)
	}

	cards := make([]pluginapi.Card, 0, len(p.cfg.Packs))
	for _, pk := range p.cfg.Packs {
		c := pluginapi.Card{Title: pk.Name, Description: pk.Description}
		switch {
		case l.has(pk.ID):
			c.Badges = []string{"Delivered"}
		case contains(q.Armed, pk.ID):
			c.Badges = []string{"Sends next"}
			c.Action = pluginapi.BuildPanelAction("disarm", map[string]string{"id": pk.ID})
		default:
			c.Action = pluginapi.BuildPanelAction("arm", map[string]string{"id": pk.ID})
		}
		cards = append(cards, c)
	}
	return []pluginapi.ContentPart{pluginapi.NewCardListPart("context_packs", cards)}, nil
}

// --- ActionHandler ---

func (p *contextPacks) HandleAction(ctx context.Context, action string, params map[string]string) error {
	store := host.PluginStateStoreFrom(ctx)
	if store == nil {
		return fmt.Errorf("context_packs: no state store in context")
	}
	id := params["id"]
	if _, ok := p.find(id); !ok {
		return fmt.Errorf("context_packs: no pack %q", id)
	}
	l := readLedger(ctx, store)
	q := readQueue(ctx, store)

	switch action {
	case "arm":
		if l.has(id) || contains(q.Armed, id) {
			return nil // idempotent: tapping twice is not an error
		}
		q.Armed = append(q.Armed, id)
	case "disarm":
		out := q.Armed[:0]
		for _, a := range q.Armed {
			if a != id {
				out = append(out, a)
			}
		}
		q.Armed = out
	default:
		return fmt.Errorf("%w: %q", pluginapi.ErrUnknownAction, action)
	}

	sort.Strings(q.Armed)
	blob, err := json.Marshal(q)
	if err != nil {
		return err
	}
	// Conversation-scoped, so this works before the conversation has any
	// messages — which is when a user is most likely to queue context.
	return store.SaveConversation(ctx, blob, ledgerVersion)
}
