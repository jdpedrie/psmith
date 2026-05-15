// discover-constraints fires a battery of probe requests through a
// running reeved instance to map out which CallSettings fields each
// enabled model accepts, silently drops, or actively rejects.
//
// Output is a JSON results file (default
// internal/modelmeta/constraint_probes/<timestamp>.json) that
// downstream tooling distils into the per-model constraint table the
// UI uses for guardrails.
//
// The tool is a thin Connect client — it does not touch the database
// directly, decrypt API keys, or call upstream provider APIs. Every
// probe goes through reeved's existing TestUserModel RPC, which
// already handles auth, decryption, driver construction, and per-call
// settings dispatch. What the report measures is "what happens when
// you set this field on a real chat through Reeve" — exactly what UI
// guardrails need to know.
//
// Usage:
//
//	go run ./cmd/discover-constraints \
//	    -addr http://localhost:8080 \
//	    -u john -p password \
//	    -out auto
//
// Cost discipline: each probe is a 4-token "OK" reply at most. ~480
// calls per full run (12 models × ~17 probes × 2-ish providers
// configured) ≈ <$0.05.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/gen/reeve/v1/reevev1connect"
)

// probe is one (name, mutator) pair. mutate sets the field(s) under
// test on a fresh CallSettings before the per-probe send. skip lets a
// probe opt out of models that obviously can't run it (e.g. thinking
// probes on a non-thinking model). Each probe is one TestUserModel RPC.
type probe struct {
	Name   string
	Mutate func(*reevev1.CallSettings)
	Skip   func(model *reevev1.UserModel) bool
}

func ptrFloat(v float64) *float64 { return &v }
func ptrInt(v int32) *int32       { return &v }
func ptrBool(v bool) *bool        { return &v }

func hasThinking(m *reevev1.UserModel) bool {
	return m.Capabilities != nil && m.Capabilities.Thinking
}

var probes = []probe{
	{Name: "baseline"},
	{Name: "temperature_zero", Mutate: func(s *reevev1.CallSettings) { s.Temperature = ptrFloat(0.0) }},
	{Name: "temperature_one", Mutate: func(s *reevev1.CallSettings) { s.Temperature = ptrFloat(1.0) }},
	{Name: "temperature_one_five", Mutate: func(s *reevev1.CallSettings) { s.Temperature = ptrFloat(1.5) }},
	{Name: "temperature_two", Mutate: func(s *reevev1.CallSettings) { s.Temperature = ptrFloat(2.0) }},
	{Name: "top_p_half", Mutate: func(s *reevev1.CallSettings) { s.TopP = ptrFloat(0.5) }},
	{Name: "top_k_forty", Mutate: func(s *reevev1.CallSettings) { s.TopK = ptrInt(40) }},
	{Name: "max_output_tokens_4", Mutate: func(s *reevev1.CallSettings) { s.MaxOutputTokens = ptrInt(4) }},
	{Name: "stop_sequences", Mutate: func(s *reevev1.CallSettings) { s.StopSequences = []string{"END"} }},
	// Thinking-capable probes: enabled at default budget; enabled
	// alongside a non-1.0 temperature (Anthropic should reject this
	// pair); enabled with a sub-floor budget (Anthropic has a 1024-
	// token minimum on extended thinking — surfaces the exact error
	// message verbatim).
	{
		Name: "thinking_enabled",
		Mutate: func(s *reevev1.CallSettings) {
			s.Thinking = &reevev1.ThinkingSettings{Enabled: ptrBool(true), BudgetTokens: ptrInt(1024)}
			s.MaxOutputTokens = ptrInt(2048)
		},
		Skip: func(m *reevev1.UserModel) bool { return !hasThinking(m) },
	},
	{
		Name: "thinking_with_temperature_half",
		Mutate: func(s *reevev1.CallSettings) {
			s.Thinking = &reevev1.ThinkingSettings{Enabled: ptrBool(true), BudgetTokens: ptrInt(1024)}
			s.Temperature = ptrFloat(0.5)
			s.MaxOutputTokens = ptrInt(2048)
		},
		Skip: func(m *reevev1.UserModel) bool { return !hasThinking(m) },
	},
	{
		Name: "thinking_below_min_budget",
		Mutate: func(s *reevev1.CallSettings) {
			s.Thinking = &reevev1.ThinkingSettings{Enabled: ptrBool(true), BudgetTokens: ptrInt(100)}
			s.MaxOutputTokens = ptrInt(2048)
		},
		Skip: func(m *reevev1.UserModel) bool { return !hasThinking(m) },
	},
	// OpenAI-only extras. Drivers for non-OpenAI providers either
	// silently drop these (probe records "ok") or pass them through
	// to a provider that rejects them — the report surfaces both.
	{
		Name: "frequency_penalty_half",
		Mutate: func(s *reevev1.CallSettings) {
			s.Openai = &reevev1.OpenAIExtras{FrequencyPenalty: ptrFloat(0.5)}
		},
	},
	{
		Name: "presence_penalty_half",
		Mutate: func(s *reevev1.CallSettings) {
			s.Openai = &reevev1.OpenAIExtras{PresencePenalty: ptrFloat(0.5)}
		},
	},
	{
		Name: "openai_seed",
		Mutate: func(s *reevev1.CallSettings) {
			s.Openai = &reevev1.OpenAIExtras{Seed: ptrInt(42)}
		},
	},
	{
		Name: "openai_top_logprobs",
		Mutate: func(s *reevev1.CallSettings) {
			s.Openai = &reevev1.OpenAIExtras{TopLogprobs: ptrInt(3)}
		},
	},
	{
		Name: "response_format_json_object",
		Mutate: func(s *reevev1.CallSettings) {
			s.Openai = &reevev1.OpenAIExtras{ResponseFormat: &reevev1.ResponseFormat{
				Kind: &reevev1.ResponseFormat_JsonObject{JsonObject: true},
			}}
		},
	},
}

