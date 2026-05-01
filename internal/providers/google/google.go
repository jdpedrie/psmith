// Package google implements the Reeve provider driver for Google's Gemini
// API (the "AI Studio" surface at generativelanguage.googleapis.com).
//
// The driver is stateless: every turn carries the full prefix.
//
// The driver self-registers in init(); importing this package is sufficient
// to make the type available to providers.Build("google", ...).
//
// # Why direct HTTP, not an SDK
//
// The Gemini REST API surface is small enough — generateContent (streaming
// SSE), countTokens, models — that vendoring an SDK isn't worth the cost.
// We get full control over streaming and error mapping, and the driver
// stays thin and easy to evolve.
//
// # Endpoint
//
// We hard-code the AI Studio base URL. Vertex AI uses a different shape
// (project-scoped paths, OAuth credentials) and is intentionally deferred —
// when it lands it will be its own driver type or a config flag here.
package google

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/jdpedrie/reeve/internal/providers"
)

// defaultBaseURL is the AI Studio (generativelanguage) endpoint.
// Vertex AI variants are deferred and would require a separate driver.
const defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"

func init() {
	providers.Register("google", New)
}

// Config is the driver-specific JSON blob stored in
// user_model_providers.config.
//
// Only api_key is required. base_url is intentionally not exposed — see the
// package doc.
type Config struct {
	APIKey string `json:"api_key"`
}

// Driver is the live driver instance.
type Driver struct {
	cfg     Config
	deps    providers.Deps
	baseURL string

	// httpClient is exposed primarily so tests can pin a custom *http.Client
	// pointing at httptest.Server.
	httpClient *http.Client
}

// New constructs a Driver from a Config blob and injected deps.
//
// configBytes must be valid JSON containing api_key. An empty blob is rejected
// because we cannot authenticate without an API key.
func New(deps providers.Deps, configBytes json.RawMessage) (providers.Provider, error) {
	var cfg Config
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("google: parse config: %w", err)
		}
	}
	if cfg.APIKey == "" {
		return nil, errors.New("google: api_key is required")
	}

	d := &Driver{
		cfg:        cfg,
		deps:       deps,
		baseURL:    defaultBaseURL,
		httpClient: http.DefaultClient,
	}
	return d, nil
}

// Type returns the registered provider-type identifier.
func (d *Driver) Type() string { return "google" }

// Stateful returns false — Gemini's HTTP API is stateless. Cached content is
// orthogonal to session state and is not yet wired through Reeve.
func (d *Driver) Stateful() bool { return false }

// logger returns the driver's logger or slog.Default if no logger was injected.
func (d *Driver) logger() *slog.Logger {
	if d.deps.Logger != nil {
		return d.deps.Logger
	}
	return slog.Default()
}
