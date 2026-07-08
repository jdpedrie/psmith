// Package grok is the speech driver for xAI's TTS API
// (POST https://api.x.ai/v1/tts). Cheap ($4.20/1M chars), 26 voices,
// and a native PCM output format matching the package wire format.
// The credential typically rides in from the user's existing xAI chat
// provider row (credential reuse, see docs/design/speech.md).
package grok

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/jdpedrie/psmith/internal/speech"
)

const (
	defaultBaseURL = "https://api.x.ai"
	defaultVoice   = "eve"
)

// Config is the decrypted user_tts_config blob for this kind.
type Config struct {
	APIKey string `json:"api_key"`
	// BaseURL is overridable for tests and proxies.
	BaseURL string `json:"base_url"`
}

type Driver struct {
	cfg    Config
	client *http.Client
}

func init() {
	speech.Register("grok", func(configBytes json.RawMessage) (speech.Synthesizer, error) {
		return New(configBytes)
	})
}

func New(configBytes json.RawMessage) (*Driver, error) {
	var cfg Config
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("grok speech config: %w", err)
		}
	}
	if cfg.APIKey == "" {
		return nil, fmt.Errorf("grok speech: api_key is required")
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultBaseURL
	}
	cfg.BaseURL = strings.TrimRight(cfg.BaseURL, "/")
	return &Driver{cfg: cfg, client: &http.Client{Timeout: 120 * time.Second}}, nil
}

func (d *Driver) Synthesize(ctx context.Context, req speech.Request, in <-chan string) (<-chan speech.Frame, <-chan error) {
	return speech.RunHTTPSegments(ctx, in, func(ctx context.Context, segment string) (io.ReadCloser, error) {
		body := map[string]any{
			"text":     segment,
			"voice_id": orDefault(req.Voice, defaultVoice),
			"language": "auto",
			// Request the package wire format directly. The docs
			// document codec pcm + 24000 Hz among the supported
			// output_format options; the inner field names below are
			// the best reading of "audio codec and quality settings"
			// — the Test RPC against a real key is the verification
			// path, and a mismatch fails loudly there, not silently.
			"output_format": map[string]any{
				"codec":       "pcm",
				"sample_rate": speech.SampleRate,
			},
			"optimize_streaming_latency": 2,
		}
		if req.Speed > 0 {
			// Documented range 0.7–1.5; clamp rather than erroring so
			// a shared speed setting can't break one provider.
			body["speed"] = min(max(req.Speed, 0.7), 1.5)
		}
		payload, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, d.cfg.BaseURL+"/v1/tts", bytes.NewReader(payload))
		if err != nil {
			return nil, err
		}
		httpReq.Header.Set("Content-Type", "application/json")
		httpReq.Header.Set("Authorization", "Bearer "+d.cfg.APIKey)
		resp, err := d.client.Do(httpReq)
		if err != nil {
			return nil, fmt.Errorf("grok speech: %w", err)
		}
		return speech.CheckHTTPResponse(resp)
	})
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}