// probeResult captures one (target, probe) outcome.
type probeResult struct {
	Probe        string `json:"probe"`
	Status       string `json:"status"` // "ok" | "rejected" | "skipped"
	ErrorMessage string `json:"error_message,omitempty"`
	LatencyMs    int64  `json:"latency_ms,omitempty"`
}

// targetResult is the per-model report.
type targetResult struct {
	UserModelProviderID string        `json:"user_model_provider_id"`
	ProviderType        string        `json:"provider_type"`
	ProviderLabel       string        `json:"provider_label"`
	ModelID             string        `json:"model_id"`
	DisplayName         string        `json:"display_name"`
	Capabilities        capabilities  `json:"capabilities"`
	Results             []probeResult `json:"results"`
}

// capabilities is a small JSON-friendly mirror of ModelCapabilities so
// readers don't need to chase the proto schema to interpret the report.
type capabilities struct {
	Thinking        bool `json:"thinking"`
	ToolUse         bool `json:"tool_use"`
	Vision          bool `json:"vision"`
	PromptCaching   bool `json:"prompt_caching"`
	GeneratesImages bool `json:"generates_images"`
}

// runReport is the full output of one discovery run.
type runReport struct {
	StartedAt   time.Time      `json:"started_at"`
	CompletedAt time.Time      `json:"completed_at"`
	ToolVersion string         `json:"tool_version"`
	ReevedAddr  string         `json:"reeved_addr"`
	Targets     []targetResult `json:"targets"`
}

const toolVersion = "discover-constraints/2"

// bearerTransport stamps every outbound request with the session
// token returned by Auth.Login. Mirrors the helper in cmd/tool-e2e.
type bearerTransport struct {
	token string
	base  http.RoundTripper
}

func (b *bearerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req.Header.Set("Authorization", "Bearer "+b.token)
	if b.base == nil {
		return http.DefaultTransport.RoundTrip(req)
	}
	return b.base.RoundTrip(req)
}

