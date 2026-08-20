# codex-app-server

The Psmith provider driver for the Codex CLI. The second `StatefulProvider`
after [claudecode](../claudecode/), built on [codexsdk](../../../codexsdk/).

## Why the handle has three parts

claudecode encodes `model:sessionID`. This encodes `model:threadID:turnID`.

The extra part is not bookkeeping. Codex's `thread/fork` takes a `lastTurnId`,
so a handle can name a specific **turn**, and editing message five forks
exactly there with nothing replayed. Claude Code can only fork from the tip of
whatever it resumed, so its handles have nothing to name.

## Always fork, never resume

A durable handle forks. That is the load-bearing decision and there is a test
that fails if anyone changes it.

Codex's `thread/resume` appends **in place**: the thread id does not change and
the transcript grows. If this driver resumed, a user editing message five would
mutate the very state the branch they forked from depends on, and Psmith's
message tree would quietly stop agreeing with Codex's thread graph. Forking
costs nothing upstream and makes every handle an immutable snapshot, which is
exactly what the `StatefulProvider` contract promises.

## The system prompt is fixed

Codex accepts `baseInstructions` on resume and fork as well as start, so unlike
Claude Code its system prompt is not structurally immutable. This driver pins
it at conversation start anyway and never passes it on a fork, so behaviour is
uniform across harnesses. Otherwise a profile edit would silently rewrite
history's framing the next time a user branched an old message.

## One subprocess, many conversations

The app-server multiplexes threads, so the driver keeps one process and shares
it. Started lazily on the first turn, not in `New` or `StartSession`:
constructing a driver happens on any provider read, and spawning a subprocess
to list models would be rude.

`StartSession` deliberately creates nothing upstream. It returns a provisional
handle and holds the setup in memory; the thread is minted on the first
message. A conversation the user abandons before typing anything would
otherwise leave an empty thread in their Codex history, which is their data.

## What is dropped

Tools, attachments and tool results: the harness has no wire for them from the
caller's side. Sampling knobs in `CallSettings`: no equivalent.

Sandbox and approval policy are **pinned** to `read-only` and `never`. An
earlier version left them to the user's config on the reasoning that Psmith is
borrowing their CLI rather than reconfiguring it. A live turn then hung for ten
minutes: their config is tuned for an agent that edits files, Codex asked the
client to approve something, and a chat harness has nobody sitting behind it to
answer. Read-only with approvals off means there is nothing to ask about, and
the SDK declines any request that arrives regardless, so a config change
upstream cannot bring the hang back.

## Usage and cost

Codex's input count already includes the cached portion, which matches Psmith's
shape, so the two map across without adjustment. Subtracting the cached
fraction would double-count the saving the cost engine computes itself. Zero
reasoning tokens are omitted rather than reported, so a model that does not
reason stays distinguishable from one that reasoned for free.

## Failure modes

- **Turn errored.** No handle is emitted. Emitting one for a failed turn would
  let the next message fork from a broken point.
- **Provisional handle after a restart.** Rejected with an explanation: the
  setup lived only in the old process. Call `StartSession` again.
- **Malformed or unknown handle.** Rejected rather than guessed at.
- **app-server missing or dead.** Surfaces as an error from the first turn that
  needs it, not from provider construction.
- **Approval requested anyway.** Declined by the SDK so the turn proceeds or
  fails, never stalls.
