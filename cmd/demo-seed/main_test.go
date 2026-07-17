package main

import (
	"strings"
	"testing"
	"time"
)

func TestPickResponseRoutesByKeyword(t *testing.T) {
	cases := []struct {
		prompt      string
		wantContain string
		wantChunk   int
		wantDelay   time.Duration
	}{
		{"please count to 400", "w000", 0, -1},
		{"show me wide output", "Wxyz0123", 24, -1},
		{"show me bullets", "Latency versus throughput", 24, -1},
		{"heavy filler 12", "Paragraph", 2048, time.Millisecond},
		{"write me a long essay", "Section 8", 24, -1},
		{"filler 12 — padding", "settled history", 512, time.Millisecond},
		{"anything else", "Psmith keeps", 24, -1},
	}
	for _, c := range cases {
		text, chunk, delay := pickResponse(c.prompt)
		if !strings.Contains(text, c.wantContain) {
			t.Errorf("pickResponse(%q) text missing %q", c.prompt, c.wantContain)
		}
		if chunk != c.wantChunk {
			t.Errorf("pickResponse(%q) chunk = %d, want %d", c.prompt, chunk, c.wantChunk)
		}
		if c.wantDelay < 0 && delay >= 0 {
			t.Errorf("pickResponse(%q) delay = %v, want flag default (<0)", c.prompt, delay)
		}
		if c.wantDelay >= 0 && delay != c.wantDelay {
			t.Errorf("pickResponse(%q) delay = %v, want %v", c.prompt, delay, c.wantDelay)
		}
	}
}

func TestPickResponseCountIsWordPerChunk(t *testing.T) {
	text, chunk, _ := pickResponse("count")
	if chunk != 0 {
		t.Fatalf("count mode should be word-per-chunk (0), got %d", chunk)
	}
	if !strings.Contains(text, "w000") || !strings.Contains(text, "w399") {
		t.Error("count text should run w000 through w399")
	}
}

func TestLastUserContent(t *testing.T) {
	body := []byte(`{"model":"m","messages":[
		{"role":"system","content":"sys"},
		{"role":"user","content":"first"},
		{"role":"assistant","content":"reply"},
		{"role":"user","content":"second"}
	],"stream":true}`)
	if got := lastUserContent(body); got != "second" {
		t.Errorf("lastUserContent = %q, want %q", got, "second")
	}
	if got := lastUserContent([]byte(`not json`)); got != "" {
		t.Errorf("lastUserContent(invalid) = %q, want empty", got)
	}
	// Multi-part content (arrays) is out of scope — must not panic,
	// must return empty so the canned default applies.
	multi := []byte(`{"messages":[{"role":"user","content":[{"type":"text","text":"x"}]}]}`)
	if got := lastUserContent(multi); got != "" {
		t.Errorf("lastUserContent(multipart) = %q, want empty", got)
	}
}
