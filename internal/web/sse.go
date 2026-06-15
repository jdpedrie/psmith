package web

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/a-h/templ"
)

// sseStream writes plain Server-Sent Events for htmx's SSE extension to
// consume (named events whose data is swapped into sse-swap targets).
type sseStream struct {
	w http.ResponseWriter
	f http.Flusher
}

// newSSE prepares w for an SSE response. Returns ok=false if the writer can't
// flush (so streaming isn't possible).
func newSSE(w http.ResponseWriter) (*sseStream, bool) {
	f, ok := w.(http.Flusher)
	if !ok {
		return nil, false
	}
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	f.Flush()
	return &sseStream{w: w, f: f}, true
}

// event writes one named SSE event. Multi-line data is split into the spec's
// repeated `data:` lines; htmx rejoins them with newlines.
func (s *sseStream) event(name, data string) {
	fmt.Fprintf(s.w, "event: %s\n", name)
	for _, line := range strings.Split(data, "\n") {
		fmt.Fprintf(s.w, "data: %s\n", line)
	}
	fmt.Fprint(s.w, "\n")
	s.f.Flush()
}

// renderComp renders a templ component to a string (for embedding in SSE data).
func renderComp(ctx context.Context, c templ.Component) string {
	var b strings.Builder
	_ = c.Render(ctx, &b)
	return b.String()
}
