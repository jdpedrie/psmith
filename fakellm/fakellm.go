// Package fakellm is a test harness for clients of upstream LLM HTTP APIs.
// It runs an httptest.Server that emits SSE in the wire format of a chosen
// flavor (Anthropic Messages API, OpenAI Chat Completions, OpenAI Responses
// API). Tests queue scripted completions; the server pops one per inbound
// request and emits the corresponding SSE bytes.
//
// Typical use:
//
//	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
//	fake.Enqueue(fakellm.Script{
//	    Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Hello"}},
//	    Usage:  &fakellm.Usage{InputTokens: 10, OutputTokens: 5},
//	})
//	// Configure the driver under test with fake.URL() as its base URL.
//	// Drive the real flow; assert on materialized state and fake.Requests().
//
// The harness lets tests cover full round-trips through the SDK + driver +
// supervisor + DB layers without bypassing wire-format parsing.
package fakellm

import (
	"encoding/json"
	"time"
)

// Flavor selects the upstream wire format the server emits.
type Flavor int

const (
	// FlavorAnthropic emits the Anthropic Messages API SSE stream:
	// message_start, content_block_*, message_delta, message_stop.
	FlavorAnthropic Flavor = iota

	// FlavorOpenAIChat emits the OpenAI Chat Completions chunked SSE
	// stream: incremental delta chunks, finish_reason on the last choice,
	// optional terminal usage chunk if the request opted in via
	// stream_options.include_usage, then a `data: [DONE]` terminator.
	FlavorOpenAIChat

	// FlavorOpenAIResponses emits the OpenAI Responses API SSE event
	// stream: response.output_text.delta and similar, terminated by
	// response.completed (which carries usage).
	FlavorOpenAIResponses
)

// Script is one queued completion. The server pops the head of its FIFO queue
// per inbound streaming request and emits Events in order, then Usage (in the
// flavor-correct terminal slot), then a normal terminator — unless Error is
// set, in which case the server emits the error in the flavor-correct shape
// instead of completing normally.
type Script struct {
	// Events emitted in order. Each event's Delay (if any) is honoured
	// before the event is written.
	Events []Event

	// Usage to emit in the terminal slot. Anthropic puts it on
	// message_delta; OpenAI Chat emits a final chunk with empty choices and
	// `usage`; OpenAI Responses puts it on response.completed.
	// Nil means "no usage reported."
	Usage *Usage

	// Error, if set, replaces the normal terminator with an error in the
	// flavor's shape. Mutually exclusive with Usage in practice (errors
	// abort the stream before final usage is sent).
	Error *ErrorSpec
}

// EventType selects what kind of streamed content an Event carries.
type EventType int

const (
	// EventText emits an incremental text delta in the assistant turn.
	EventText EventType = iota

	// EventThinking emits an incremental reasoning / thinking delta.
	// Anthropic encodes as a thinking_delta on a thinking content block;
	// OpenAI Responses uses response.reasoning_summary_text.delta. OpenAI
	// Chat has no thinking concept and silently drops these.
	EventThinking

	// EventToolUseStart begins a tool call. ToolName + ToolID required.
	EventToolUseStart

	// EventToolUseDelta emits a partial tool-input JSON fragment for the
	// currently-open tool call.
	EventToolUseDelta

	// EventToolUseEnd closes the current tool call.
	EventToolUseEnd
)

// Event is a single item in a Script's emission sequence.
type Event struct {
	Type EventType

	// Text is the delta payload for EventText / EventThinking.
	Text string

	// ToolName, ToolID identify the tool call for EventToolUseStart and
	// are echoed on EventToolUseEnd. Ignored for non-tool events.
	ToolName string
	ToolID   string

	// ToolInput is the partial JSON fragment for EventToolUseDelta or the
	// complete arguments JSON for EventToolUseEnd.
	ToolInput json.RawMessage

	// Delay, if non-zero, is slept before this event is emitted. Useful
	// for testing slow streams, interruption, and back-pressure.
	Delay time.Duration
}

// Usage is the terminal token-count tally emitted with the script.
type Usage struct {
	InputTokens     int
	OutputTokens    int
	CacheReadTokens int
	// Anthropic calls this cache_creation_input_tokens; OpenAI doesn't
	// expose a separate write counter.
	CacheWriteTokens int
	// ReasoningTokens is OpenAI-only (CompletionTokensDetails.ReasoningTokens
	// for Chat; OutputTokensDetails.ReasoningTokens for Responses).
	// Anthropic emitters ignore it.
	ReasoningTokens int
}

// ErrorSpec describes how a failure should be reported. If HTTPStatus is
// non-zero the server returns that status with a JSON error body BEFORE
// opening the stream; otherwise the error is emitted as an in-stream event in
// the flavor's shape (Anthropic: error event; OpenAI Responses: response.failed
// or top-level error event; OpenAI Chat: a final chunk with an error field).
type ErrorSpec struct {
	HTTPStatus int    // 0 = in-stream error
	Code       string // provider-specific error code (e.g. "rate_limit_error")
	Message    string
}

// Request is a captured inbound HTTP request to the fake server. Tests use
// this to assert that the driver sent the right wire shape (model id, system
// prompt, message ordering, settings, etc.).
type Request struct {
	Method  string
	Path    string
	Headers map[string][]string
	Body    []byte // raw; tests parse as needed
}
