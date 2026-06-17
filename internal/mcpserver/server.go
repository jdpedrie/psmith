package mcpserver

import (
	"context"
	"encoding/json"
	"log/slog"
	"sort"

	"github.com/jdpedrie/spalt/internal/conversations"
	"github.com/jdpedrie/spalt/internal/modelproviders"
	"github.com/jdpedrie/spalt/internal/profiles"
)

// ToolFunc is the contract every tool implementation satisfies. The
// caller (HandleRPC) puts the authenticated user on `ctx` before
// invoking — tools should pull it via auth.MustFromContext. Return an
// error only for protocol-level failures (bad arguments are reported
// in-band as ToolResult.IsError); the dispatcher converts a non-nil
// error into an isError ToolResult.
type ToolFunc func(ctx context.Context, args json.RawMessage) (ToolResult, error)

// Server is the MCP server core. Stateless beyond the immutable tool
// registry; one Server instance handles every request from every user.
type Server struct {
	profilesSvc       *profiles.Service
	conversationsSvc  *conversations.Service
	modelProvidersSvc *modelproviders.Service
	log               *slog.Logger
	tools             map[string]registeredTool
}

type registeredTool struct {
	tool Tool
	fn   ToolFunc
}

// New constructs a Server with the provided service handles. The
// registry is populated synchronously in registerTools() so the first
// tools/list call after construction is fully populated.
func New(
	profilesSvc *profiles.Service,
	conversationsSvc *conversations.Service,
	modelProvidersSvc *modelproviders.Service,
	log *slog.Logger,
) *Server {
	if log == nil {
		log = slog.Default()
	}
	s := &Server{
		profilesSvc:       profilesSvc,
		conversationsSvc:  conversationsSvc,
		modelProvidersSvc: modelProvidersSvc,
		log:               log,
		tools:             make(map[string]registeredTool),
	}
	s.registerTools()
	return s
}

// register adds a tool to the registry. `schema` is a raw JSON Schema
// document — passed as a string so the call sites stay legible (the
// alternative is `json.RawMessage([]byte(...))` which adds noise).
func (s *Server) register(name, description, schema string, fn ToolFunc) {
	s.tools[name] = registeredTool{
		tool: Tool{
			Name:        name,
			Description: description,
			InputSchema: json.RawMessage(schema),
		},
		fn: fn,
	}
}

// HandleRPC dispatches one JSON-RPC request and returns the bytes the
// HTTP handler should write back. Returns (nil, nil) for notifications
// (no `id` set on the request) — the HTTP handler should reply with
// 202 Accepted and no body.
//
// Protocol-level failures (parse error, unknown method) become
// JSON-RPC error responses. Tool-level failures (unknown tool name,
// bad arguments, business-logic error) become tools/call success
// responses with IsError=true so the model sees them in-band.
func (s *Server) HandleRPC(ctx context.Context, body []byte) ([]byte, error) {
	var req rpcRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return s.errResponse(nil, rpcCodeParseError, "parse error: "+err.Error()), nil
	}
	if req.JSONRPC != "2.0" {
		return s.errResponse(req.ID, rpcCodeInvalidRequest, "invalid request: jsonrpc must be 2.0"), nil
	}

	switch req.Method {
	case "initialize":
		return s.okResponse(req.ID, InitializeResult{
			ProtocolVersion: ProtocolVersion,
			Capabilities:    map[string]any{"tools": map[string]any{}},
			ServerInfo:      map[string]string{"name": "spalt", "version": "0.1"},
		})

	case "notifications/initialized", "notifications/cancelled":
		// Notifications carry no id and expect no response. The HTTP
		// handler turns nil bytes into 202 Accepted + empty body.
		return nil, nil

	case "tools/list":
		out := struct {
			Tools []Tool `json:"tools"`
		}{Tools: s.toolList()}
		return s.okResponse(req.ID, out)

	case "tools/call":
		return s.dispatchToolCall(ctx, req)

	case "ping":
		// MCP defines `ping` as a liveness probe with empty result.
		return s.okResponse(req.ID, map[string]any{})

	default:
		return s.errResponse(req.ID, rpcCodeMethodNotFound, "method not found: "+req.Method), nil
	}
}

// toolList returns the registered tools sorted by name. Stable order
// is helpful both for clients that hash the list and for test diffs.
func (s *Server) toolList() []Tool {
	out := make([]Tool, 0, len(s.tools))
	for _, rt := range s.tools {
		out = append(out, rt.tool)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (s *Server) dispatchToolCall(ctx context.Context, req rpcRequest) ([]byte, error) {
	var params struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return s.errResponse(req.ID, rpcCodeInvalidParams, "invalid params: "+err.Error()), nil
	}
	rt, ok := s.tools[params.Name]
	if !ok {
		return s.okResponse(req.ID, errorResult("unknown tool: "+params.Name))
	}
	args := params.Arguments
	if len(args) == 0 {
		args = json.RawMessage(`{}`)
	}
	res, err := rt.fn(ctx, args)
	if err != nil {
		return s.okResponse(req.ID, errorResult("tool error: "+err.Error()))
	}
	return s.okResponse(req.ID, res)
}

func (s *Server) okResponse(id json.RawMessage, result any) ([]byte, error) {
	body, err := json.Marshal(result)
	if err != nil {
		return s.errResponse(id, rpcCodeInternalError, "marshal result: "+err.Error()), nil
	}
	resp := rpcResponse{JSONRPC: "2.0", ID: id, Result: body}
	return json.Marshal(resp)
}

func (s *Server) errResponse(id json.RawMessage, code int, msg string) []byte {
	resp := rpcResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &rpcError{Code: code, Message: msg},
	}
	body, _ := json.Marshal(resp)
	return body
}

// registerTools wires every tool implementation. Lives here so a
// reader gets the full inventory in one place; the implementations
// live in tools_*.go files alongside their schemas.
func (s *Server) registerTools() {
	s.registerProfileTools()
	s.registerModelTools()
	s.registerConversationTools()
}
