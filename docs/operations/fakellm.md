# The fake LLM

`fakellm` (under `fakellm/`) is a test harness that stands in for an upstream LLM HTTP API. It runs an `httptest.Server` that speaks the three wire formats Reeve's drivers consume, so a test can drive a real conversation end to end without reaching a real provider, spending tokens, or depending on the network. The point is that the wire parsing actually happens: a test exercises the real SDK, the real driver, the supervisor, and the database path, with only the provider's HTTP endpoint faked. It is the right tool when a test needs the streaming, retry, or tool-loop machinery to run for real; reach for a stubbed driver only when you explicitly want to bypass wire parsing.

## What it speaks

A server is constructed for one flavor, the wire format it emits:

- **`FlavorAnthropic`** — the Anthropic Messages API SSE stream: `message_start`, `content_block_start` / `content_block_delta` / `content_block_stop`, `message_delta` (carrying the terminal usage), `message_stop`.
- **`FlavorOpenAIChat`** — the OpenAI Chat Completions chunked SSE stream: incremental delta chunks, `finish_reason` on the last choice, an optional terminal usage chunk when the request opted in via `stream_options.include_usage`, then `data: [DONE]`.
- **`FlavorOpenAIResponses`** — the OpenAI Responses API SSE event stream: `response.output_text.delta` and friends, terminated by `response.completed`, which carries usage.

These cover all three shipped drivers (anthropic, openai-compatible across both Chat and Responses). See [providers.md](../design/providers.md).

## The model

A test enqueues `Script`s. The server keeps them in a FIFO queue and pops one per inbound request, emitting it as SSE in the flavor's shape. A script is:

- **`Events []Event`** — the emission sequence, in order. Each event is a `text` delta, a `thinking` delta, or one of the tool-call steps (`tool_use_start`, `tool_use_delta`, `tool_use_end`). An event carries its `Text` (for text/thinking), or `ToolName` / `ToolID` / `ToolInput` (for tool steps), and an optional `Delay` slept before the event is written.
- **`Usage *Usage`** — the terminal token tally, emitted in the flavor-correct slot (Anthropic on `message_delta`, OpenAI Chat as a final empty-choices chunk, OpenAI Responses on `response.completed`). Nil means no usage reported. The fields cover input, output, cache-read, cache-write (Anthropic's `cache_creation_input_tokens`), and reasoning tokens (OpenAI only).
- **`Error *ErrorSpec`** — if set, replaces the normal terminator with a failure. A non-zero `HTTPStatus` returns that status with a flavor-shaped JSON error body before the stream opens; a zero status emits an in-stream error in the flavor's shape. This is how the retry and error-materialization paths get tested.

Flavor differences are handled for you. A `thinking` event becomes an Anthropic `thinking_delta` or an OpenAI Responses `reasoning_summary_text.delta`, and is silently dropped on OpenAI Chat (which has no thinking concept). You write one script; the emitter renders it correctly per flavor.

## The server API

```go
fake := fakellm.NewServer(t, fakellm.FlavorAnthropic) // closed via t.Cleanup
fake.Enqueue(fakellm.Script{
    Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Hello"}},
    Usage:  &fakellm.Usage{InputTokens: 10, OutputTokens: 5},
})
// Point the driver under test at fake.URL() as its base URL, drive the
// real flow, then assert on materialized state and on what the driver sent.
reqs := fake.Requests()
```

- **`NewServer(t, flavor)`** starts the server and registers cleanup. The queue and request log are mutex-guarded, so it is safe across goroutines, though a single test usually drives it linearly.
- **`URL()`** is the base URL to wire into the driver's config. For Anthropic, use it directly. For OpenAI-compatible, the SDK expects a `/v1` prefix, so use `URL() + "/v1"` or whatever the driver's config expects.
- **`Enqueue(script)`** appends to the FIFO queue. The next inbound streaming request pops it.
- **`Requests()`** returns a snapshot of every captured request (method, path, headers, raw body) in arrival order. This is how a test asserts the driver sent the right wire shape: the model id, the system prompt, message ordering, the resolved call settings, the tool definitions.
- **`QueueLen()`** reports how many scripts remain unconsumed.

One script is consumed per request. A multi-turn test (for example a tool round-trip, where the model calls a tool and then continues) enqueues one script per upstream call the turn will make.

## How it fits the test stack

The harness is what makes the deterministic integration tests possible. The conversations service tests (`internal/conversations/*_test.go`) send a message, let the supervisor run the turn against the fake, and assert on the materialized message, usage, cost, and tool calls in a real pgtestdb database. The retry test (`internal/stream/retry_fakellm_test.go`) scripts a mid-stream failure to drive the supervisor's reconnect path. The title tests drive the small-model title call against the fake. Because the fake emits real wire bytes, these tests catch parsing regressions that a stubbed driver would hide. See [building-and-codegen.md](building-and-codegen.md) for the test layers and [streaming.md](../design/streaming.md) for the supervisor the tests exercise.

## Gotchas

- **Queue exhaustion is a loud 500.** If a request arrives with no script enqueued, the server returns HTTP 500 with a message saying the test forgot to `Enqueue`. This surfaces the mistake instead of hanging. If you see that 500, you enqueued fewer scripts than the turn made upstream calls (a tool round-trip makes more than one).
- **Base URL `/v1` prefix.** Anthropic points at `URL()`; OpenAI-compatible drivers expect `URL() + "/v1"`. Getting this wrong shows up as 404s against the fake.
- **`Delay` is for timing tests.** Use per-event delays to exercise slow streams, interruption, and back-pressure; leave them zero otherwise.
- **`Usage` and `Error` are effectively exclusive.** An error aborts the stream before final usage would be sent, so a script that sets both will emit the error, not the usage.
- **It only emits streaming SSE.** The drivers stream, so the fake streams. There is no non-streaming completion path.
