package grok

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/jdpedrie/psmith/internal/speech"
)

type captured struct {
	Text         string  `json:"text"`
	VoiceID      string  `json:"voice_id"`
	Language     string  `json:"language"`
	Speed        float64 `json:"speed"`
	OutputFormat struct {
		Codec      string `json:"codec"`
		SampleRate int    `json:"sample_rate"`
	} `json:"output_format"`
	auth string
}

func newCaptureServer(t *testing.T, audioPerRequest []byte) (*httptest.Server, func() []captured) {
	t.Helper()
	var mu sync.Mutex
	var reqs []captured
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/tts" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		var c captured
		_ = json.NewDecoder(r.Body).Decode(&c)
		c.auth = r.Header.Get("Authorization")
		mu.Lock()
		reqs = append(reqs, c)
		mu.Unlock()
		_, _ = w.Write(audioPerRequest)
	}))
	return srv, func() []captured {
		mu.Lock()
		defer mu.Unlock()
		return append([]captured(nil), reqs...)
	}
}

func TestSynthesize_RequestShape(t *testing.T) {
	audio := []byte{5, 6, 7}
	srv, reqs := newCaptureServer(t, audio)
	defer srv.Close()

	cfg, _ := json.Marshal(Config{APIKey: "xai-test", BaseURL: srv.URL})
	d, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	in := make(chan string, 2)
	in <- "The first spoken segment."
	in <- "The second spoken segment."
	close(in)
	frames, errs := d.Synthesize(context.Background(), speech.Request{Voice: "ara", Speed: 1.1}, in)
	var pcm []byte
	for f := range frames {
		pcm = append(pcm, f.PCM...)
	}
	if err := <-errs; err != nil {
		t.Fatalf("Synthesize: %v", err)
	}

	got := reqs()
	if len(got) != 2 {
		t.Fatalf("want one request per segment, got %d", len(got))
	}
	for _, r := range got {
		if r.VoiceID != "ara" || r.Language != "auto" || r.Speed != 1.1 {
			t.Errorf("request shape: %+v", r)
		}
		if r.OutputFormat.Codec != "pcm" || r.OutputFormat.SampleRate != speech.SampleRate {
			t.Errorf("output_format should request the wire PCM: %+v", r.OutputFormat)
		}
		if r.auth != "Bearer xai-test" {
			t.Errorf("auth: %q", r.auth)
		}
	}
	if got[0].Text != "The first spoken segment." {
		t.Errorf("segment order: %+v", got)
	}
	if len(pcm) != 2*len(audio) {
		t.Errorf("audio bytes: %d want %d", len(pcm), 2*len(audio))
	}
}

func TestSynthesize_SpeedClampAndDefaultVoice(t *testing.T) {
	srv, reqs := newCaptureServer(t, []byte{1})
	defer srv.Close()
	cfg, _ := json.Marshal(Config{APIKey: "k", BaseURL: srv.URL})
	d, _ := New(cfg)

	in := make(chan string, 1)
	in <- "Segment for the clamp check."
	close(in)
	frames, errs := d.Synthesize(context.Background(), speech.Request{Speed: 3.0}, in)
	for range frames {
	}
	if err := <-errs; err != nil {
		t.Fatalf("Synthesize: %v", err)
	}
	got := reqs()
	if got[0].Speed != 1.5 {
		t.Errorf("speed should clamp to the documented 1.5 max, got %v", got[0].Speed)
	}
	if got[0].VoiceID != "eve" {
		t.Errorf("default voice should be eve, got %q", got[0].VoiceID)
	}
}

func TestNew_RequiresKey(t *testing.T) {
	if _, err := New(json.RawMessage(`{}`)); err == nil || !strings.Contains(err.Error(), "api_key") {
		t.Fatalf("keyless grok config should fail loudly, got %v", err)
	}
}
