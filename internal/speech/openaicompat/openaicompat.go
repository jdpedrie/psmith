// Package openaicompat is the speech driver for OpenAI's
// /v1/audio/speech API and everything that clones it — which is most
// of the self-hosted TTS world (kokoro-fastapi, openedai-speech
// fronting Piper and XTTS, LocalAI, speaches). A custom base URL plus
// an optional key is the whole self-hosting story; voice and model are
// free-form because a self-hosted server's voices are its own.
package openaicompat

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
	defaultBaseURL = "https://api.openai.com"
	defaultModel   = "gpt-4o-mini-tts"
	defaultVoice   = "alloy"
)

// Config is the decrypted user_tts_config blob for this kind.
type Config struct {
	// APIKey is optional: a LAN Kokoro server has no auth.
	APIKey string `json:"api_key"`
	// BaseURL overrides api.openai.com for self-hosted servers.
	BaseURL string `json:"base_url"`
}

type Driver struct {
	cfg    Config
	client *http.Client
}

func init() {
	speech.Register("openai-compatible", func(configBytes json.RawMessage) (speech.Synthesizer, error) {
		return New(configBytes)
	})
}

func New(configBytes json.RawMessage) (*Driver, error) {
	var cfg Config
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("openai-compatible speech config: %w", err)
		}
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
			"model": orDefault(req.Model, defaultModel),
			"input": segment,
			"voice": orDefault(req.Voice, defaultVoice),
			// "pcm" is s16le 24kHz mono on OpenAI and on the
			// self-hosted clones — exactly the package wire format.
			"response_format": "pcm",
		}
		if req.Speed > 0 {
			body["speed"] = req.Speed
		}
		payload, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, d.cfg.BaseURL+"/v1/audio/speech", bytes.NewReader(payload))
		if err != nil {
			return nil, err
		}
		httpReq.Header.Set("Content-Type", "application/json")
		if d.cfg.APIKey != "" {
			httpReq.Header.Set("Authorization", "Bearer "+d.cfg.APIKey)
		}
		resp, err := d.client.Do(httpReq)
		if err != nil {
			return nil, fmt.Errorf("openai-compatible speech: %w", err)
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
