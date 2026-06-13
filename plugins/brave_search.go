package plugins

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// BraveSearchName is the registered name for the Brave web-search tool plugin.
const BraveSearchName = "brave_search"

const (
	braveDefaultEndpoint = "https://api.search.brave.com/res/v1/web/search"
	braveDefaultCount    = 5
	braveDefaultTimeout  = 12 * time.Second
)

// braveSearch declares one tool — `web_search` — that the model can call to
// query the Brave Search web index. Implements ToolProvider + Configurable.
//
// Wiring requirement: the server-side supervisor must collect Tools() into
// the outbound wire request and dispatch tool_use chunks back to
// ExecuteTool. That lift is tracked in docs/todo.md as deferred
// work; this plugin is fully functional in isolation (the HTTP call works,
// ExecuteTool produces a usable JSON result) but won't fire end-to-end
// until the supervisor learns about ToolProvider.
type braveSearch struct {
	cfg    braveSearchConfig
	client *http.Client
}

// braveSearchConfig is the per-instance config. APIKey is required.
type braveSearchConfig struct {
	// APIKey is the Brave Search subscription token. Sent as the
	// `X-Subscription-Token` header on every request. Required.
	APIKey string `json:"api_key"`

	// DefaultCount is the result count used when the model doesn't pass an
	// explicit `count` parameter. Brave caps at 20; we cap at the same
	// value here. Defaults to 5.
	DefaultCount int `json:"default_count"`

	// SafeSearch maps to Brave's `safesearch` parameter — "off", "moderate",
	// or "strict". Defaults to "moderate" (Brave's own default).
	SafeSearch string `json:"safesearch"`

	// Country is an optional 2-letter country code biasing the result mix
	// (e.g. "US", "GB"). Empty = Brave default.
	Country string `json:"country"`

	// EndpointOverride lets test harnesses point the plugin at a fake.
	// Empty = production Brave endpoint.
	EndpointOverride string `json:"endpoint_override"`
}

// braveSearchInput is the JSON Schema-described input the model is allowed
// to pass on tool_use. Mirrors the schema below — kept as a typed Go
// struct so ExecuteTool gets compile-time field access.
type braveSearchInput struct {
	Query      string `json:"query"`
	Count      *int   `json:"count,omitempty"`
	Freshness  string `json:"freshness,omitempty"`
}

// braveSearchOutput is the trimmed result shape we hand back to the model.
// Brave's raw response is large and noisy; we keep only the fields a
// downstream LLM actually uses for synthesis.
type braveSearchOutput struct {
	Query   string              `json:"query"`
	Results []braveSearchResult `json:"results"`
}

type braveSearchResult struct {
	Title       string `json:"title"`
	URL         string `json:"url"`
	Description string `json:"description"`
	Age         string `json:"age,omitempty"`
}

// braveAPIResponse is the subset of Brave's response we decode. The full
// schema includes news, videos, infoboxes, etc.; we ignore everything
// outside `web.results` for v1.
type braveAPIResponse struct {
	Web struct {
		Results []struct {
			Title       string `json:"title"`
			URL         string `json:"url"`
			Description string `json:"description"`
			Age         string `json:"age"`
		} `json:"results"`
	} `json:"web"`
}

func newBraveSearch(configBytes json.RawMessage) (Plugin, error) {
	cfg := braveSearchConfig{
		DefaultCount: braveDefaultCount,
		SafeSearch:   "moderate",
	}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("brave_search: parse config: %w", err)
		}
	}
	if cfg.DefaultCount <= 0 {
		cfg.DefaultCount = braveDefaultCount
	}
	if cfg.DefaultCount > 20 {
		cfg.DefaultCount = 20
	}
	if cfg.SafeSearch == "" {
		cfg.SafeSearch = "moderate"
	}
	switch cfg.SafeSearch {
	case "off", "moderate", "strict":
	default:
		return nil, fmt.Errorf("brave_search: safesearch must be off|moderate|strict, got %q", cfg.SafeSearch)
	}
	return &braveSearch{
		cfg:    cfg,
		client: &http.Client{Timeout: braveDefaultTimeout},
	}, nil
}

func init() {
	Register(BraveSearchName, newBraveSearch)
}

func (p *braveSearch) Name() string        { return BraveSearchName }
func (p *braveSearch) DisplayName() string { return "Brave Search" }

func (p *braveSearch) Description() string {
	return "Gives the model a web_search tool backed by the Brave Search API. " +
		"Each call returns the top web results (title, URL, snippet) for a query. " +
		"Requires a Brave Search subscription token."
}

// --- Configurable ---

