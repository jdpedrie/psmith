package web

import (
	"net/http/httptest"
	"testing"
)

// An event stream tells proxies not to buffer it: nginx holds a response
// until it ends otherwise, and a held stream shows no reply until it's done.
func TestSSE_HeadersKeepProxiesFromBuffering(t *testing.T) {
	rec := httptest.NewRecorder()
	s, ok := newSSE(rec)
	if !ok {
		t.Fatal("newSSE refused a flushable writer")
	}
	s.event("message", "line one\nline two")
	h := rec.Result().Header
	for k, want := range map[string]string{
		"Content-Type":      "text/event-stream",
		"Cache-Control":     "no-cache",
		"X-Accel-Buffering": "no",
	} {
		if got := h.Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
	if got, want := rec.Body.String(), "event: message\ndata: line one\ndata: line two\n\n"; got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
}
