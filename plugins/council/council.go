// Package council runs a conversation with more than one voice in it.
//
// See docs/design/council.md for the full design and the reasoning behind the
// wire shape.
package council

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/providers"
)

// Name is the registered plugin name. Stable forever: it is a database value
// in profile_plugins and plugin_state.plugin_name.
const Name = "council"

// council turns one assistant into a panel.
//
// Each member speaks as its own assistant message, with its own model and its
// own cost. That is the entire point. One model writing a transcript of a
// panel discussion into a single message is a prompt you can have today for
// free; separate rows are what make the disagreement real, individually
// forkable, and separately priced.
//
// A moderator decides who speaks next and for how long. It never says
// anything, produces no message row, and has no presence in the UI. Its
// decisions are state.
type council struct {
	cfg config

	// directions is the frozen direction for each assistant message on this
	// branch, keyed by message id. Loaded once per send by the server wiring
	// from plugin_state; nil outside a council turn. Safe on the instance
	// because the pipeline is resolved once per send.
	directions map[uuid.UUID]string
}

// SetDirections hands the plugin this branch's frozen directions for the send
// about to happen. Called by the server wiring after loading plugin_state.
func (c *council) SetDirections(d map[uuid.UUID]string) { c.directions = d }

type config struct {
	// Members is the roster, in speaking order for the deterministic router.
	Members []member `json:"members"`

	// MaxExchanges caps a single discussion. Enforced server-side rather than
	// requested in a prompt: two agreeable personas will talk until the money
	// runs out, and a number we enforce is the only thing between a council
	// and an overnight bill.
	MaxExchanges int `json:"max_exchanges,omitempty"`

	// OpeningTokens and DiscussionTokens bound a hop's reply. A directive
	// alone does not work; models are trained to elaborate and will elaborate
	// through a polite request for brevity. This is the only lever that is an
	// actual bound, and it has to agree with the wording of the directive or
	// you get truncation mid-sentence.
	OpeningTokens    int `json:"opening_tokens,omitempty"`
	DiscussionTokens int `json:"discussion_tokens,omitempty"`
}

type member struct {
	// ID keys the roster and the palette slot, so it has to survive renaming
	// and reordering.
	ID string `json:"id"`
	// Name is what the model is told to answer to and what the user reads.
	Name string `json:"name"`
	// ProfileID resolves the member's system prompt, model and plugins.
	ProfileID string `json:"profile_id"`
	// Stance is a one-line summary shown to the other members in the roster,
	// so the panel knows who is who without reading each other's prompts.
	Stance string `json:"stance,omitempty"`
}

// Defaults chosen to make the first discussion feel right rather than to be
// round numbers. Six exchanges is long enough for two members to actually
// disagree and short enough to read. 60 tokens is about two sentences, which
// is what "briefly" has to mean if the cap and the wording are to agree.
const (
	defaultMaxExchanges     = 6
	defaultOpeningTokens    = 1200
	defaultDiscussionTokens = 60
)

func (c *council) maxExchanges() int {
	if c.cfg.MaxExchanges > 0 {
		return c.cfg.MaxExchanges
	}
	return defaultMaxExchanges
}

func (c *council) openingTokens() int {
	if c.cfg.OpeningTokens > 0 {
		return c.cfg.OpeningTokens
	}
	return defaultOpeningTokens
}

func (c *council) discussionTokens() int {
	if c.cfg.DiscussionTokens > 0 {
		return c.cfg.DiscussionTokens
	}
	return defaultDiscussionTokens
}

func newCouncil(raw json.RawMessage) (pluginapi.Plugin, error) {
	var cfg config
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &cfg); err != nil {
			return nil, fmt.Errorf("council: bad config: %w", err)
		}
	}
	seen := map[string]bool{}
	for i, m := range cfg.Members {
		if strings.TrimSpace(m.ID) == "" {
			return nil, fmt.Errorf("council: member %d has no id", i)
		}
		if seen[m.ID] {
			// Duplicate ids would make the speaking ledger ambiguous and give
			// two members the same palette slot.
			return nil, fmt.Errorf("council: duplicate member id %q", m.ID)
		}
		seen[m.ID] = true
		if strings.TrimSpace(m.Name) == "" {
			return nil, fmt.Errorf("council: member %q has no name", m.ID)
		}
	}
	return &council{cfg: cfg}, nil
}

