// Package codexsdk drives the Codex CLI's app-server over JSON-RPC.
//
// Codex has two non-interactive surfaces and only one of them is usable for a
// chat harness. `codex exec resume <id>` appends to a session in place: it
// returns the SAME thread id and mutates the transcript, so there is no way to
// branch. `codex app-server` speaks a JSON-RPC protocol that has thread/fork
// with a lastTurnId, which forks from a specific turn rather than the tip.
// That is what makes editing a historical message possible without replaying
// anything, so this package talks to the app-server.
//
// Scope is deliberately narrow. The protocol has eighty-odd methods covering
// filesystem access, MCP management, plugins, approvals and sandboxing. A chat
// harness needs six. Everything here exists to serve
// server/providers/codex; nothing else in the tree should import it, the same
// arrangement claudesdk has with server/providers/claudecode.
//
// The protocol is marked experimental by Codex itself, and its own code
// carries deprecation notes for fields removed across three consecutive minor
// releases. So this package pins nothing and generates nothing: it sends the
// handful of fields it needs and reads the handful it understands, ignoring
// everything else. A protocol change breaks this package only if it touches
// one of those fields, rather than every time a type moves.
package codexsdk
