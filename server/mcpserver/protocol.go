// Package mcpserver exposes a curated subset of Psmith's operations
// (profile management, plugin pipeline editing, conversation reads,
// model + provider reads) as Model Context Protocol (MCP) tools served
// over HTTP. The intended use is dogfooding through Psmith's own `mcp`
// plugin so an assistant attached to a profile can read and edit other
// profiles, set up plugin pipelines, and inspect conversation state on
// the same Psmith instance.
//
// The server speaks MCP protocol version 2024-11-05 — the version
// `plugins/mcp.go` already negotiates — so the two are dogfood
// compatible without a version bump on either side.
//
// Authentication piggybacks on the same Bearer-token sessions the
// Connect RPCs use; the user attached to the request context drives
// every tool's data scope. Tools never reach across users.
package mcpserver

import (
	"encoding/json"
	"fmt"
)

// ProtocolVersion advertised in the initialize response. Matches the
// version the psmithd-side mcp client speaks (plugins/mcp.go).
const ProtocolVersion = "2024-11-05"

// JSON-RPC 2.0 envelope. `id` is `string | number` per spec — we keep
// it as RawMessage so we can echo whatever the client sent back
// verbatim without needing to discriminate the type.
type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// JSON-RPC 2.0 standard error codes — the only ones we actually emit.
const (
	rpcCodeParseError     = -32700
	rpcCodeInvalidRequest = -32600
	rpcCodeMethodNotFound = -32601
	rpcCodeInvalidParams  = -32602
	rpcCodeInternalError  = -32603
)

// Tool is one entry in the MCP tools/list response. `InputSchema` is a
// raw JSON Schema document — the model uses it both as a hint and as
// the structure it'll generate when the tool is called.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

// ContentItem is one element in the tools/call result `content` list.
// We only emit text items; images and resources aren't part of the v1
// surface (tools that need to return blobs would add cases here).
type ContentItem struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

// ToolResult is the body of a tools/call response. `IsError=true`
// signals a tool-level failure — distinct from a JSON-RPC protocol
// error, which uses the rpcResponse.Error envelope.
type ToolResult struct {
	Content []ContentItem `json:"content"`
	IsError bool          `json:"isError,omitempty"`
}

// InitializeResult is the body of an initialize response.
type InitializeResult struct {
	ProtocolVersion string            `json:"protocolVersion"`
	Capabilities    map[string]any    `json:"capabilities"`
	ServerInfo      map[string]string `json:"serverInfo"`
}

// textResult wraps an arbitrary serialisable value as a single
// text-content tools/call success. The model receives the JSON as
// the tool result and parses it (every chat-tuned model handles JSON
// reliably). Non-marshalable values fall back to an isError result so
// the failure surfaces in-band.
func textResult(v any) ToolResult {
	body, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return errorResult(fmt.Sprintf("marshal result: %v", err))
	}
	return ToolResult{Content: []ContentItem{{Type: "text", Text: string(body)}}}
}

// errorResult wraps a message as a single isError text-content
// tools/call response. The model sees the error in-band and can
// decide to retry, surface it to the user, or proceed.
func errorResult(msg string) ToolResult {
	return ToolResult{
		IsError: true,
		Content: []ContentItem{{Type: "text", Text: msg}},
	}
}
