// Package ollama implements embeddings.Embedder against a local Ollama
// instance (or any HTTP endpoint speaking the same `/api/embed` shape).
//
// Why Ollama by default: it's the path of least friction for a self-
// hosted Reeve deployment that already runs local models for chat —
// the same daemon handles both. Swap path is trivial (Register an
// openai/voyage/etc. impl, point the user-config at it).
package ollama

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/jdpedrie/reeve/internal/embeddings"
)

// Name is the registered embedder type. Stored in
// user_embedder_configs.type (when that surface lands) and stable
// across releases — changing it would orphan existing rows.
const Name = "ollama"

const (
	defaultEndpoint = "http://localhost:11434"
	defaultModel    = "nomic-embed-text"
	// nomic-embed-text-v1.5 is 768-dim. The default here matches that
	// model so a zero-config setup just works on a fresh Ollama
	// install with `ollama pull nomic-embed-text`. Different models
	// (mxbai-embed-large at 1024, bge-large at 1024, etc.) must set
	// `dimensions` explicitly — Ollama itself doesn't advertise the
	// dimension before the first call.
	defaultDimensions = 768
	defaultTimeout    = 60 * time.Second
)

// Config is the JSON shape persisted in the per-user embedder row.
// Every field is optional; defaults target a local Ollama with
// nomic-embed-text installed.
type Config struct {
	// Endpoint is the Ollama base URL (without trailing slash).
	// Default: http://localhost:11434.
	Endpoint string `json:"endpoint"`

	// Model is the Ollama model tag (`ollama pull <model>`).
	// Default: nomic-embed-text.
	Model string `json:"model"`

	// Dimensions is the vector length the chosen model produces.
	// Required to match the model; the storage layer reads this to
	// pick the right typed column. Default: 768 (nomic-embed-text).
	Dimensions int `json:"dimensions"`

	// Timeout for a single Embed HTTP call (Go duration string,
	// e.g. "30s"). Default: 60s — embedding a batch of long
	// messages on CPU can take a while.
	Timeout string `json:"timeout"`
}

type embedder struct {
	cfg    Config
	client *http.Client
}

func newEmbedder(configBytes json.RawMessage) (embeddings.Embedder, error) {
	cfg := Config{
		Endpoint:   defaultEndpoint,
		Model:      defaultModel,
		Dimensions: defaultDimensions,
	}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("ollama: parse config: %w", err)
		}
	}
	if cfg.Endpoint == "" {
		cfg.Endpoint = defaultEndpoint
	}
	if cfg.Model == "" {
		cfg.Model = defaultModel
	}
	if cfg.Dimensions <= 0 {
		cfg.Dimensions = defaultDimensions
	}
	timeout := defaultTimeout
	if cfg.Timeout != "" {
		d, err := time.ParseDuration(cfg.Timeout)
		if err != nil {
			return nil, fmt.Errorf("ollama: invalid timeout %q: %w", cfg.Timeout, err)
		}
		timeout = d
	}
	return &embedder{
		cfg:    cfg,
		client: &http.Client{Timeout: timeout},
	}, nil
}

func init() {
	embeddings.Register(Name, newEmbedder)
}

func (e *embedder) Model() string    { return e.cfg.Model }
func (e *embedder) Dimensions() int  { return e.cfg.Dimensions }

// embedRequest is Ollama's `/api/embed` shape (multi-input). Distinct
// from the legacy `/api/embeddings` (single-input) — we use the
// modern endpoint so we can batch.
type embedRequest struct {
	Model string   `json:"model"`
	Input []string `json:"input"`
}

type embedResponse struct {
	Model      string      `json:"model"`
	Embeddings [][]float32 `json:"embeddings"`
}

// Embed posts the inputs as one Ollama batch. We don't sub-batch here:
// Ollama internally handles its own micro-batching against the model's
// context. Callers wrap this in their own outer batching loop when
// embedding many thousands of items at once (e.g. backfill).
func (e *embedder) Embed(ctx context.Context, inputs []string) ([][]float32, error) {
	if len(inputs) == 0 {
		return nil, nil
	}
	body, err := json.Marshal(embedRequest{Model: e.cfg.Model, Input: inputs})
	if err != nil {
		return nil, fmt.Errorf("ollama: marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		e.cfg.Endpoint+"/api/embed", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("ollama: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := e.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ollama: HTTP: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("ollama: HTTP %d: %s", resp.StatusCode, string(b))
	}

	var out embedResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("ollama: decode response: %w", err)
	}
	if len(out.Embeddings) != len(inputs) {
		return nil, fmt.Errorf("ollama: got %d embeddings for %d inputs",
			len(out.Embeddings), len(inputs))
	}
	// Verify the first vector's dimension matches what we advertised.
	// Drift here means cfg.Dimensions is wrong for the chosen model —
	// catch it loudly before the storage layer writes a vector that
	// won't fit the column.
	if len(out.Embeddings[0]) != e.cfg.Dimensions {
		return nil, fmt.Errorf("ollama: model %q returned dim %d, configured %d",
			e.cfg.Model, len(out.Embeddings[0]), e.cfg.Dimensions)
	}
	return out.Embeddings, nil
}
