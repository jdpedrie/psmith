package council

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/jdpedrie/psmith/pluginapi/host"
)

// The moderator decides who speaks next and for how long. It never says
// anything: it produces no message, has no presence in the UI, and its output
// is state.
//
// It is a second implementation of the same decision the deterministic router
// makes, not a replacement. Every failure path here falls back to round-robin,
// because a panel that goes silent when a cheap model times out is worse than
// a panel that takes turns in order.

// moderatorSystem is the whole instruction. Kept blunt and short: this is a
// routing decision, not a conversation, and every token spent explaining
// nuance is paid on every hop of every discussion.
const moderatorSystem = `You are moderating a panel discussion. You never speak to anyone.
Read the discussion and decide who should speak next.

Reply with JSON only, no prose, in exactly this shape:
{"speaker":"<name>","length":"short"|"long","end":false}

Rules:
- Pick the member with something to add. Do not simply rotate.
- Do not pick whoever just spoke unless they were directly challenged by name.
- "long" is for opening a topic or a substantive disagreement. Everything else
  is "short", and short means one or two sentences.
- Set "end":true when the panel is repeating itself, has converged, or has
  nothing left worth saying. Ending early is a good outcome, not a failure.`

// moderatorDecision is the parsed reply. Fields are deliberately forgiving:
// a model that returns something unusable must degrade to round-robin rather
// than block the turn.
type moderatorDecision struct {
	Speaker string `json:"speaker"`
	Length  string `json:"length"`
	End     bool   `json:"end"`
}

// moderate asks the configured model who speaks next.
//
// Returns ok=false for every failure, and there are many worth naming: no
// model configured, no completer wired, the call errored or timed out, the
// reply was not JSON, the named speaker is not on the roster. Each one falls
// through to the deterministic router. The only thing a moderator failure may
// never do is stop the panel.
func (c *council) moderate(ctx context.Context, d *discussion) (decision, bool) {
	if c.cfg.moderatorProviderID() == "" || c.cfg.moderatorModelID() == "" {
		return decision{}, false
	}
	comp := host.CompleterFrom(ctx)
	if comp == nil {
		return decision{}, false
	}

	raw, err := comp.Complete(ctx,
		c.cfg.moderatorProviderID(), c.cfg.moderatorModelID(),
		moderatorSystem, c.moderatorBrief(d),
		200)
	if err != nil {
		return decision{}, false
	}

	var md moderatorDecision
	if err := json.Unmarshal([]byte(extractJSON(raw)), &md); err != nil {
		return decision{}, false
	}

	remaining := c.maxExchanges() - d.used() - 1
	if md.End {
		return decision{End: true}, true
	}

	m, ok := c.memberByName(md.Speaker)
	if !ok {
		// A hallucinated name is the most likely bad reply, and silently
		// substituting someone would put words in a member's mouth. Fall
		// through instead.
		return decision{}, false
	}

	length := "Two sentences at most. One word is a fine answer."
	tokens := c.discussionTokens()
	if strings.EqualFold(md.Length, "long") {
		length = "Answer at length."
		tokens = c.openingTokens()
	}
	return decision{
		MemberID:  m.ID,
		Direction: c.direction(m, length, remaining),
		MaxTokens: tokens,
	}, true
}

// moderatorBrief is what the moderator reads.
//
// Deliberately a window rather than the whole transcript. The moderator only
// needs the recent shape of the argument to decide who is being challenged,
// and sending the full prefix would make routing cost as much as answering.
// It also keeps the moderator's own cache lineage small and separate.
func (c *council) moderatorBrief(d *discussion) string {
	var b strings.Builder
	b.WriteString("Panel:\n")
	for _, m := range c.cfg.Members {
		b.WriteString("- ")
		b.WriteString(m.Name)
		if s := strings.TrimSpace(m.Stance); s != "" {
			b.WriteString(": ")
			b.WriteString(s)
		}
		b.WriteString("\n")
	}

	b.WriteString("\nRecent turns, oldest first:\n")
	const window = 6
	start := 0
	if len(d.Hops) > window {
		start = len(d.Hops) - window
	}
	if len(d.Hops) == 0 {
		b.WriteString("(none yet — this is the opening turn)\n")
	}
	for _, h := range d.Hops[start:] {
		name := h.MemberID
		if m, _, ok := c.memberByID(h.MemberID); ok {
			name = m.Name
		}
		b.WriteString("- ")
		b.WriteString(name)
		b.WriteString(" spoke")
		if t := strings.TrimSpace(h.Excerpt); t != "" {
			b.WriteString(": ")
			b.WriteString(t)
		}
		b.WriteString("\n")
	}

	remaining := c.maxExchanges() - d.used()
	b.WriteString("\nExchanges remaining: ")
	b.WriteString(itoa(remaining))
	return b.String()
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

func (c *council) memberByName(name string) (member, bool) {
	want := strings.TrimSpace(strings.ToLower(name))
	if want == "" {
		return member{}, false
	}
	for _, m := range c.cfg.Members {
		if strings.ToLower(m.Name) == want {
			return m, true
		}
	}
	return member{}, false
}

// extractJSON pulls the first {...} block out of a reply.
//
// Models wrap JSON in prose or fences even when told not to, and a routing
// decision is too small a thing to lose to a stray "Here you go:". Anything
// that still fails to parse falls back to round-robin.
func extractJSON(s string) string {
	i := strings.Index(s, "{")
	j := strings.LastIndex(s, "}")
	if i < 0 || j < i {
		return s
	}
	return s[i : j+1]
}
