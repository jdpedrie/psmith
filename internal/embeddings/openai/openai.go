// Package openai implements embeddings.Embedder against any
// OpenAI-compatible `/v1/embeddings` endpoint. Out of the box it
// targets a local Ollama (which exposes `/v1/embeddings` alongside
// its native `/api/embed`), but the exact same driver hits real
// OpenAI, Voyage, Together, Lambda, vLLM-served local models, or
// anything else speaking the same shape — only the base_url +
// model + api_key change.
//
// The OpenAI wire contract:
//
//	POST {base_url}/embeddings
//	Authorization: Bearer {api_key}    (omitted when api_key empty;
//	                                    Ollama doesn't authenticate)
//	{
//	  "model": "text-embedding-3-small",
//	  "input": ["text1", "text2", ...]
//	}
//
// Response:
//
//	{
//	  "data": [{"embedding": [...], "index": 0}, ...],
//	  "model": "...",
//	  "usage": {"prompt_tokens": ..., "total_tokens": ...}
//	}
package openai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"time"

	"github.com/jdpedrie/psmith/internal/embeddings"
)

// Name is the registered embedder type. Stored in
// user_embedder_configs.type and stable across releases —
// changing it would orphan existing rows.
const Name = "openai"

const (
	// Defaults target a local Ollama at the standard port. Pointing
	// at real OpenAI is one config line: set base_url to
	// "https://api.openai.com/v1" and supply an api_key.
	defaultBaseURL    = "http://localhost:11434/v1"
	defaultModel      = "nomic-embed-text"
	defaultDimensions = 768
	defaultTimeout    = 60 * time.Second
)

// Config is the JSON shape persisted in the per-user embedder row.
// Every field is optional; defaults target a local Ollama with
// nomic-embed-text installed.
type Config struct {
	// BaseURL is the OpenAI-compatible base, ending in /v1 (the
	// driver appends "/embeddings"). Default
	// "http://localhost:11434/v1" — Ollama's OAI-compat endpoint.
	BaseURL string `json:"base_url"`

	// Model is the embedder model name. Default
	// "nomic-embed-text". For real OpenAI: "text-embedding-3-small"
	// or "text-embedding-3-large".
	Model string `json:"model"`

	// Dimensions is the vector length the chosen model produces.
	// Default 768 (nomic-embed-text). OpenAI's
	// text-embedding-3-small is 1536; text-embedding-3-large is
	// 3072. Some models support dimension truncation via the
	// `dimensions` request param — not surfaced in v1.
	Dimensions int `json:"dimensions"`

	// APIKey is the Bearer token sent as `Authorization: Bearer
	// <api_key>`. Empty = no Authorization header (Ollama doesn't
	// authenticate by default; trying to authenticate to it is
	// harmless but unnecessary).
	APIKey string `json:"api_key"`

	// Timeout for a single Embed call (Go duration string,
	// e.g. "30s"). Default: 60s.
	Timeout string `json:"timeout"`
}

type embedder struct {
	cfg    Config
	client *http.Client
}

func newEmbedder(configBytes json.RawMessage) (embeddings.Embedder, error) {
	cfg := Config{
		BaseURL:    defaultBaseURL,
		Model:      defaultModel,
		Dimensions: defaultDimensions,
	}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("openai: parse config: %w", err)
		}
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultBaseURL
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
			return nil, fmt.Errorf("openai: invalid timeout %q: %w", cfg.Timeout, err)
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

func (e *embedder) Model() string   { return e.cfg.Model }
func (e *embedder) Dimensions() int { return e.cfg.Dimensions }

// embedRequest mirrors OpenAI's request shape.
type embedRequest struct {
	Model string   `json:"model"`
	Input []string `json:"input"`
}

// embedResponse is the OpenAI wire shape. We only need `data[]`;
// `model` + `usage` come through but aren't surfaced (cost tracking
// for embeddings is a follow-up).
type embedResponse struct {
	Data []embedDatum `json:"data"`
}

type embedDatum struct {
	Embedding []float32 `json:"embedding"`
	// Index is the original input position. The OpenAI contract
	// guarantees the response order matches the request, but
	// `index` is provided so we can sort defensively — some
	// gateways have shipped reordered responses in the past.
	Index int `json:"index"`
}

func (e *embedder) Embed(ctx context.Context, inputs []string) ([][]float32, error) {
	if len(inputs) == 0 {
		return nil, nil
	}
	body, err := json.Marshal(embedRequest{Model: e.cfg.Model, Input: inputs})
	if err != nil {
		return nil, fmt.Errorf("openai: marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		e.cfg.BaseURL+"/embeddings", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("openai: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if e.cfg.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+e.cfg.APIKey)
	}

	resp, err := e.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("openai: HTTP: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("openai: HTTP %d: %s", resp.StatusCode, string(b))
	}

	var out embedResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("openai: decode response: %w", err)
	}
	if len(out.Data) != len(inputs) {
		return nil, fmt.Errorf("openai: got %d embeddings for %d inputs",
			len(out.Data), len(inputs))
	}
	// Defensive re-order by index — see embedDatum.Index docstring.
	sort.SliceStable(out.Data, func(i, j int) bool {
		return out.Data[i].Index < out.Data[j].Index
	})
	if len(out.Data[0].Embedding) != e.cfg.Dimensions {
		return nil, fmt.Errorf("openai: model %q returned dim %d, configured %d",
			e.cfg.Model, len(out.Data[0].Embedding), e.cfg.Dimensions)
	}

	vectors := make([][]float32, len(out.Data))
	for i, d := range out.Data {
		vectors[i] = d.Embedding
	}
	return vectors, nil
}
