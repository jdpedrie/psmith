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
	"encoding/json"
)

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// ToolProvider declares callable tools and executes them. The runtime
// collects Tools() across active plugins to build the wire tools array;
// when the model emits a tool_use, the runtime dispatches ExecuteTool to
// the plugin owning that tool name.
type ToolProvider interface {
	Tools() []ToolDef
	// ExecuteTool returns the tool's structured output (what the
	// model sees on the next round) plus any attachments
	// (images, files) the tool produced. Attachments are
	// persisted with role_hint=tool_result and bound to the
	// assistant message that emitted the tool_use; drivers that
	// support image-in-tool-result blocks (Anthropic, Google)
	// inline them on the next round so the model can see what
	// the tool returned.
	ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error)
}

// ToolDef describes a single callable tool. InputSchema is the raw JSON
// Schema the provider expects on its tools field.
type ToolDef struct {
	Name        string
	Description string
	InputSchema []byte
}

// ToolResult is the full return shape from a tool call. `Output`
// is the JSON the model sees on the next round (treated as the
// tool's textual answer). `Attachments` carry any binary content
// (typically screenshots or generated images) that the tool
// produced — these get persisted on the assistant message and,
// when the upstream provider supports it, ride back into the
// next-round wire prefix as image blocks the model can read.
//
// `CostUSD` is the dollar cost the plugin's upstream API
// charged for this call. Plugins compute it at call time
// (per-token billing × usage from the response, or a flat
// per-call price); the conversations-side tool loop accumulates
// it into the assistant message's `tool_cost_usd` column so the
// chat surface's cost chip reflects total spend (LLM + tools).
// nil = unknown / not billed (typical for free / self-hosted
// tools like brave_search via a personal key, where we don't
// model the spend).
type ToolResult struct {
	Output      json.RawMessage
	Attachments []ToolAttachment
	CostUSD     *float64
}

// ToolAttachment is one binary blob a tool produced (e.g. a
// screenshot from a web-browse tool, a chart from a code-exec
// tool, an image from an MCP server). Mirrors the shape of
// `providers.Attachment` so it slots into the rest of the
// pipeline; `Filename` is optional and used as a download hint.
type ToolAttachment struct {
	// "image" | "document" | "audio" | "video"
	Kind     string
	MimeType string
	Data     []byte
	Filename string
}

// ---------------------------------------------------------------------------
// Registry.
// ---------------------------------------------------------------------------
