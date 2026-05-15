// discover-constraints fires a battery of probe requests against each
// blessed provider's models to map out which CallSettings fields they
// support, which they silently drop, and which they actively reject.
//
// Output is a JSON results file (default
// internal/modelmeta/constraint_probes/<timestamp>.json) that downstream
// tooling distils into the per-model constraint table the UI uses for
// guardrails.
//
// Probes go through the existing internal/providers drivers, not raw
// HTTP — so what the report measures is "what happens when you pass
// this setting through Reeve's code path," which is exactly what the
// UI guardrails need to know. If the driver drops the field silently,
// the probe records "ok"; if the upstream API returns 400, it records
// the error string. Both are actionable.
//
// Reads keys from env vars (ANTHROPIC_API_KEY, OPENAI_API_KEY,
// GOOGLE_API_KEY, OPENROUTER_API_KEY). Providers without a key are
// skipped silently.
//
// Cost discipline: every probe sends a 2-token user message, caps
// max_output_tokens at 4 (or the thinking-minimum + 100 when probing
// thinking), and ignores response content. ~10 models × ~12 probes ×
// 4 providers ≈ 480 calls; at average ~$0.0001 per call that's <$0.05
// per full run.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jdpedrie/reeve/internal/providers"
	_ "github.com/jdpedrie/reeve/internal/providers/anthropic"
	_ "github.com/jdpedrie/reeve/internal/providers/google"
	_ "github.com/jdpedrie/reeve/internal/providers/openai"
)

// target identifies one model to probe. providerType is the
// driver-registered name; baseURL is needed for openai-compatible
// (OpenRouter, etc.). Tags categorise the model so the probe
// battery skips inapplicable probes (e.g. thinking probes on a
// non-thinking model).
type target struct {
	ProviderType string   `json:"provider_type"`
	ModelID      string   `json:"model_id"`
	BaseURL      string   `json:"base_url,omitempty"`
	APIKeyEnv    string   `json:"-"`
	Tags         []string `json:"tags,omitempty"`
}

func (t target) hasTag(tag string) bool {
	for _, x := range t.Tags {
		if x == tag {
			return true
		}
	}
	return false
}

// blessedTargets is the curated probe set. Goal: cover one
// representative per (provider, family) so the constraint table can
// be cut by family without exhausting cost. Add OpenRouter mirrors
// of these same families so we can spot routing-induced quirks.
//
// Tags:
//   - "thinking": model supports extended thinking / reasoning effort.
//   - "reasoning_locked_temp": OpenAI o-series + gpt-5 lock temperature
//     at 1.0. Tagged so the temperature probe expectation is clear.
//   - "image_output": image-output capable; sampling fields may behave
//     differently here.
var blessedTargets = []target{
	// Anthropic — direct.
	{ProviderType: "anthropic", ModelID: "claude-opus-4-5", APIKeyEnv: "ANTHROPIC_API_KEY", Tags: []string{"thinking"}},
	{ProviderType: "anthropic", ModelID: "claude-sonnet-4-5", APIKeyEnv: "ANTHROPIC_API_KEY", Tags: []string{"thinking"}},
	{ProviderType: "anthropic", ModelID: "claude-haiku-4-5", APIKeyEnv: "ANTHROPIC_API_KEY", Tags: []string{"thinking"}},

	// OpenAI — direct (api.openai.com → Responses API path).
	{ProviderType: "openai-compatible", ModelID: "gpt-5", BaseURL: "https://api.openai.com/v1", APIKeyEnv: "OPENAI_API_KEY", Tags: []string{"reasoning_locked_temp", "thinking"}},
	{ProviderType: "openai-compatible", ModelID: "gpt-5-mini", BaseURL: "https://api.openai.com/v1", APIKeyEnv: "OPENAI_API_KEY", Tags: []string{"reasoning_locked_temp", "thinking"}},
	{ProviderType: "openai-compatible", ModelID: "gpt-4o", BaseURL: "https://api.openai.com/v1", APIKeyEnv: "OPENAI_API_KEY"},
	{ProviderType: "openai-compatible", ModelID: "gpt-4o-mini", BaseURL: "https://api.openai.com/v1", APIKeyEnv: "OPENAI_API_KEY"},
	{ProviderType: "openai-compatible", ModelID: "o3-mini", BaseURL: "https://api.openai.com/v1", APIKeyEnv: "OPENAI_API_KEY", Tags: []string{"reasoning_locked_temp", "thinking"}},

	// Google — direct (Gemini native).
	{ProviderType: "google", ModelID: "gemini-2.5-pro", APIKeyEnv: "GOOGLE_API_KEY", Tags: []string{"thinking"}},
	{ProviderType: "google", ModelID: "gemini-2.5-flash", APIKeyEnv: "GOOGLE_API_KEY", Tags: []string{"thinking"}},
	{ProviderType: "google", ModelID: "gemini-2.0-flash", APIKeyEnv: "GOOGLE_API_KEY"},

	// OpenRouter — only models that mirror a blessed-provider family,
	// so we can cross-reference vs the direct call.
	{ProviderType: "openai-compatible", ModelID: "anthropic/claude-opus-4.5", BaseURL: "https://openrouter.ai/api/v1", APIKeyEnv: "OPENROUTER_API_KEY", Tags: []string{"thinking", "openrouter"}},
	{ProviderType: "openai-compatible", ModelID: "openai/gpt-5", BaseURL: "https://openrouter.ai/api/v1", APIKeyEnv: "OPENROUTER_API_KEY", Tags: []string{"reasoning_locked_temp", "thinking", "openrouter"}},
	{ProviderType: "openai-compatible", ModelID: "google/gemini-2.5-pro", BaseURL: "https://openrouter.ai/api/v1", APIKeyEnv: "OPENROUTER_API_KEY", Tags: []string{"thinking", "openrouter"}},
}

