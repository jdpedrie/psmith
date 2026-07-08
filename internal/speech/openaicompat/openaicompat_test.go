package openaicompat

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
	Model          string  `json:"model"`
	Input          string  `json:"input"`
	Voice          string  `json:"voice"`
	ResponseFormat string  `json:"response_format"`
	Speed          float64 `json:"speed"`
	auth           string
}

func newCaptureServer(t *testing.T, audioPerRequest []byte) (*httptest.Server, func() []captured) {
	t.Helper()
	var mu sync.Mutex
	var reqs []captured
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/audio/speech" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		var c captured
		_ = json.NewDecoder(r.Body).Decode(&c)
		c.auth = r.Header.Get("Authorization")
		mu.Lock()
		reqs = append(reqs, c)
		mu.Unlock()
		w.Header().Set("Content-Type", "audio/pcm")
		_, _ = w.Write(audioPerRequest)
	}))
	return srv, func() []captured {
		mu.Lock()
		defer mu.Unlock()
		return append([]captured(nil), reqs...)
	}
}

func synthesizeAll(t *testing.T, d *Driver, req speech.Request, segments []string) []byte {
	t.Helper()
	in := make(chan string, len(segments))
	for _, s := range segments {
		in <- s
	}
	close(in)
	frames, errs := d.Synthesize(context.Background(), req, in)
	var pcm []byte
	for f := range frames {
		pcm = append(pcm, f.PCM...)
	}
	if err := <-errs; err != nil {
		t.Fatalf("Synthesize: %v", err)
	}
	return pcm
}

func TestSynthesize_RequestShapeAndOrder(t *testing.T) {
	audio := []byte{1, 2, 3, 4}
	srv, reqs := newCaptureServer(t, audio)
	defer srv.Close()

	cfg, _ := json.Marshal(Config{APIKey: "sk-test", BaseURL: srv.URL})
	d, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	pcm := synthesizeAll(t, d, speech.Request{Voice: "nova", Model: "tts-9", Speed: 1.2},
		[]string{"First segment here.", "Second segment here."})

	got := reqs()
	if len(got) != 2 {
		t.Fatalf("want one request per segment, got %d", len(got))
	}
	if got[0].Input != "First segment here." || got[1].Input != "Second segment here." {
		t.Errorf("segment order wrong: %+v", got)
	}
	for _, r := range got {
		if r.Model != "tts-9" || r.Voice != "nova" || r.ResponseFormat != "pcm" || r.Speed != 1.2 {
			t.Errorf("request shape: %+v", r)
		}
		if r.auth != "Bearer sk-test" {
			t.Errorf("auth header: %q", r.auth)
		}
	}
	if len(pcm) != 2*len(audio) {
		t.Errorf("concatenated audio: %d bytes want %d", len(pcm), 2*len(audio))
	}
}

func TestSynthesize_SelfHostedNoAuthAndDefaults(t *testing.T) {
	srv, reqs := newCaptureServer(t, []byte{9})
	defer srv.Close()

	// A LAN Kokoro: base URL, no key.
	cfg, _ := json.Marshal(Config{BaseURL: srv.URL + "/"})
	d, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	_ = synthesizeAll(t, d, speech.Request{}, []string{"A segment long enough to speak."})

	got := reqs()
	if len(got) != 1 {
		t.Fatalf("want 1 request, got %d", len(got))
	}
	if got[0].auth != "" {
		t.Errorf("keyless config must not send Authorization, got %q", got[0].auth)
	}
	if got[0].Model != "gpt-4o-mini-tts" || got[0].Voice != "alloy" {
		t.Errorf("defaults: %+v", got[0])
	}
	if got[0].Speed != 0 {
		t.Errorf("unset speed must be omitted (zero), got %v", got[0].Speed)
	}
}

func TestSynthesize_ProviderErrorSurfaces(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"bad key"}}`))
	}))
	defer srv.Close()

	cfg, _ := json.Marshal(Config{APIKey: "sk-bad", BaseURL: srv.URL})
	d, _ := New(cfg)
	in := make(chan string, 1)
	in <- "Some text to speak aloud."
	close(in)
	frames, errs := d.Synthesize(context.Background(), speech.Request{}, in)
	for range frames {
	}
	err := <-errs
	if err == nil || !strings.Contains(err.Error(), "bad key") {
		t.Fatalf("provider error should surface with body excerpt, got %v", err)
	}
}
