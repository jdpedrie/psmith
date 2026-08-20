# codexsdk

Drives the Codex CLI's `app-server` over JSON-RPC. The counterpart to
[`claudesdk`](../claudesdk), and consumed only by
`server/providers/codex`.

## Why app-server and not `codex exec`

Codex has two non-interactive surfaces. Only one can branch.

`codex exec resume <id>` appends to a session in place. Verified against
0.144.1: it returns the **same** `thread_id` and the transcript grows. There is
no fork flag on `exec`, and `codex fork` exists only as an interactive command
with no JSON output, so a driver cannot use it.

`codex app-server` speaks JSON-RPC and has `thread/fork` with a **`lastTurnId`**,
which forks from a specific turn rather than the tip. That is what makes
editing a historical message cheap: fork at the turn before it, send the
replacement, replay nothing. It also has `thread/rollback` if rewinding N turns
is ever wanted.

This is better than what Claude Code offers, where `--fork-session` branches
from the tip of whatever you resumed.

## Why not `pmenglund/codex-sdk-go`

That library does the same job, is Apache 2.0, and is worth reading for how it
handles the protocol's union types. It was not taken as a dependency because it
pins `GeneratedCodexVersion` and enforces a major/minor match against the CLI
it spawns. It targets 0.147.0; this machine runs 0.144.1, so it refuses by
default. Codex's own generated code carries deprecation notes for fields
removed in 0.145, 0.146 and 0.147, so three consecutive minor releases each
broke something. Pinning a generated protocol against a CLI that moves that
fast means the build tracks someone else's release cadence.

## How this stays stable instead

It generates nothing and pins nothing. It sends the handful of fields it needs
and reads the handful it understands, ignoring every other notification the
protocol emits. There are eighty-odd methods and dozens of notifications
covering approvals, sandboxing, filesystem access, MCP and plugins; a chat
harness needs six methods and five notifications. A protocol change breaks this
package only if it touches one of those, rather than every time a type moves.

Regenerate the schema to check what changed:

```
codex app-server generate-json-schema --out /tmp/codexschema
```

## Shape

One `Client` is one subprocess, long-lived and safe for concurrent use: the
app-server multiplexes threads, so one process serves every conversation. That
is the main difference from `claudesdk`, which spawns per query.

- `StartThread` opens a conversation.
- `ResumeThread` reopens one and **mutates** it: the id does not change and a
  turn appends. There is a test pinning that, so nobody mistakes it for a fork.
- `ForkThread(threadID, lastTurnID)` branches, leaving the original untouched.
  The new thread records `ForkedFrom`.
- `Thread.Send` starts a turn and streams `Event`s: text deltas, reasoning
  deltas, usage, done, error.

One turn per thread at a time. A second concurrent `Send` is refused rather
than interleaving two turns' deltas into one channel, which the caller could
not untangle.

## Requests, not just notifications

The protocol sends the client *requests* as well as notifications, and they are
distinguished only by carrying an `id` alongside the `method`. Approvals for
command execution, file changes, tool calls and MCP elicitations all arrive
that way, and the server blocks the turn until it hears back.

Treating one as a notification and dropping it is a hang, not a missed message:
`turn/completed` never arrives and the caller's channel never closes. That cost
a live turn ten minutes before the readLoop learned the difference. Every
server request is now declined, and there is a test with a fake server that
only completes its turn after being answered.

## Failure behaviour

A dead app-server unblocks every in-flight call rather than hanging. A
subscriber that stops draining has its deltas dropped rather than blocking the
read loop that serves every other thread in the process. A retryable error
notification does not end the turn, because Codex is telling us it is handling
the problem.

## Tests

`go test ./codexsdk/` runs offline against a scripted fake app-server built at
test time: a real subprocess, so framing, buffering, lifecycle and
demultiplexing are all exercised.

The live test drives the real binary and spends real tokens, so it is opt-in:

```
PSMITH_LIVE_CODEX=1 go test ./codexsdk/ -run TestLive -v
```

It asserts the property the whole design rests on: forking returns a new id,
the fork's turns land on the branch, and the parent does not know about them.
