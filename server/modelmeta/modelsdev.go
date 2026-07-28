package modelmeta

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"time"
)

// ModelsDevURL is the canonical models.dev catalog endpoint.
const ModelsDevURL = "https://models.dev/api.json"

type modelsDevProvider struct {
	ID     string                       `json:"id"`
	Name   string                       `json:"name"`
	API    string                       `json:"api,omitempty"`
	Env    []string                     `json:"env,omitempty"`
	Doc    string                       `json:"doc,omitempty"`
	NPM    string                       `json:"npm,omitempty"`
	Models map[string]modelsDevModelDoc `json:"models,omitempty"`
}

type modelsDevModelDoc struct {
	ID          string               `json:"id"`
	Name        string               `json:"name"`
	Limit       *modelsDevLimit      `json:"limit,omitempty"`
	Cost        *modelsDevCost       `json:"cost,omitempty"`
	Modalities  *modelsDevModalities `json:"modalities,omitempty"`
	Knowledge   string               `json:"knowledge,omitempty"`
	ReleaseDate string               `json:"release_date,omitempty"`
	Reasoning   bool                 `json:"reasoning,omitempty"`
	ToolCall    bool                 `json:"tool_call,omitempty"`
	Attachment  bool                 `json:"attachment,omitempty"`
	OpenWeights bool                 `json:"open_weights,omitempty"`
	Extra       map[string]any       `json:"-"` // captured separately if we ever need it
}

type modelsDevLimit struct {
	Context int `json:"context,omitempty"`
	Output  int `json:"output,omitempty"`
}

type modelsDevCost struct {
	Input      float64 `json:"input,omitempty"`
	Output     float64 `json:"output,omitempty"`
	CacheRead  float64 `json:"cache_read,omitempty"`
	CacheWrite float64 `json:"cache_write,omitempty"`
}

type modelsDevModalities struct {
	Input  []string `json:"input,omitempty"`
	Output []string `json:"output,omitempty"`
}

// Fetcher pulls the models.dev payload over HTTP.
type Fetcher struct {
	URL    string
	Client *http.Client
}

func NewFetcher() *Fetcher {
	return &Fetcher{
		URL:    ModelsDevURL,
		Client: &http.Client{Timeout: 30 * time.Second},
	}
}

// Fetch returns the parsed payload along with the raw bytes per provider/model
// (so the DB can store the original blob for any field we don't materialize).
func (f *Fetcher) Fetch(ctx context.Context) (Snapshot, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.URL, nil)
	if err != nil {
		return Snapshot{}, err
	}
	resp, err := f.Client.Do(req)
	if err != nil {
		return Snapshot{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Snapshot{}, fmt.Errorf("modelsdev: HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return Snapshot{}, err
	}
	return ParseSnapshot(body, time.Now().UTC())
}

// Snapshot is the parsed view of a models.dev fetch, ready for DB upsert.
type Snapshot struct {
	Providers []ProviderSnapshot
	FetchedAt time.Time
}

type ProviderSnapshot struct {
	Provider Provider
	RawJSON  []byte
	Models   []ModelSnapshot
}

type ModelSnapshot struct {
	Model   Model
	RawJSON []byte
}

// ParseSnapshot parses a models.dev payload (the top-level provider map) into a
// Snapshot ready for DB upsert. fetchedAt is stamped on every row.
func ParseSnapshot(data []byte, fetchedAt time.Time) (Snapshot, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return Snapshot{}, fmt.Errorf("modelsdev: parse payload: %w", err)
	}
	out := Snapshot{FetchedAt: fetchedAt}
	for providerID, providerRaw := range raw {
		var p modelsDevProvider
		if err := json.Unmarshal(providerRaw, &p); err != nil {
			// Skip unparseable provider entries rather than failing the whole import.
			continue
		}
		if p.ID == "" {
			p.ID = providerID
		}
		ps := ProviderSnapshot{
			Provider: Provider{
				ID:        p.ID,
				Name:      p.Name,
				APIBase:   p.API,
				EnvKey:    firstNonEmpty(p.Env),
				DocURL:    p.Doc,
				NPM:       p.NPM,
				FetchedAt: fetchedAt,
			},
			RawJSON: providerRaw,
		}
		// Re-extract per-model raw JSON for storage.
		var providerObj struct {
			Models map[string]json.RawMessage `json:"models"`
		}
		_ = json.Unmarshal(providerRaw, &providerObj)
		for modelID, modelRaw := range providerObj.Models {
			var m modelsDevModelDoc
			if err := json.Unmarshal(modelRaw, &m); err != nil {
				continue
			}
			if m.ID == "" {
				m.ID = modelID
			}
			ps.Models = append(ps.Models, ModelSnapshot{
				Model:   modelsDevToModel(p.ID, m, fetchedAt),
				RawJSON: modelRaw,
			})
		}
		out.Providers = append(out.Providers, ps)
	}
	return out, nil
}

func modelsDevToModel(providerID string, m modelsDevModelDoc, fetchedAt time.Time) Model {
	model := Model{
		ProviderID:  providerID,
		ID:          m.ID,
		DisplayName: m.Name,
		Modalities:  collectModalities(m.Modalities),
		Capabilities: Capabilities{
			Streaming:       true, // assume true; providers that can't stream are rare
			Thinking:        m.Reasoning,
			ToolUse:         m.ToolCall,
			Vision:          hasModality(m.Modalities, "input", "image"),
			PromptCaching:   m.Cost != nil && (m.Cost.CacheRead > 0 || m.Cost.CacheWrite > 0),
			GeneratesImages: hasModality(m.Modalities, "output", "image"),
		},
		FetchedAt: fetchedAt,
	}
	if m.Limit != nil {
		model.ContextWindow = m.Limit.Context
		model.MaxOutputTokens = m.Limit.Output
	}
	if m.Cost != nil {
		model.Pricing = &Pricing{
			InputPerMillion:      m.Cost.Input,
			OutputPerMillion:     m.Cost.Output,
			CacheReadPerMillion:  m.Cost.CacheRead,
			CacheWritePerMillion: m.Cost.CacheWrite,
		}
	}
	if m.Knowledge != "" {
		if t, err := parseLooseDate(m.Knowledge); err == nil {
			model.KnowledgeCutoff = &t
		}
	}
	return model
}

func collectModalities(m *modelsDevModalities) []string {
	if m == nil {
		return nil
	}
	seen := map[string]bool{}
	out := []string{}
	for _, s := range m.Input {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, s := range m.Output {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func hasModality(m *modelsDevModalities, dir, name string) bool {
	if m == nil {
		return false
	}
	var list []string
	switch dir {
	case "input":
		list = m.Input
	case "output":
		list = m.Output
	}
	return slices.Contains(list, name)
}

// parseLooseDate accepts ISO date or year-month-only forms ("2024-10", "2024").
func parseLooseDate(s string) (time.Time, error) {
	formats := []string{"2006-01-02", "2006-01", "2006"}
	for _, f := range formats {
		if t, err := time.Parse(f, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("modelmeta: unparseable date %q", s)
}

func firstNonEmpty(ss []string) string {
	for _, s := range ss {
		if s != "" {
			return s
		}
	}
	return ""
}
