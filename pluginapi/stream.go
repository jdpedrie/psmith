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
	"github.com/jdpedrie/psmith/server/providers"
)

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// ChunkTransformer is a stream processor running inside the supervisor.
// NewInboundProcessor returns a fresh per-stream instance so internal state
// is isolated.
type ChunkTransformer interface {
	NewInboundProcessor() InboundProcessor
}

// InboundProcessor processes one stream's chunks. Process may return zero or
// more output chunks per input (buffering is allowed). Close emits any
// buffered residue at stream end.
type InboundProcessor interface {
	Process(providers.Chunk) []providers.Chunk
	Close() []providers.Chunk
}

// StreamingTagProvider is an optional sub-interface for plugins that
// emit `<tag>body</tag>` blocks the client should render inline as
// they stream. The returned list is surfaced on the Conversation
// proto so the client can identify completed blocks mid-stream and
// hand them to the matching renderer — no JSON-flash before terminal.
//
// Each StreamingTag carries the bare tag NAME (the wire shape is
// fixed at `<{name}>...</{name}>`) and the renderer component name
// to use for the parsed body. Plugins that don't implement this
// interface contribute nothing to the streaming-render list; their
// content still renders correctly at terminal via RenderContent.
type StreamingTagProvider interface {
	StreamingTags() []StreamingTag
}

// StreamingTag is one (tag-name, renderer-component) pair contributed
// by a plugin. The wire shape is fixed: `<{Tag}>body</{Tag}>`.
type StreamingTag struct {
	Tag       string
	Component string
}

// StreamingTags aggregates contributions from every plugin in the
// pipeline that implements StreamingTagProvider. Duplicate tags (two
// plugins claiming the same name) keep first-seen wins — pipeline
// order is the deterministic tiebreaker.
func (p Pipeline) StreamingTags() []StreamingTag {
	var out []StreamingTag
	seen := make(map[string]bool)
	for _, pl := range p {
		provider, ok := pl.(StreamingTagProvider)
		if !ok {
			continue
		}
		for _, t := range provider.StreamingTags() {
			if t.Tag == "" || t.Component == "" {
				continue
			}
			if seen[t.Tag] {
				continue
			}
			seen[t.Tag] = true
			out = append(out, t)
		}
	}
	return out
}
