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
	"encoding/json"
)

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// DisplayTransformer rewrites stored content for display at message-fetch
// time. Position-independent — same input always yields the same output for
// a given plugin config.
type DisplayTransformer interface {
	TransformForDisplay(content string) string
}

// AssistantContentTransformer rewrites the assistant's just-finalised
// text BEFORE the message row is inserted: the persisted bytes
// are the post-transform output, so subsequent history builds and
// display reads see the rewritten content forever.
//
// Use cases: strip ANSI/control chars from coding-tool output, watermark
// turns with provider/model metadata, sanitize tool-call cruft. NOT for
// rewrites that need to evolve over time — those live on
// DisplayTransformer (read-time, non-persistent).
type AssistantContentTransformer interface {
	TransformAssistantContent(content string) string
}

// ContentRenderer turns a message's display-time content into a
// structured list of `ContentPart`s the client can render with
// native UI components instead of (or alongside) plain markdown.
// It runs AFTER DisplayTransformer in the pipeline, so the input
// is the post-display-transform text. The output is the same
// shape regardless of whether the renderer wants to do a full
// rewrite, span replacements, or pass-through.
//
// Pipeline mechanics: the first call sees parts =
// [{Text: display_content}]. Each subsequent ContentRenderer
// receives the previous output and is free to walk the parts
// list, split a Text part into [Text, Fragment, Text], or
// replace it entirely. A renderer that doesn't want to do
// anything can return parts unchanged.
//
// All output is DERIVED, not stored. The server re-renders on
// every fetch, so adding/removing a renderer plugin from a
// profile takes effect retroactively across the whole history
// without a backfill job.
//
// See plugins/CONTENT_RENDERERS.md for the full authoring guide,
// component reference, and action vocabulary.
type ContentRenderer interface {
	RenderContent(parts []ContentPart, role string) []ContentPart
}

// ContentPart is one element of the rendered parts list. Exactly
// one of `Text` and `Fragment` is set: a Text part is a literal
// string the client renders as markdown; a Fragment part names
// a typed UI component the client renders with a native view.
//
// The order of parts in the slice is the order they're rendered
// top-to-bottom in the message bubble. Plugins downstream in
// the pipeline see this slice and can split a Text part into
// [Text, Fragment, Text] (e.g. a `mermaid` renderer scanning
// for fenced code blocks) without disturbing the surrounding
// content.
type ContentPart struct {
	// Text is the literal string for a text segment. Empty
	// when Fragment is set.
	Text string
	// Fragment carries a typed UI component description the
	// client renders with a native view. nil when Text is set.
	Fragment *UIFragment
}

// IsText reports whether this part is a literal text segment.
func (p ContentPart) IsText() bool { return p.Fragment == nil }

// UIFragment describes one rendered UI component. The Component
// name keys into the client's renderer registry; Props is the
// component-specific JSON payload (validated client-side per
// the component's documented schema).
//
// Component names are stable identifiers — pinning to literal
// strings at both ends. See `plugins/CONTENT_RENDERERS.md` for
// the canonical component vocabulary + each component's Props
// schema.
type UIFragment struct {
	// Component names the typed UI element. e.g. "card_list",
	// "choice_list", "key_value", "image", "image_grid",
	// "error", "raw_json".
	Component string
	// Props is the component-specific JSON payload. Schema is
	// per-Component; the client's renderer is responsible for
	// validating + falling back to a safe rendering on
	// malformed payloads.
	Props json.RawMessage
	// Key is an optional stable identifier the client uses to
	// preserve view state (selection, scroll position,
	// expansion) across re-renders. Empty when the renderer
	// doesn't need stable identity (most cases).
	Key string
}

// NewTextPart wraps a string as a Text-only ContentPart. Trivial
// helper kept on the package for renderer authors who'd otherwise
// have to remember the struct shape.
func NewTextPart(s string) ContentPart {
	return ContentPart{Text: s}
}

// NewFragmentPart wraps a UIFragment as a ContentPart. The
// component name + props are required; key is optional.
func NewFragmentPart(component string, props json.RawMessage, key string) ContentPart {
	return ContentPart{Fragment: &UIFragment{
		Component: component,
		Props:     props,
		Key:       key,
	}}
}

// WalkText is a convenience for renderers that only need to
// transform Text parts (the common case). For each Text part,
// `fn` is called with the literal string and returns one or
// more replacement parts (a single text part = pure
// transformation; multiple parts = split into text+fragment+text
// or similar). Fragment parts are passed through unchanged.
//
// The result preserves order: each input part's replacement
// is emitted in place. Renderers that need access to Fragment
// parts (e.g. to coalesce adjacent fragments) should walk the
// slice manually instead.
func WalkText(parts []ContentPart, fn func(text string) []ContentPart) []ContentPart {
	out := make([]ContentPart, 0, len(parts))
	for _, part := range parts {
		if !part.IsText() {
			out = append(out, part)
			continue
		}
		replacement := fn(part.Text)
		out = append(out, replacement...)
	}
	return out
}

// TransformForDisplay walks the pipeline, applying every DisplayTransformer
// in order to content.
func (p Pipeline) TransformForDisplay(content string) string {
	for _, pl := range p {
		if t, ok := pl.(DisplayTransformer); ok {
			content = t.TransformForDisplay(content)
		}
	}
	return content
}

func (p Pipeline) TransformAssistantContent(content string) string {
	for _, pl := range p {
		if t, ok := pl.(AssistantContentTransformer); ok {
			content = t.TransformAssistantContent(content)
		}
	}
	return content
}

// RenderContent walks the pipeline, applying every ContentRenderer in
// order to the parts list. The first renderer sees a single Text part
// containing `content` (typically the post-DisplayTransformer string);
// subsequent renderers see whatever the previous one returned, free to
// further split / replace any part.
//
// Returns the final []ContentPart. When no ContentRenderer is in the
// pipeline, returns nil so callers can short-circuit (the wire shape
// then leaves `ui_fragments` empty and the client falls back to
// rendering `display_content` as plain markdown).
//
// `role` is "system" | "context" | "user" | "assistant" |
// "compression_summary"; renderers that should only fire on certain
// roles guard inside their RenderContent.
func (p Pipeline) RenderContent(content string, role string) []ContentPart {
	// Avoid the allocation entirely when no plugin is interested.
	any := false
	for _, pl := range p {
		if _, ok := pl.(ContentRenderer); ok {
			any = true
			break
		}
	}
	if !any {
		return nil
	}
	parts := []ContentPart{NewTextPart(content)}
	for _, pl := range p {
		r, ok := pl.(ContentRenderer)
		if !ok {
			continue
		}
		parts = r.RenderContent(parts, role)
	}
	return parts
}