// probe is one (name, mutator) pair. mutate sets the field(s) under
// test on a fresh CallSettings. skip lets a probe opt out of models
// that obviously can't run it (e.g. thinking probes on non-thinking
// models). Each probe sends one minimal request and records pass/fail.
type probe struct {
	Name   string
	Mutate func(*providers.CallSettings)
	Skip   func(target) bool
}

func ptrFloat(v float64) *float64 { return &v }
func ptrInt(v int) *int           { return &v }
func ptrBool(v bool) *bool        { return &v }

var probes = []probe{
	{Name: "baseline"},
	{Name: "temperature_zero", Mutate: func(s *providers.CallSettings) { s.Temperature = ptrFloat(0.0) }},
	{Name: "temperature_one", Mutate: func(s *providers.CallSettings) { s.Temperature = ptrFloat(1.0) }},
	{Name: "temperature_one_five", Mutate: func(s *providers.CallSettings) { s.Temperature = ptrFloat(1.5) }},
	{Name: "temperature_two", Mutate: func(s *providers.CallSettings) { s.Temperature = ptrFloat(2.0) }},
	{Name: "top_p_half", Mutate: func(s *providers.CallSettings) { s.TopP = ptrFloat(0.5) }},
	{Name: "top_k_forty", Mutate: func(s *providers.CallSettings) { s.TopK = ptrInt(40) }},
	{Name: "max_output_tokens_4", Mutate: func(s *providers.CallSettings) { s.MaxOutputTokens = ptrInt(4) }},
	{Name: "stop_sequences", Mutate: func(s *providers.CallSettings) { s.StopSequences = []string{"END"} }},
	// Thinking-only probes: enabled with default budget; enabled
	// alongside a non-1.0 temperature (Anthropic should reject this
	// pair); enabled with a tiny budget under the floor (Anthropic
	// has a 1024-token minimum on extended thinking — surfaces the
	// error message verbatim).
	{
		Name: "thinking_enabled",
		Mutate: func(s *providers.CallSettings) {
			s.Thinking = &providers.ThinkingSettings{Enabled: ptrBool(true), BudgetTokens: ptrInt(1024)}
			// Anthropic requires max_tokens > thinking budget.
			s.MaxOutputTokens = ptrInt(2048)
		},
		Skip: func(t target) bool { return !t.hasTag("thinking") },
	},
	{
		Name: "thinking_with_temperature_half",
		Mutate: func(s *providers.CallSettings) {
			s.Thinking = &providers.ThinkingSettings{Enabled: ptrBool(true), BudgetTokens: ptrInt(1024)}
			s.Temperature = ptrFloat(0.5)
			s.MaxOutputTokens = ptrInt(2048)
		},
		Skip: func(t target) bool { return !t.hasTag("thinking") },
	},
	{
		Name: "thinking_below_min_budget",
		Mutate: func(s *providers.CallSettings) {
			s.Thinking = &providers.ThinkingSettings{Enabled: ptrBool(true), BudgetTokens: ptrInt(100)}
			s.MaxOutputTokens = ptrInt(2048)
		},
		Skip: func(t target) bool { return !t.hasTag("thinking") },
	},
	// OpenAI-specific. The driver routes openai-compatible requests
	// through Chat or Responses APIs depending on base URL; both
	// paths are exercised by the openai/openrouter targets above.
	{
		Name: "frequency_penalty_half",
		Mutate: func(s *providers.CallSettings) {
			s.OpenAI = &providers.OpenAIExtras{FrequencyPenalty: ptrFloat(0.5)}
		},
	},
	{
		Name: "presence_penalty_half",
		Mutate: func(s *providers.CallSettings) {
			s.OpenAI = &providers.OpenAIExtras{PresencePenalty: ptrFloat(0.5)}
		},
	},
	{
		Name: "openai_seed",
		Mutate: func(s *providers.CallSettings) {
			s.OpenAI = &providers.OpenAIExtras{Seed: ptrInt(42)}
		},
	},
	{
		Name: "openai_top_logprobs",
		Mutate: func(s *providers.CallSettings) {
			s.OpenAI = &providers.OpenAIExtras{TopLogprobs: ptrInt(3)}
		},
	},
	{
		Name: "response_format_json_object",
		Mutate: func(s *providers.CallSettings) {
			b := true
			s.OpenAI = &providers.OpenAIExtras{ResponseFormat: &providers.ResponseFormat{JSONObject: &b}}
		},
	},
}