func main() {
	addr := flag.String("addr", "http://localhost:8080", "reeved base URL")
	user := flag.String("u", "john", "username")
	pass := flag.String("p", "password", "password")
	out := flag.String("out", "", "output JSON path; empty = stdout, 'auto' = internal/modelmeta/constraint_probes/<timestamp>.json")
	only := flag.String("only", "", "comma-separated probe names to run (default: all)")
	models := flag.String("models", "", "comma-separated provider_id:model_id pairs to limit the run")
	timeout := flag.Duration("timeout", 30*time.Second, "per-probe RPC timeout")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	// Login.
	rawClient := http.DefaultClient
	authClient := reevev1connect.NewAuthServiceClient(rawClient, *addr)
	loginResp, err := authClient.Login(ctx, connect.NewRequest(&reevev1.LoginRequest{
		Username: *user,
		Password: *pass,
	}))
	if err != nil {
		fatal("login: %v", err)
	}
	token := loginResp.Msg.SessionToken
	authedHTTP := &http.Client{Transport: &bearerTransport{token: token}}

	mpClient := reevev1connect.NewModelProvidersServiceClient(authedHTTP, *addr)

	// Filter probes by -only.
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

	// Filter targets by -models.
	var modelFilter map[string]struct{}
	if *models != "" {
		modelFilter = map[string]struct{}{}
		for _, m := range strings.Split(*models, ",") {
			modelFilter[strings.TrimSpace(m)] = struct{}{}
		}
	}

	// Enumerate enabled (provider, model) pairs via the API.
	provResp, err := mpClient.ListUserModelProviders(ctx, connect.NewRequest(&reevev1.ListUserModelProvidersRequest{}))
	if err != nil {
		fatal("ListUserModelProviders: %v", err)
	}

	report := runReport{
		StartedAt:   time.Now().UTC(),
		ToolVersion: toolVersion,
		ReevedAddr:  *addr,
	}

	for _, prov := range provResp.Msg.Providers {
		modelsResp, err := mpClient.ListUserModels(ctx, connect.NewRequest(&reevev1.ListUserModelsRequest{
			UserModelProviderId: prov.Id,
		}))
		if err != nil {
			fmt.Fprintf(os.Stderr, "ListUserModels(%s) failed: %v — skipping provider\n", prov.Label, err)
			continue
		}
		for _, m := range modelsResp.Msg.Models {
			key := prov.Id + ":" + m.ModelId
			if modelFilter != nil {
				if _, ok := modelFilter[key]; !ok {
					continue
				}
			}
			tr := targetResult{
				UserModelProviderID: prov.Id,
				ProviderType:        prov.Type,
				ProviderLabel:       prov.Label,
				ModelID:             m.ModelId,
				DisplayName:         m.DisplayName,
				Capabilities:        capsFromProto(m.Capabilities),
			}
			for _, p := range activeProbes {
				if p.Skip != nil && p.Skip(m) {
					tr.Results = append(tr.Results, probeResult{Probe: p.Name, Status: "skipped"})
					continue
				}
				res := runProbe(ctx, mpClient, prov.Id, m.ModelId, p, *timeout)
				tr.Results = append(tr.Results, res)
				fmt.Fprintf(os.Stderr, "[%s/%s] %s → %s\n", prov.Label, m.ModelId, p.Name, res.Status)
			}
			report.Targets = append(report.Targets, tr)
		}
	}

	report.CompletedAt = time.Now().UTC()

	// Stable ordering across runs.
	sort.Slice(report.Targets, func(i, j int) bool {
		a := report.Targets[i].ProviderLabel + ":" + report.Targets[i].ModelID
		b := report.Targets[j].ProviderLabel + ":" + report.Targets[j].ModelID
		return a < b
	})

	encoded, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		fatal("marshal report: %v", err)
	}

	switch *out {
	case "":
		os.Stdout.Write(encoded)
		os.Stdout.WriteString("\n")
	case "auto":
		ts := report.StartedAt.Format("20060102-150405")
		path := filepath.Join("internal/modelmeta/constraint_probes", ts+".json")
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			fatal("mkdir: %v", err)
		}
		if err := os.WriteFile(path, encoded, 0o644); err != nil {
			fatal("write: %v", err)
		}
		fmt.Printf("wrote %s\n", path)
	default:
		if err := os.WriteFile(*out, encoded, 0o644); err != nil {
			fatal("write: %v", err)
		}
		fmt.Printf("wrote %s\n", *out)
	}
}

// runProbe issues one TestUserModel call with the probe's settings
// applied and classifies the response. ok=true → "ok"; ok=false →
// "rejected" with the upstream error string.
func runProbe(ctx context.Context, c reevev1connect.ModelProvidersServiceClient, providerID, modelID string, p probe, timeout time.Duration) probeResult {
	settings := &reevev1.CallSettings{}
	if p.Mutate != nil {
		p.Mutate(settings)
	}

	probeCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	resp, err := c.TestUserModel(probeCtx, connect.NewRequest(&reevev1.TestUserModelRequest{
		UserModelProviderId: providerID,
		ModelId:             modelID,
		CallSettings:        settings,
	}))
	if err != nil {
		return probeResult{Probe: p.Name, Status: "rejected", ErrorMessage: shorten(err.Error())}
	}
	r := resp.Msg
	if r.Ok {
		return probeResult{Probe: p.Name, Status: "ok", LatencyMs: r.LatencyMs}
	}
	return probeResult{Probe: p.Name, Status: "rejected", ErrorMessage: shorten(r.ErrorMessage), LatencyMs: r.LatencyMs}
}

func capsFromProto(c *reevev1.ModelCapabilities) capabilities {
	if c == nil {
		return capabilities{}
	}
	return capabilities{
		Thinking:        c.Thinking,
		ToolUse:         c.ToolUse,
		Vision:          c.Vision,
		PromptCaching:   c.PromptCaching,
		GeneratesImages: c.GeneratesImages,
	}
}

// shorten caps an error string at a length friendly for JSON inspection.
func shorten(s string) string {
	const limit = 400
	s = strings.TrimSpace(s)
	if len(s) <= limit {
		return s
	}
	return s[:limit] + "…"
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "discover-constraints: "+format+"\n", args...)
	os.Exit(1)
}