func init() { pluginapi.Register(Name, newCouncil) }

func (c *council) Name() string        { return Name }
func (c *council) DisplayName() string { return "Council" }

func (c *council) Description() string {
	return "Answer with a panel of personas that then discuss the answer, " +
		"each speaking as its own message with its own model."
}

// active reports whether there is a panel at all. A council with fewer than
// two members is an ordinary conversation, and every hook no-ops.
func (c *council) active() bool { return len(c.cfg.Members) >= 2 }

func (c *council) memberByID(id string) (member, int, bool) {
	for i, m := range c.cfg.Members {
		if m.ID == id {
			return m, i, true
		}
	}
	return member{}, 0, false
}

// --- Discussion state ------------------------------------------------------

// discussion is the branch-scoped record of a panel exchange.
//
// Branch-scoped, bound to the assistant message each hop produced, so forking
// carries its own speaking order and its own remaining budget. Exploring an
// alternative argument should not spend the budget of the branch you left.
type discussion struct {
	// Hops is every hop taken so far, oldest first, each holding the
	// direction verbatim as it was issued.
	Hops []hop `json:"hops"`
	// Closed marks a discussion the moderator ended, so a stale continue
	// cannot resurrect it.
	Closed bool `json:"closed,omitempty"`
}

// hop records one turn of the discussion.
//
// Direction is stored rather than recomputed. That is the load-bearing
// decision: it is replayed verbatim into the wire on every later prefix build,
// so if hop six regenerated hop two's wording, the prefix would change at
// position two and every byte after it would be a cache miss. Same
// freeze-at-write-time invariant message_headers has, applied to something
// that is not stored on a message.
type hop struct {
	MemberID  string `json:"member_id"`
	Direction string `json:"direction"`
}

func (d *discussion) used() int { return len(d.Hops) }

func (d *discussion) lastMember() string {
	if len(d.Hops) == 0 {
		return ""
	}
	return d.Hops[len(d.Hops)-1].MemberID
}

// --- Routing ---------------------------------------------------------------

// decision is what a router returns for one hop.
type decision struct {
	MemberID  string
	Direction string
	MaxTokens int
	// End means the discussion is over and no hop should run.
	End bool
}

// route picks the next speaker deterministically: round-robin through the
// roster, a long opener, then short exchanges.
//
// This is not a stepping stone to the model-backed moderator, it is the
// fallback that has to exist regardless. A moderator call that times out or
// returns something unparseable must never block the panel, and having both
// behind one decision shape makes the model moderator's contribution
// measurable rather than assumed.
func (c *council) route(d *discussion) decision {
	if !c.active() || d.Closed {
		return decision{End: true}
	}
	used := d.used()
	if used >= c.maxExchanges() {
		return decision{End: true}
	}

	next := c.cfg.Members[used%len(c.cfg.Members)]
	remaining := c.maxExchanges() - used - 1

	if used == 0 {
		return decision{
			MemberID:  next.ID,
			Direction: c.direction(next, "Answer at length.", remaining),
			MaxTokens: c.openingTokens(),
		}
	}
	return decision{
		MemberID:  next.ID,
		Direction: c.direction(next, "Two sentences at most. One word is a fine answer.", remaining),
		MaxTokens: c.discussionTokens(),
	}
}

// direction renders the moderator's instruction for one hop.
//
// The remaining count is included so the panel can wind down rather than being
// cut off mid-thought by the cap. It is addressed to a named member because
// the same text is what separates two persona turns on the wire, and a turn
// that reads as generic filler teaches the model nothing.
func (c *council) direction(m member, length string, remaining int) string {
	var b strings.Builder
	b.WriteString("[panel] ")
	b.WriteString(m.Name)
	b.WriteString(", your turn. ")
	b.WriteString(length)
	if remaining > 0 {
		b.WriteString(" ")
		b.WriteString(strconv.Itoa(remaining))
		if remaining == 1 {
			b.WriteString(" exchange remains after this one.")
		} else {
			b.WriteString(" exchanges remain after this one.")
		}
	} else {
		b.WriteString(" This is the last turn of the discussion.")
	}
	return b.String()
}