// probeResult captures one (target, probe) outcome.
type probeResult struct {
	Probe    string `json:"probe"`
	Status   string `json:"status"` // "ok" | "rejected" | "driver_error"
	ErrorMsg string `json:"error_message,omitempty"`
}

// targetResult is the per-model report.
type targetResult struct {
	target
	Results []probeResult `json:"results"`
}

// runReport is the full output of one discovery run.
type runReport struct {
	StartedAt    time.Time      `json:"started_at"`
	CompletedAt  time.Time      `json:"completed_at"`
	ToolVersion  string         `json:"tool_version"`
	Targets      []targetResult `json:"targets"`
}

const toolVersion = "discover-constraints/1"

func main() {
	out := flag.String("out", "", "output JSON path; empty = stdout, 'auto' = internal/modelmeta/constraint_probes/<timestamp>.json")
	only := flag.String("only", "", "comma-separated probe names to run (default: all)")
	models := flag.String("models", "", "comma-separated provider:model identifiers to limit the run")
	timeout := flag.Duration("timeout", 30*time.Second, "per-probe timeout")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	// Filter probes if -only is set.
	activeProbes := probes
	if *only != "" {
		want := map[string]struct{}{}
		for _, n := range strings.Split(*only, ",") {
			want[strings.TrimSpace(n)] = struct{}{}
		}
		filtered := make([]probe, 0, len(probes))
		for _, p := range probes {
			if _, ok := want[p.Name]; ok {
				filtered = append(filtered, p)
			}
		}
		activeProbes = filtered
	}

	// Filter targets by -models or by missing API keys.
	var modelFilter map[string]struct{}
	if *models != "" {
		modelFilter = map[string]struct{}{}
		for _, m := range strings.Split(*models, ",") {
			modelFilter[strings.TrimSpace(m)] = struct{}{}
		}
	}

	report := runReport{
		StartedAt:   time.Now().UTC(),
		ToolVersion: toolVersion,
	}

	for _, t := range blessedTargets {
		if modelFilter != nil {
			key := t.ProviderType + ":" + t.ModelID
			if _, ok := modelFilter[key]; !ok {
				continue
			}
		}
		key := os.Getenv(t.APIKeyEnv)
		if key == "" {
			logger.Info("skipping target — no api key", "target", t.ProviderType+"/"+t.ModelID, "env", t.APIKeyEnv)
			continue
		}

		driver, err := buildDriver(t, key)
		if err != nil {
			logger.Error("driver build failed", "target", t.ProviderType+"/"+t.ModelID, "err", err)
			continue
		}
		stateless, ok := driver.(providers.StatelessProvider)
		if !ok {
			logger.Error("driver is not stateless", "target", t.ProviderType+"/"+t.ModelID)
			continue
		}

		tr := targetResult{target: t}
		for _, p := range activeProbes {
			if p.Skip != nil && p.Skip(t) {
				tr.Results = append(tr.Results, probeResult{Probe: p.Name, Status: "skipped"})
				continue
			}
			res := runProbe(stateless, t.ModelID, p, *timeout)
			tr.Results = append(tr.Results, res)
			logger.Info("probe", "target", t.ProviderType+"/"+t.ModelID, "probe", p.Name, "status", res.Status)
		}
		report.Targets = append(report.Targets, tr)
	}

	report.CompletedAt = time.Now().UTC()

	// Sort targets so output is stable across runs.
	sort.Slice(report.Targets, func(i, j int) bool {
		a := report.Targets[i].ProviderType + ":" + report.Targets[i].ModelID
		b := report.Targets[j].ProviderType + ":" + report.Targets[j].ModelID
		return a < b
	})

	encoded, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "marshal report: %v\n", err)
		os.Exit(1)
	}

	switch *out {
	case "":
		os.Stdout.Write(encoded)
		os.Stdout.WriteString("\n")
	case "auto":
		ts := report.StartedAt.Format("20060102-150405")
		path := filepath.Join("internal/modelmeta/constraint_probes", ts+".json")
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "mkdir: %v\n", err)
			os.Exit(1)
		}
		if err := os.WriteFile(path, encoded, 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "write: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("wrote %s\n", path)
	default:
		if err := os.WriteFile(*out, encoded, 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "write: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("wrote %s\n", *out)
	}
}

