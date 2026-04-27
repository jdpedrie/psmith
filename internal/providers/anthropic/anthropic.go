// Package anthropic implements the Clark provider driver for Anthropic's
// Claude API. It is stateless: every turn carries the full prefix.
//
// The driver self-registers in init(); importing this package is sufficient
// to make the type available to providers.Build("anthropic", ...).
package anthropic

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	sdk "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"

	"github.com/jdpedrie/clark/internal/providers"
)

// defaultMaxOutputTokens is used when CallSettings.MaxOutputTokens is nil.
// Anthropic requires max_tokens; we pick a conservative default.
const defaultMaxOutputTokens = 4096

func init() {
	providers.Register("anthropic", New)
}

// Config is the driver-specific JSON blob stored in
// user_model_providers.config.
type Config struct {
	APIKey  string `json:"api_key"`
	BaseURL string `json:"base_url,omitempty"` // optional, for proxies / self-hosted gateways
}

// Driver is the live driver instance.
type Driver struct {
	cfg    Config
	deps   providers.Deps
	client sdk.Client

	// httpClient is exposed primarily so tests can pin a custom *http.Client.
	httpClient *http.Client
}

// New constructs a Driver from a Config blob and injected deps.
//
// If configBytes is non-empty it must be valid JSON; an empty/nil blob is
// rejected because we cannot authenticate without an API key.
func New(deps providers.Deps, configBytes json.RawMessage) (providers.Provider, error) {
	var cfg Config
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("anthropic: parse config: %w", err)
		}
	}
	if cfg.APIKey == "" {
		return nil, errors.New("anthropic: api_key is required")
	}

	opts := []option.RequestOption{
		option.WithAPIKey(cfg.APIKey),
	}
	if cfg.BaseURL != "" {
		opts = append(opts, option.WithBaseURL(cfg.BaseURL))
	}
	// SDK retries upstream errors transparently. The supervisor in the
	// streaming subsystem owns Clark's higher-level retry posture, so we
	// disable SDK retries to keep behaviour predictable in tests and prod.
	opts = append(opts, option.WithMaxRetries(0))

	d := &Driver{
		cfg:  cfg,
		deps: deps,
	}
	d.client = sdk.NewClient(opts...)
	return d, nil
}

// Type returns the registered provider-type identifier.
func (d *Driver) Type() string { return "anthropic" }

// Stateful returns false — Anthropic's HTTP API is stateless.
func (d *Driver) Stateful() bool { return false }
