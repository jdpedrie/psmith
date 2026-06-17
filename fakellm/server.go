package fakellm

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// Server is a fake upstream LLM HTTP server backed by httptest.Server.
// Construct via NewServer; the underlying server is closed automatically via
// t.Cleanup. Safe for use from multiple goroutines (the queue and the request
// log are mutex-guarded) but a single test typically uses one server linearly.
type Server struct {
	flavor Flavor
	srv    *httptest.Server

	mu       sync.Mutex
	queue    []Script
	requests []Request
}

// NewServer starts a server that emits in the given flavor.
func NewServer(t *testing.T, flavor Flavor) *Server {
	t.Helper()
	s := &Server{flavor: flavor}
	s.srv = httptest.NewServer(http.HandlerFunc(s.handle))
	t.Cleanup(s.srv.Close)
	return s
}

// URL returns the base URL to wire into the driver under test's config. For
// Anthropic, point base_url at this URL. For OpenAI-compat, point base_url at
// URL() + "/v1" or just URL() depending on whether the driver expects the
// /v1 prefix in its config (the openai-go SDK does — typical OpenAI base_url
// values include /v1).
func (s *Server) URL() string { return s.srv.URL }

// Enqueue appends a Script to the FIFO queue. The next inbound streaming
// request pops it and emits it.
func (s *Server) Enqueue(script Script) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.queue = append(s.queue, script)
}

// Requests returns a snapshot of all captured requests in arrival order.
func (s *Server) Requests() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Request, len(s.requests))
	copy(out, s.requests)
	return out
}

// QueueLen reports how many enqueued Scripts remain unconsumed.
func (s *Server) QueueLen() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.queue)
}

// pop removes and returns the head Script. Returns ok=false when the queue
// is empty — handlers should respond with an HTTP 500 in that case so test
// failures surface clearly rather than hanging.
func (s *Server) pop() (Script, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.queue) == 0 {
		return Script{}, false
	}
	head := s.queue[0]
	s.queue = s.queue[1:]
	return head, true
}

// recordRequest captures the inbound request for later inspection.
func (s *Server) recordRequest(r *http.Request, body []byte) {
	headers := make(map[string][]string, len(r.Header))
	for k, v := range r.Header {
		dup := make([]string, len(v))
		copy(dup, v)
		headers[k] = dup
	}
	s.mu.Lock()
	s.requests = append(s.requests, Request{
		Method:  r.Method,
		Path:    r.URL.Path,
		Headers: headers,
		Body:    body,
	})
	s.mu.Unlock()
}

// handle is the single dispatch entry point. It reads + records the body,
// pops a Script, and routes to the flavor's emitter.
func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf("fakellm: read body: %v", err), http.StatusBadRequest)
		return
	}
	s.recordRequest(r, body)

	script, ok := s.pop()
	if !ok {
		http.Error(w, "fakellm: no script enqueued for incoming request — test forgot to Enqueue", http.StatusInternalServerError)
		return
	}

	// Pre-stream HTTP error: return the status with a JSON error body in
	// the flavor's shape and don't open the stream.
	if script.Error != nil && script.Error.HTTPStatus != 0 {
		writeHTTPError(w, s.flavor, *script.Error)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "fakellm: ResponseWriter not a Flusher; can't stream", http.StatusInternalServerError)
		return
	}

	// SSE headers expected by the SDK parsers.
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	switch s.flavor {
	case FlavorAnthropic:
		emitAnthropic(r.Context(), w, flusher, script)
	case FlavorOpenAIChat:
		emitOpenAIChat(r.Context(), w, flusher, script)
	case FlavorOpenAIResponses:
		emitOpenAIResponses(r.Context(), w, flusher, script)
	default:
		// Should be unreachable — Flavor is set at construction.
		http.Error(w, fmt.Sprintf("fakellm: unknown flavor %d", s.flavor), http.StatusInternalServerError)
	}
}

// writeHTTPError returns a flavor-shaped JSON error body with the given status.
// Both Anthropic and OpenAI use a top-level {"type":"error","error":{...}} or
// similar envelope; both SDKs handle the structural variation gracefully so we
// emit a minimally-shared shape.
func writeHTTPError(w http.ResponseWriter, flavor Flavor, e ErrorSpec) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(e.HTTPStatus)
	switch flavor {
	case FlavorAnthropic:
		fmt.Fprintf(w, `{"type":"error","error":{"type":%q,"message":%q}}`,
			coalesceErrCode(e.Code, "api_error"), e.Message)
	default: // OpenAI variants
		fmt.Fprintf(w, `{"error":{"message":%q,"type":%q,"code":%q}}`,
			e.Message, "invalid_request_error", coalesceErrCode(e.Code, "error"))
	}
}

func coalesceErrCode(s, fallback string) string {
	if s != "" {
		return s
	}
	return fallback
}