// --- SystemPrompter --------------------------------------------------------

// PrependSystemMessage contributes nothing. The panel description belongs at
// the end of the system slot, after the profile's own instructions, so it
// frames how to answer rather than what to be.
func (c *council) PrependSystemMessage() string { return "" }

// AppendSystemMessage describes the panel to every member.
//
// One shared block, identical for every member, deliberately. Per-member
// system prompts thrash the provider cache when two members share a model:
// they alternate, and each invalidates the other at position zero. Identity
// and length live in the per-hop direction at the tail instead, so the whole
// prefix in front of it is one cache lineage.
func (c *council) AppendSystemMessage() string {
	if !c.active() {
		return ""
	}
	var b strings.Builder
	b.WriteString("\n\nThis conversation is a panel. Several people answer, one at a time, " +
		"and they can see each other's replies. Each reply is tagged with a " +
		`<speaker name="..."/> marker naming who wrote it. The panel is:` + "\n")
	for _, m := range c.cfg.Members {
		b.WriteString("\n- ")
		b.WriteString(m.Name)
		if s := strings.TrimSpace(m.Stance); s != "" {
			b.WriteString(": ")
			b.WriteString(s)
		}
	}
	b.WriteString("\n\nA line beginning [panel] is the moderator telling you who speaks next " +
		"and how long to take. It is not from the user, and the user cannot see it. " +
		"Answer only when it names you, write only your own reply, and never write a " +
		`<speaker/> marker or a [panel] line yourself.` + "\n\n" +
		"Length is an instruction, not a suggestion. When you are asked to be brief, " +
		"be brief. Addressing another member by name and disagreeing in one line is a " +
		"good turn. Examples of good short turns:\n" +
		"\n- \"Agreed.\"\n" +
		"- \"No. The rollback path is untested.\"\n" +
		"- \"That's the cost question, not the safety one.\"")
	return b.String()
}

// --- HistoryTransformer ----------------------------------------------------

// TransformHistoryMessage expands a persona's stored message into the
// direction that preceded it, followed by the message itself.
//
// This is why HistoryTransformer returns a slice. Two persona turns must never
// be adjacent on the wire. Nothing rejects that shape, but Anthropic combines
// consecutive assistant turns into one, which erases the structure saying
// these were different speakers and leaves the model reading a single long
// block of its own prior voice. That is the exact failure a panel exists to
// avoid, and it happens silently, with no error to notice.
//
// The direction is replayed verbatim from state, never re-rendered. Re-render
// it and hop six's build changes hop two's bytes, which invalidates the
// provider cache from that point on every send.
func (c *council) TransformHistoryMessage(msg providers.WireMessage, pos pluginapi.HistoryPos) []providers.WireMessage {
	if !c.active() || msg.Role != "assistant" {
		return pluginapi.OneMessage(msg)
	}
	dir := c.directions[pos.MessageID]
	if dir == "" {
		// An assistant message with no recorded direction: a turn from before
		// the council was attached, or a welcome message. Leave it alone.
		return pluginapi.OneMessage(msg)
	}
	return []providers.WireMessage{
		{Role: "user", Content: dir},
		msg,
	}
}

// MergeDirections folds a hop's directions into a built prefix, applying the
// rule that a direction never lands next to a user turn.
//
// Two consecutive user messages would be combined by the provider anyway. We
// do it ourselves so the bytes are deterministic and ours, rather than
// depending on a join that is undocumented for two of the three drivers. In
// practice this is what puts the opening direction inside the user's own
// message instead of after it.
func MergeDirections(msgs []providers.WireMessage) []providers.WireMessage {
	out := make([]providers.WireMessage, 0, len(msgs))
	for _, m := range msgs {
		if n := len(out); n > 0 && m.Role == "user" && out[n-1].Role == "user" &&
			len(m.ToolResults) == 0 && len(out[n-1].ToolResults) == 0 &&
			len(m.Attachments) == 0 && len(out[n-1].Attachments) == 0 {
			prev := &out[n-1]
			if prev.Content == "" {
				prev.Content = m.Content
			} else if m.Content != "" {
				prev.Content = prev.Content + "\n\n" + m.Content
			}
			continue
		}
		out = append(out, m)
	}
	return out
}
