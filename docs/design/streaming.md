# Streaming

Streaming is the part Psmith cares most about getting right. A model turn can run for minutes, and the client that started it might background, lose signal, or be swapped for another device mid-stream. The design goal is that none of that loses work or corrupts state. The server owns the stream; the client is a viewer that can come and go.

The mechanism is a supervisor goroutine per run, a durable chunk log, and an in-process pub/sub broker. A client subscribes from a sequence number and gets every chunk after it, whether the run is live or already finished. This document covers the supervisor, the chunk vocabulary, durability and replay, retry, and how a turn materializes into a message.

## The shape of the problem

A naive design streams provider tokens straight to the requesting HTTP connection. When that connection drops, the stream is gone: either the turn dies, or it finishes into a void and the client never sees the result. Psmith decouples the two. The provider stream feeds a supervisor that writes every chunk to Postgres and publishes it to subscribers. The client subscribes over a separate, resumable channel. The run's lifetime is tied to the supervisor, not to any client connection.

## The supervisor

`SendMessage` does the synchronous work (validate, resolve the model and pipeline, persist the user message, build the wire prefix, wrap the tool loop if needed) and then hands a send function to the stream supervisor, which spawns a goroutine for the run and returns. The goroutine owns the run from there.

The supervisor:

1. Calls the provider send function, getting back a channel of chunks.
2. For each chunk, assigns the next sequence number, persists it to `stream_chunks`, and publishes it to the broker. Sequence numbers are per-run and monotonic, and they are the contract the client resumes against.
3. Accumulates the chunks it needs to materialize the final message: text, thinking, tool calls, usage.
4. On the terminal `done` chunk, materializes the assistant message in one transaction, writes the usage and cost columns, and runs the post-materialization hooks (auto-title, Langfuse, cost ledger).
5. On an `error` chunk, materializes an errored assistant message carrying the error payload, so the failure is durable and visible on reload rather than lost with the connection.

The requesting RPC does not block on any of this. It returns once the run is launched, and the client picks up the output by subscribing.

## The chunk vocabulary

Every event in a stream is a chunk with a type. The full set:

- `text_delta` — a piece of visible assistant text.
- `thinking_delta` — a piece of reasoning text (extended thinking).
- `thinking_signature` — the signed seal on an Anthropic thinking block, captured so the block can be replayed verbatim on a later tool round.
- `tool_use_start`, `tool_use_delta`, `tool_use_end` — a tool call being assembled: the name and id, then streamed JSON arguments, then the close.
- `tool_result` — the synthetic chunk the tool loop emits after running a tool, for the live UI and for persistence.
- `device_tool_use` — a request for the connected client to run a device tool (see [tools.md](tools.md)).
- `elicit` — a request for the client to prompt the user for input mid-call.
- `usage` — token counts and provider usage, emitted near the end.
- `error` — a terminal failure; carries the error payload.
- `done` — the terminal success marker.

Intermediate tool rounds never reach the supervisor as `done`. The tool loop swallows each round's `done` and emits exactly one synthetic `done` when the model finally stops calling tools, so a multi-round turn looks like a single stream to the supervisor and to the client.

## Durability and replay

Every chunk is written to `stream_chunks` keyed by run and sequence number before or as it is published. That table is the durable log of the stream. A client subscribes by run id and last-seen sequence; the server replays everything after that sequence from the table, then attaches the client to the live broker feed for anything newer. The handoff is seamless because both sides speak the same sequence numbers.

This is what makes reconnection transparent. A client that backgrounds at sequence 40 and resumes at sequence 40 gets 41 onward, whether the run is still going or finished while it was away. A client that opens a conversation whose last run finished an hour ago replays that run's chunks from the table to reconstruct the streamed message exactly, then sees the terminal `done`.

Because the log is durable, a server restart does not corrupt a finished run: its chunks are on disk and its message materialized. A run that was mid-flight when the process died is the one gap, since the supervisor goroutine is in memory; the client re-fetches conversation state on reconnect and sees the last durable state.

## The broker

The pub/sub broker is in-process and in-memory. A run publishes chunks to it; subscribers attached to that run receive them. It exists so a live stream can fan out to more than one viewer (the same user on two devices) and so the replay-then-attach handoff has a live side to attach to. It holds no durable state; the durability is entirely in `stream_chunks`. A subscriber that falls behind or disconnects just stops receiving, and resubscribes from its last sequence against the durable log.

## Retry

A provider stream can fail partway. The supervisor handles a retryable upstream failure by reconnecting to the provider and continuing, without restarting the visible stream from the top, so the client does not see duplicated text. Non-retryable failures become an `error` chunk and an errored message. The retry logic and the fake-LLM tests that exercise it live alongside the supervisor; the fake LLM can script a mid-stream disconnect to drive the retry path deterministically (see [building-and-codegen.md](../operations/building-and-codegen.md)).

## Materialization

When the run completes, the accumulated chunks become one `messages` row. Visible text becomes the body. Thinking becomes the stored reasoning. Tool calls are re-derived from the chunk stream by a separate aggregator and written as a JSON array to `tool_calls` (the aggregator shares no state with the tool loop; the live `tool_result` chunk and the stored column are reconstructed independently). The usage chunk drives the token and cost columns. An errored run still materializes, carrying its error payload, so it is durable and shows up on reload as a failed turn rather than vanishing.

## Why this shape

Two properties fall out of it. First, the client is thin and replaceable: it holds no authoritative stream state, only a sequence cursor, so any client can attach to any run at any time. Second, work is never lost to a network event: the turn runs to completion on the server regardless of who is watching, and the result is durable the instant it materializes. The cost is that the server carries the whole stream and a Postgres write per chunk, which is the deliberate trade. See [the iOS reference](../clients/ios-reference.md) for how a client consumes this, and [the client spec](../clients/client-spec.md) for the contract any client must honor.