func (p *braveSearch) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "api_key",
			Display:     "API key",
			Description: "Brave Search subscription token. Get one at api.search.brave.com. Shared across every profile that uses this plugin.",
			Type:        ConfigFieldText,
			Required:    true,
			Global:      true,
		},
		{
			Name:        "default_count",
			Display:     "Default result count",
			Description: "How many results to return when the model doesn't specify. Brave caps at 20.",
			Type:        ConfigFieldNumber,
			Default:     braveDefaultCount,
		},
		{
			Name:        "safesearch",
			Display:     "Safe search",
			Description: "Brave's content filter level.",
			Type:        ConfigFieldSelect,
			Default:     "moderate",
			Options: []ConfigOption{
				{Value: "off", Label: "Off"},
				{Value: "moderate", Label: "Moderate"},
				{Value: "strict", Label: "Strict"},
			},
		},
		{
			Name:        "country",
			Display:     "Country bias",
			Description: "Optional 2-letter country code (e.g. US, GB) biasing the result mix.",
			Type:        ConfigFieldText,
		},
	}
}

// --- ToolProvider ---

func (p *braveSearch) Tools() []ToolDef {
	schema := []byte(`{
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "The search query. A short natural-language phrase."
    },
    "count": {
      "type": "integer",
      "minimum": 1,
      "maximum": 20,
      "description": "Number of results to return. Defaults to the plugin's configured value."
    },
    "freshness": {
      "type": "string",
      "enum": ["pd", "pw", "pm", "py"],
      "description": "Optional recency filter — pd=past 24h, pw=past week, pm=past month, py=past year."
    }
  },
  "required": ["query"]
}`)
	return []ToolDef{
		{
			Name: "web_search",
			Description: "Search the public web via Brave Search. Returns the top results " +
				"with title, URL, and a short description snippet. Use for fresh facts, " +
				"current events, citations, or anything not in your training data.",
			InputSchema: schema,
		},
	}
}

func (p *braveSearch) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	if name != "web_search" {
		return ToolResult{}, fmt.Errorf("brave_search: unknown tool %q", name)
	}
	if p.cfg.APIKey == "" {
		return ToolResult{}, fmt.Errorf("brave_search: api_key is not configured")
	}

	var in braveSearchInput
	if err := json.Unmarshal(input, &in); err != nil {
		return ToolResult{}, fmt.Errorf("brave_search: parse input: %w", err)
	}
	in.Query = strings.TrimSpace(in.Query)
	if in.Query == "" {
		return ToolResult{}, fmt.Errorf("brave_search: query is required")
	}

	count := p.cfg.DefaultCount
	if in.Count != nil {
		count = *in.Count
		if count < 1 {
			count = 1
		}
		if count > 20 {
			count = 20
		}
	}

	endpoint := p.cfg.EndpointOverride
	if endpoint == "" {
		endpoint = braveDefaultEndpoint
	}
	q := url.Values{}
	q.Set("q", in.Query)
	q.Set("count", strconv.Itoa(count))
	q.Set("safesearch", p.cfg.SafeSearch)
	if p.cfg.Country != "" {
		q.Set("country", p.cfg.Country)
	}
	if in.Freshness != "" {
		q.Set("freshness", in.Freshness)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"?"+q.Encode(), nil)
	if err != nil {
		return ToolResult{}, fmt.Errorf("brave_search: build request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Subscription-Token", p.cfg.APIKey)

	resp, err := p.client.Do(req)
	if err != nil {
		return ToolResult{}, fmt.Errorf("brave_search: http call: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return ToolResult{}, fmt.Errorf("brave_search: read body: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		// Surface the status + a short body excerpt so the caller can see
		// auth failures, rate limits, etc. without us having to enumerate
		// every Brave error shape.
		excerpt := string(body)
		if len(excerpt) > 240 {
			excerpt = excerpt[:240] + "…"
		}
		return ToolResult{}, fmt.Errorf("brave_search: %s — %s", resp.Status, excerpt)
	}

	var raw braveAPIResponse
	if err := json.Unmarshal(body, &raw); err != nil {
		return ToolResult{}, fmt.Errorf("brave_search: decode response: %w", err)
	}

	out := braveSearchOutput{Query: in.Query}
	for _, r := range raw.Web.Results {
		out.Results = append(out.Results, braveSearchResult{
			Title:       r.Title,
			URL:         r.URL,
			Description: r.Description,
			Age:         r.Age,
		})
	}

	encoded, err := json.Marshal(out)
	if err != nil {
		return ToolResult{}, fmt.Errorf("brave_search: encode output: %w", err)
	}
	return ToolResult{Output: encoded}, nil
}