// buildDriver constructs a driver instance from a target. Catalog stays
// nil — Send doesn't need it; only Discover does.
func buildDriver(t target, apiKey string) (providers.Provider, error) {
	cfg := map[string]string{"api_key": apiKey}
	if t.BaseURL != "" {
		cfg["base_url"] = t.BaseURL
	}
	cfgBytes, err := json.Marshal(cfg)
	if err != nil {
		return nil, err
	}
	return providers.Build(t.ProviderType, providers.Deps{}, cfgBytes)
}

// runProbe sends one minimal request with the probe's settings applied
// and classifies the outcome. The user message is a 2-token "Say hi."
// to keep cost minimal; max_output_tokens is left to the probe's
// mutator (defaults vary by provider).
func runProbe(drv providers.StatelessProvider, modelID string, p probe, timeout time.Duration) probeResult {
	settings := providers.CallSettings{}
	if p.Mutate != nil {
		p.Mutate(&settings)
	}
	// Cap output for non-thinking probes; thinking probes set their
	// own max via the mutator.
	if settings.MaxOutputTokens == nil {
		settings.MaxOutputTokens = ptrInt(4)
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	ch, err := drv.Send(ctx, providers.SendRequest{
		ModelID: modelID,
		Messages: []providers.WireMessage{
			{Role: "user", Content: "Say hi."},
		},
		Settings: settings,
	})
	if err != nil {
		return probeResult{Probe: p.Name, Status: "driver_error", ErrorMsg: shorten(err.Error())}
	}

	var errMsg string
	for chunk := range ch {
		if chunk.Type == providers.ChunkError {
			var payload struct {
				Message string `json:"message"`
			}
			_ = json.Unmarshal(chunk.Payload, &payload)
			if payload.Message == "" {
				errMsg = shorten(string(chunk.Payload))
			} else {
				errMsg = shorten(payload.Message)
			}
		}
	}
	if errMsg != "" {
		return probeResult{Probe: p.Name, Status: "rejected", ErrorMsg: errMsg}
	}
	return probeResult{Probe: p.Name, Status: "ok"}
}

// shorten caps an error string at a length friendly for JSON inspection.
// Provider error messages occasionally include the full request echo;
// the meaningful part is always at the start.
func shorten(s string) string {
	const limit = 400
	s = strings.TrimSpace(s)
	if len(s) <= limit {
		return s
	}
	return s[:limit] + "…"
}
