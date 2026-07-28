# mcp

Bridges an MCP server's tools into a conversation. One plugin instance is one
MCP server. A user attaches this plugin to a profile once per server they want
available, and each instance carries its own transport config.

Display name is "Custom MCP server (advanced)", because attaching one means
knowing what you are pointing it at.

## How it works

`Tools()` runs the `initialize` handshake and `tools/list` against the
configured server, then presents the result as ordinary plugin tools. The
conversations-side tool loop keeps an owner-by-name map, so two MCP plugins on
one profile coexist as long as their tool names do not collide. `tool_prefix`
exists for when they do.

Transports:

- **stdio**: spawn a subprocess, speak newline-delimited JSON-RPC over its pipes.
- **http**: POST to a URL, carrying the negotiated session id.

We speak protocol version `2024-11-05`. Servers negotiate down through the
handshake and we accept whatever they reply with, as long as the connection
succeeds.

Connections are pooled process-wide and reaped after 5 minutes idle. For stdio
that kills the subprocess; for http it drops the cached session id and lets the
server free its own resources. Generous enough that a few minutes between turns
does not cost a cold start, tight enough that a long-idle server does not hold a
process and its memory indefinitely.

Timeouts: 60s per `tools/call`, because MCP servers vary from a sub-millisecond
filesystem read to a slow remote-API wrapper. 30s per HTTP request, which is
cheaper because `tools/list` and `tools/call` exchanges should be fast, and the
slow case (`initialize` on a warming server) is bounded by the call timeout
anyway.

## Host integration

This package owns two entry points that production code outside the plugin
calls directly:

- `RegisterInprocMCPDispatcher`, called from `cmd/psmithd` at startup, wires the
  in-process MCP server so Psmith's own tools are reachable through the same path.
- `TestMCPConnection`, called from `server/profiles`, powers the "test
  connection" button without going through a real send.

Both used to sit in the flat `plugins` package. They live here now and their
callers import `plugins/mcp`.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | Transport and its parameters. |
| `pluginapi.ToolProvider` | Implies a `ToolUse` model requirement. |

## Config

| Field | Applies to |
|---|---|
| `transport` | `stdio` or `http`. |
| `command`, `args`, `env` | stdio. |
| `url`, `headers` | http. |
| `tool_prefix` | both. Disambiguates colliding tool names. |

## Failure modes

- **Server will not start or connect.** `Tools()` returns empty and the failure
  is logged. A broken MCP server degrades the conversation rather than failing
  the send.
- **Tool call times out.** 60s ceiling, error returns as the tool result.
- **Name collision between two instances.** The owner-by-name map resolves to
  one of them. Set `tool_prefix` on at least one.
- **Subprocess dies mid-conversation.** The next call restarts it through the
  pool. State inside the server is not ours to preserve.
