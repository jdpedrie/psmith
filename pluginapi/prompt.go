// Package plugins implements Psmith's chat-plugin system. A chat plugin is a
// compiled-in unit that can contribute to the system prompt, transform
// outgoing user messages, mutate stored history at prefix-build time, process
// inbound chunk streams, transform stored content for display, and provide
// tools the model can call.
//
// The required Plugin interface is intentionally tiny — name + display name + description.
// Every behavior is a separate opt-in interface, detected by type assertion
// at the call sites that care. A plugin implements as many sub-interfaces
// as it needs.
//
// See docs/design/plugins.md for the full design.
package pluginapi

import (
	"context"

	"github.com/jdpedrie/psmith/server/providers"
)

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// SystemPrompter contributes to the system slot at prefix-build time.
type SystemPrompter interface {
	// PrependSystemMessage returns text prepended to the system slot.
	// Empty string means "no contribution."
	PrependSystemMessage() string
	// AppendSystemMessage returns text appended to the system slot.
	// Empty string means "no contribution."
	AppendSystemMessage() string
}

// MessageEnvelope contributes header/trailer blocks for the outgoing
// user message. SendMessage persists them in the dedicated
// message_headers / message_trailers columns BESIDE the user's
// content — content stays exactly what the user typed, so edits,
// display, TTS, and embeddings never see the envelope. The history
// builder composes headers + content + trailers into the wire text.
//
// Values are frozen at write time (the same cache-stability contract
// the old persist-the-rewrite approach had): a header carrying "now"
// stays byte-stable on every later prefix build, and edits to the
// content leave the envelope untouched.
//
// The `facts` argument carries device-side context the plugin
// requested via `DeviceFactRequester` (e.g. user locale, current
// location, platform version). Keys are the same strings the
// plugin returned from `RequestedDeviceFacts`. Map may be nil if
// the client didn't supply any — plugins should treat missing
// keys as "not available" rather than failing.
// The context carries the same host capabilities tool dispatch gets
// (PluginStateStore, CallerInfo, …), so a plugin whose envelope depends
// on stored state can read it. Envelope rendering happens inside the
// send, before the user row is written.
type MessageEnvelope interface {
	OutgoingMessageEnvelope(ctx context.Context, facts map[string]string) (header, trailer string)
}

// DeviceFactRequester is the opt-in interface for plugins that
// want device-supplied facts (location, locale, platform, etc.)
// passed alongside the outgoing user content. The returned slice
// is the canonical list of fact keys the plugin understands —
// the client uses it to know what to gather and when to trigger
// OS-level permission prompts.
//
// Standard fact keys (defined in DeviceFactKey* constants):
//   - "locale"          — BCP-47 language tag (e.g. "en-US")
//   - "timezone"        — IANA tz (e.g. "America/New_York")
//   - "platform"        — free-form OS+device (e.g. "iOS 26.5 / iPhone 17 Pro")
//   - "location_city"   — reverse-geocoded human-readable place
//   - "location_coords" — "lat,lng" (e.g. "40.6782,-73.9442")
//
// Plugins may declare new keys ad-hoc; clients ignore keys they
// don't know how to gather. Keep the list short — every key
// translates to potential permission friction or stale-data risk.
type DeviceFactRequester interface {
	RequestedDeviceFacts() []string
}

// Standard device-fact keys understood by basic_grounding and
// any future fact-aware plugins. Keep names stable across
// releases — clients pin to these literal strings.
const (
	DeviceFactKeyLocale         = "locale"
	DeviceFactKeyTimezone       = "timezone"
	DeviceFactKeyPlatform       = "platform"
	DeviceFactKeyLocationCity   = "location_city"
	DeviceFactKeyLocationCoords = "location_coords"
)

// HistoryPos tells a HistoryTransformer where the message sits relative to
// the head of the prefix being built. Both ranks are 0-indexed from the head.
//
//   - FromHead counts ALL messages back. The head (the message about to
//     elicit a response) is FromHead=0; its parent is 1; etc.
//   - FromHeadSameRole counts only messages with the same wire role. The
//     most-recent message of this role is FromHeadSameRole=0; the next is 1;
//     etc. This is the right metric for "keep choices on the last N
//     assistant turns" — independent of how user/assistant rows interleave
//     (which can vary under forks or future tool-use additions).
type HistoryPos struct {
	FromHead         int
	FromHeadSameRole int
	// DestProviderType is the driver the prefix is being built for
	// ("anthropic", "openai-compatible", "google"). Lets a transform
	// vary by provider — e.g. a history rewrite that would break
	// Anthropic's prompt-cache prefix can be skipped on that provider.
	DestProviderType string
}

// HistoryTransformer mutates a history message at prefix-build time.
// Returning the message unchanged is fine; the plugin decides based on
// position whether to apply.
type HistoryTransformer interface {
	TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage
}

// SystemPrompts walks the pipeline and concatenates the prepend/append
// contributions of every SystemPrompter, joining individual contributions
// with newlines. Returns ("", "") for a pipeline without SystemPrompters.
func (p Pipeline) SystemPrompts() (prepend, appendStr string) {
	var prep, app []string
	for _, pl := range p {
		sp, ok := pl.(SystemPrompter)
		if !ok {
			continue
		}
		if s := sp.PrependSystemMessage(); s != "" {
			prep = append(prep, s)
		}
		if s := sp.AppendSystemMessage(); s != "" {
			app = append(app, s)
		}
	}
	prepend = joinNonEmpty(prep, "\n\n")
	appendStr = joinNonEmpty(app, "\n\n")
	return
}

// OutgoingEnvelope collects every MessageEnvelope plugin's header and
// trailer contributions in pipeline order, each side joined with blank
// lines. `facts` is the device-fact envelope (may be nil) — passed
// verbatim to each plugin so those requesting facts can read them.
// Plugins that don't implement the interface are skipped. Empty
// strings mean "no contribution on that side."
func (p Pipeline) OutgoingEnvelope(ctx context.Context, facts map[string]string, decorate func(context.Context, string) context.Context) (headers, trailers string) {
	var hs, ts []string
	for _, pl := range p {
		if t, ok := pl.(MessageEnvelope); ok {
			// Same per-plugin decoration tool dispatch uses, so a
			// stateful envelope can reach its own state and no other
			// plugin's.
			pctx := ctx
			if decorate != nil {
				pctx = decorate(ctx, pl.Name())
			}
			h, tr := t.OutgoingMessageEnvelope(pctx, facts)
			if h != "" {
				hs = append(hs, h)
			}
			if tr != "" {
				ts = append(ts, tr)
			}
		}
	}
	return joinNonEmpty(hs, "\n\n"), joinNonEmpty(ts, "\n\n")
}

// TransformHistoryMessage walks the pipeline, applying every
// HistoryTransformer in order to the given message at the given position.
// Plugins that don't implement the interface are skipped.
func (p Pipeline) TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage {
	for _, pl := range p {
		if t, ok := pl.(HistoryTransformer); ok {
			msg = t.TransformHistoryMessage(msg, pos)
		}
	}
	return msg
}
