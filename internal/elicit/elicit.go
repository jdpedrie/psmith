// Package elicit holds the MCP elicitation primitives shared between
// the MCP server (which exposes the `ctx.Elicit(...)` hook to tool
// implementations) and the conversations service (which implements
// the broker that routes user responses back to the waiting tool).
//
// Lives in its own package to break the dependency cycle that'd
// otherwise exist: mcpserver already imports conversations (it wraps
// the existing Connect services), and if elicit types lived in
// mcpserver the conversations broker would have to import mcpserver
// in turn.
//
// Elicitation = MCP protocol feature added in the 2025-06-18 revision.
// Mid-tool-call, the server requests additional input from the user
// (a confirmation, a choice, a free-form field, a secret). The client
// surfaces a prompt, the user answers, the response routes back to
// the server's in-flight tool call.
//
// Today we support elicitation only on the in-process MCP transport.
// HTTP transport elicitation would require SSE response framing and
// a paired POST channel — deferred until a concrete need surfaces.
// Tools that call Elicit when the inproc dispatcher is absent get
// ErrUnsupported and can degrade gracefully.
package elicit

import (
	"context"
	"encoding/json"
	"errors"
)

// Request mirrors the MCP `elicitation/create` request shape.
// `Message` is the human-readable prompt the client surfaces above
// the form. `RequestedSchema` is a JSON Schema fragment describing
// the expected response — clients render it as a form. The minimal
// subset our UI handles: an object with one or more string / integer
// / boolean properties; string properties may declare
// `"format": "password"` to signal a secure-text rendering (the
// secrets use case).
type Request struct {
	Message         string          `json:"message"`
	RequestedSchema json.RawMessage `json:"requestedSchema"`
}

// Action is the user's top-level response.
type Action string

const (
	// ActionAccept means the user submitted a value; `Content` is the
	// form payload matching `RequestedSchema`.
	ActionAccept Action = "accept"
	// ActionDecline means the user explicitly refused (e.g. tapped
	// "Skip"). Tools should treat as a hard "no" — the user doesn't
	// want to proceed.
	ActionDecline Action = "decline"
	// ActionCancel means the user dismissed the prompt without
	// answering. Tools should typically abort the operation.
	ActionCancel Action = "cancel"
)

// Response is the parsed user response routed back to the tool.
// `Content` is populated only for Accept actions and matches the
// shape requested in the original Request.RequestedSchema.
type Response struct {
	Action  Action          `json:"action"`
	Content json.RawMessage `json:"content,omitempty"`
}

// Client is the hook tools call to ask the user for input. One Client
// binds to one in-flight tool call — implementations own the
// conversation-side state (chunk emission, response broker lookup,
// timeouts) so tools stay transport-agnostic.
type Client interface {
	Elicit(ctx context.Context, req Request) (Response, error)
}

// ErrUnsupported is returned by Elicit when the request flows over a
// transport that doesn't carry elicitation today (HTTP or stdio MCP).
// Tools should catch this and return a graceful degraded result
// rather than panicking.
var ErrUnsupported = errors.New("elicit: not supported on this transport")

type ctxKey struct{}

// WithClient attaches a Client to ctx so downstream tool invocations
// can pull it out via FromContext. Wired by the inproc transport at
// tool-dispatch time; absent on wire transports.
func WithClient(ctx context.Context, c Client) context.Context {
	return context.WithValue(ctx, ctxKey{}, c)
}

// FromContext returns the Client stashed on ctx, or `(nil, false)`
// if none is attached. Tools that want to call Elicit should check
// this and return ErrUnsupported when missing, so an HTTP-attached
// MCP client gets a useful error instead of a nil-pointer panic.
func FromContext(ctx context.Context) (Client, bool) {
	v, ok := ctx.Value(ctxKey{}).(Client)
	return v, ok
}
