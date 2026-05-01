package google

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/clark/internal/providers"
)

// sseFrame writes a single SSE event with a JSON-encoded data payload.
func sseFrame(w http.ResponseWriter, payload any) {
	raw, _ := json.Marshal(payload)
	fmt.Fprintf(w, "data: %s\n\n", raw)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// mustMarshalUsage wraps a typed usageMetadata as json.RawMessage so
// tests can express "the upstream sent this usage shape" while the
// pump's contract is "I receive raw bytes in env.UsageMetadata."
func mustMarshalUsage(u usageMetadata) json.RawMessage {
	b, _ := json.Marshal(u)
	return b
}

// streamHandler emits a canned generateContent SSE sequence:
//   - text deltas split across two events
//   - a final event carrying usage metadata
func streamHandler(t *testing.T) http.Handler {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1beta/models/gemini-test:streamGenerateContent",
		func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost {
				t.Errorf("unexpected method %s", r.Method)
			}
			if got := r.URL.Query().Get("alt"); got != "sse" {
				t.Errorf("alt=%q want sse", got)
			}
			if got := r.URL.Query().Get("key"); got == "" {
				t.Errorf("missing key query param")
			}
			w.Header().Set("Content-Type", "text/event-stream")
			sseFrame(w, streamEnvelope{
				Candidates: []candidate{{
					Content: geminiContent{
						Role:  "model",
						Parts: []geminiPart{{Text: "Hello, "}},
					},
				}},
			})
			sseFrame(w, streamEnvelope{
				Candidates: []candidate{{
					Content: geminiContent{
						Role:  "model",
						Parts: []geminiPart{{Text: "world!"}},
					},
					FinishReason: "STOP",
				}},
			})
			sseFrame(w, streamEnvelope{
				UsageMetadata: mustMarshalUsage(usageMetadata{
					PromptTokenCount:     12,
					CandidatesTokenCount: 3,
					TotalTokenCount:      15,
				}),
			})
		})
	return mux
}

func TestSend_HappyPath(t *testing.T) {
	srv := httptest.NewServer(streamHandler(t))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ch, err := d.Send(ctx, providers.SendRequest{
		ModelID: "gemini-test",
		Messages: []providers.WireMessage{
			{Role: "system", Content: "be brief"},
			{Role: "user", Content: "hi"},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var got []providers.Chunk
	for c := range ch {
		got = append(got, c)
	}

	wantTypes := []providers.ChunkType{
		providers.ChunkText,
		providers.ChunkText,
		providers.ChunkUsage,
		providers.ChunkDone,
	}
	if len(got) != len(wantTypes) {
		t.Fatalf("got %d chunks, want %d: %+v", len(got), len(wantTypes), got)
	}
	for i, w := range wantTypes {
		if got[i].Type != w {
			t.Errorf("chunk[%d].Type=%q want %q", i, got[i].Type, w)
		}
	}

	// Reassemble text.
	var text string
	for _, c := range got {
		if c.Type == providers.ChunkText {
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			text += p.Text
		}
	}
	if text != "Hello, world!" {
		t.Errorf("text=%q want %q", text, "Hello, world!")
	}

	// Usage chunk values.
	var usage providers.Usage
	for _, c := range got {
		if c.Type == providers.ChunkUsage {
			if err := json.Unmarshal(c.Payload, &usage); err != nil {
				t.Fatalf("usage payload: %v", err)
			}
		}
	}
	if usage.InputTokens == nil || *usage.InputTokens != 12 {
		t.Errorf("input_tokens=%v want 12", usage.InputTokens)
	}
	if usage.OutputTokens == nil || *usage.OutputTokens != 3 {
		t.Errorf("output_tokens=%v want 3", usage.OutputTokens)
	}
}

func TestSend_ThinkingDelta(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		sseFrame(w, streamEnvelope{
			Candidates: []candidate{{
				Content: geminiContent{
					Role: "model",
					Parts: []geminiPart{
						{Text: "let me think...", Thought: true},
						{Text: "answer."},
					},
				},
				FinishReason: "STOP",
			}},
		})
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	var sawThinking, sawText bool
	for c := range ch {
		switch c.Type {
		case providers.ChunkThinking:
			sawThinking = true
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			if !strings.Contains(p.Text, "let me think") {
				t.Errorf("thinking text=%q", p.Text)
			}
		case providers.ChunkText:
			sawText = true
		}
	}
	if !sawThinking {
		t.Error("expected ChunkThinking from a thought=true part")
	}
	if !sawText {
		t.Error("expected ChunkText from a normal part")
	}
}

func TestSend_CachedContentTokensAsCacheRead(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		sseFrame(w, streamEnvelope{
			UsageMetadata: mustMarshalUsage(usageMetadata{
				PromptTokenCount:        100,
				CandidatesTokenCount:    20,
				CachedContentTokenCount: 75,
				ThoughtsTokenCount:      4,
			}),
		})
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	var usage providers.Usage
	for c := range ch {
		if c.Type == providers.ChunkUsage {
			_ = json.Unmarshal(c.Payload, &usage)
		}
	}
	if usage.CacheReadTokens == nil || *usage.CacheReadTokens != 75 {
		t.Errorf("cache_read_tokens=%v want 75", usage.CacheReadTokens)
	}
	if usage.ReasoningTokens == nil || *usage.ReasoningTokens != 4 {
		t.Errorf("reasoning_tokens=%v want 4", usage.ReasoningTokens)
	}
}

// TestSend_CacheTokensDetailsFallback — when Gemini emits the
// per-modality breakdown (cacheTokensDetails) but omits the
// CachedContentTokenCount summary, the driver must sum the breakdown
// rather than reporting nil. Defends against the silent-no-cache
// failure mode the user surfaced from the docs.
func TestSend_CacheTokensDetailsFallback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		// Hand-rolled JSON because we want a payload that has
		// cacheTokensDetails but NOT cachedContentTokenCount — our
		// typed usageMetadata struct would happily round-trip both,
		// hiding the very condition we're testing.
		fmt.Fprintln(w, `data: {"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20,"cacheTokensDetails":[{"modality":"TEXT","tokenCount":60},{"modality":"IMAGE","tokenCount":15}]}}`)
		fmt.Fprintln(w)
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	var usage providers.Usage
	for c := range ch {
		if c.Type == providers.ChunkUsage {
			_ = json.Unmarshal(c.Payload, &usage)
		}
	}
	if usage.CacheReadTokens == nil || *usage.CacheReadTokens != 75 {
		t.Errorf("cache_read_tokens=%v want 75 (sum of modality breakdown 60+15)", usage.CacheReadTokens)
	}
}

// TestSend_PreservesUnknownUsageFields — provider_usage_raw must carry
// the upstream bytes verbatim so unknown / new Gemini fields
// (toolUsePromptTokenCount, *TokensDetails arrays, future additions)
// survive into the DB. Pre-fix, the pump re-marshaled our typed struct
// and silently dropped any field we didn't model.
func TestSend_PreservesUnknownUsageFields(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintln(w, `data: {"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20,"toolUsePromptTokenCount":33,"someFutureField":{"foo":"bar"}}}`)
		fmt.Fprintln(w)
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	var usage providers.Usage
	for c := range ch {
		if c.Type == providers.ChunkUsage {
			_ = json.Unmarshal(c.Payload, &usage)
		}
	}
	if len(usage.ProviderRaw) == 0 {
		t.Fatal("ProviderRaw missing")
	}
	rawStr := string(usage.ProviderRaw)
	if !strings.Contains(rawStr, "toolUsePromptTokenCount") {
		t.Errorf("toolUsePromptTokenCount not preserved in raw bytes: %s", rawStr)
	}
	if !strings.Contains(rawStr, "someFutureField") {
		t.Errorf("unknown field someFutureField dropped from raw bytes: %s", rawStr)
	}
}

func TestSend_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"code":400,"message":"bad request","status":"INVALID_ARGUMENT"}}`))
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send returned err (expected error chunk): %v", err)
	}
	var sawError, sawDone bool
	for c := range ch {
		switch c.Type {
		case providers.ChunkError:
			sawError = true
		case providers.ChunkDone:
			sawDone = true
		}
	}
	if !sawError {
		t.Error("expected ChunkError from 400")
	}
	if !sawDone {
		t.Error("expected ChunkDone")
	}
}

func TestSend_MissingModelID(t *testing.T) {
	d := newDriverWithBaseURL(t, "http://unused", providers.Deps{})
	_, err := d.Send(context.Background(), providers.SendRequest{
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err == nil {
		t.Error("expected error for missing model_id")
	}
}

// TestSend_SystemMessageRouting verifies that a `system` wire role lands in
// `system_instruction` and not in `contents`.
func TestSend_SystemMessageRouting(t *testing.T) {
	const term = "data: {}\n\n"
	srv, captured := captureRequest(t, "/v1beta/models/gemini-test:streamGenerateContent", term)

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "gemini-test",
		Messages: []providers.WireMessage{
			{Role: "system", Content: "be terse"},
			{Role: "user", Content: "hi"},
			{Role: "assistant", Content: "ok"},
			{Role: "user", Content: "again"},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	body := *captured
	// system_instruction must contain "be terse"
	if !strings.Contains(body, `"system_instruction"`) {
		t.Errorf("body missing system_instruction; body=%s", body)
	}
	if !strings.Contains(body, `"be terse"`) {
		t.Errorf("body missing system text; body=%s", body)
	}
	// system text must NOT appear in contents.
	// Easy way: parse the body and assert structure.
	var parsed generateContentRequest
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		t.Fatalf("parse body: %v; body=%s", err, body)
	}
	if parsed.SystemInstruction == nil || len(parsed.SystemInstruction.Parts) != 1 ||
		parsed.SystemInstruction.Parts[0].Text != "be terse" {
		t.Errorf("system_instruction wrong: %+v", parsed.SystemInstruction)
	}
	if len(parsed.Contents) != 3 {
		t.Errorf("expected 3 contents (user/model/user), got %d", len(parsed.Contents))
	}
	wantRoles := []string{"user", "model", "user"}
	for i, c := range parsed.Contents {
		if c.Role != wantRoles[i] {
			t.Errorf("contents[%d].role=%q want %q", i, c.Role, wantRoles[i])
		}
	}
	// The assistant message must use "model" role, not "assistant".
	for _, c := range parsed.Contents {
		if c.Role == "assistant" {
			t.Errorf("found wire role 'assistant'; want 'model'")
		}
	}
}

// TestSend_AllSettings — every CallSettings field plus GoogleExtras lands on
// the wire in the right place.
func TestSend_AllSettings(t *testing.T) {
	const term = "data: {}\n\n"
	srv, captured := captureRequest(t, "/v1beta/models/gemini-2.5-flash:streamGenerateContent", term)

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	temp := 0.42
	topP := 0.9
	topK := 7
	maxOut := 256
	enabled := true
	budget := 4096
	respMime := "application/json"
	candCount := 2
	harassment := providers.HarmThresholdBlockNone
	hateSpeech := providers.HarmThresholdBlockOnlyHigh
	sexuallyExplicit := providers.HarmThresholdBlockMediumAndAbove
	dangerousContent := providers.HarmThresholdBlockLowAndAbove

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "gemini-2.5-flash",
		Messages: []providers.WireMessage{
			{Role: "user", Content: "hi"},
		},
		Settings: providers.CallSettings{
			Temperature:     &temp,
			TopP:            &topP,
			TopK:            &topK,
			MaxOutputTokens: &maxOut,
			StopSequences:   []string{"END"},
			Thinking: &providers.ThinkingSettings{
				Enabled:      &enabled,
				BudgetTokens: &budget,
			},
			Google: &providers.GoogleExtras{
				ResponseMimeType: &respMime,
				ResponseSchema:   []byte(`{"type":"object","properties":{"x":{"type":"integer"}}}`),
				CandidateCount:   &candCount,
				SafetySettings: &providers.SafetySettings{
					Harassment:       &harassment,
					HateSpeech:       &hateSpeech,
					SexuallyExplicit: &sexuallyExplicit,
					DangerousContent: &dangerousContent,
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	body := *captured

	// Parse + assert structurally, since fragment-grepping is fragile for
	// nested schema bytes.
	var parsed generateContentRequest
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		t.Fatalf("parse body: %v; body=%s", err, body)
	}
	if parsed.GenerationConfig == nil {
		t.Fatalf("generationConfig missing; body=%s", body)
	}
	gc := parsed.GenerationConfig
	if gc.Temperature == nil || *gc.Temperature != 0.42 {
		t.Errorf("temperature=%v want 0.42", gc.Temperature)
	}
	if gc.TopP == nil || *gc.TopP != 0.9 {
		t.Errorf("top_p=%v want 0.9", gc.TopP)
	}
	if gc.TopK == nil || *gc.TopK != 7 {
		t.Errorf("top_k=%v want 7", gc.TopK)
	}
	if gc.MaxOutputTokens == nil || *gc.MaxOutputTokens != 256 {
		t.Errorf("max_output_tokens=%v want 256", gc.MaxOutputTokens)
	}
	if len(gc.StopSequences) != 1 || gc.StopSequences[0] != "END" {
		t.Errorf("stop_sequences=%v", gc.StopSequences)
	}
	if gc.CandidateCount == nil || *gc.CandidateCount != 2 {
		t.Errorf("candidate_count=%v want 2", gc.CandidateCount)
	}
	if gc.ResponseMimeType == nil || *gc.ResponseMimeType != "application/json" {
		t.Errorf("response_mime_type=%v want application/json", gc.ResponseMimeType)
	}
	// response_schema must be inlined as JSON, not a string.
	if gc.ResponseSchema == nil {
		t.Errorf("response_schema missing")
	} else {
		var schema map[string]any
		if err := json.Unmarshal(gc.ResponseSchema, &schema); err != nil {
			t.Errorf("response_schema not valid JSON: %v", err)
		}
		if schema["type"] != "object" {
			t.Errorf("response_schema not inlined; got %v", schema)
		}
	}
	if gc.ThinkingConfig == nil {
		t.Fatalf("thinking_config missing")
	}
	if gc.ThinkingConfig.IncludeThoughts == nil || !*gc.ThinkingConfig.IncludeThoughts {
		t.Errorf("includeThoughts=%v want true", gc.ThinkingConfig.IncludeThoughts)
	}
	if gc.ThinkingConfig.ThinkingBudget == nil || *gc.ThinkingConfig.ThinkingBudget != 4096 {
		t.Errorf("thinkingBudget=%v want 4096", gc.ThinkingConfig.ThinkingBudget)
	}

	// Safety settings: 4 entries, all categories represented.
	if len(parsed.SafetySettings) != 4 {
		t.Fatalf("safetySettings count=%d want 4", len(parsed.SafetySettings))
	}
	gotByCategory := map[string]string{}
	for _, s := range parsed.SafetySettings {
		gotByCategory[s.Category] = s.Threshold
	}
	want := map[string]string{
		"HARM_CATEGORY_HARASSMENT":        "BLOCK_NONE",
		"HARM_CATEGORY_HATE_SPEECH":       "BLOCK_ONLY_HIGH",
		"HARM_CATEGORY_SEXUALLY_EXPLICIT": "BLOCK_MEDIUM_AND_ABOVE",
		"HARM_CATEGORY_DANGEROUS_CONTENT": "BLOCK_LOW_AND_ABOVE",
	}
	for cat, threshold := range want {
		if got := gotByCategory[cat]; got != threshold {
			t.Errorf("safety[%s]=%q want %q", cat, got, threshold)
		}
	}
}

// TestSend_PartialSafety_OnlyNonNilEntries ensures we don't write
// HARM_THRESHOLD_UNSPECIFIED entries to the wire when a category is unset.
func TestSend_PartialSafety_OnlyNonNilEntries(t *testing.T) {
	const term = "data: {}\n\n"
	srv, captured := captureRequest(t, "/v1beta/models/gemini-test:streamGenerateContent", term)

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	hateSpeech := providers.HarmThresholdBlockOnlyHigh

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: providers.CallSettings{
			Google: &providers.GoogleExtras{
				SafetySettings: &providers.SafetySettings{
					HateSpeech: &hateSpeech,
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	var parsed generateContentRequest
	if err := json.Unmarshal([]byte(*captured), &parsed); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(parsed.SafetySettings) != 1 {
		t.Fatalf("safetySettings=%d entries, want 1", len(parsed.SafetySettings))
	}
	if parsed.SafetySettings[0].Category != "HARM_CATEGORY_HATE_SPEECH" {
		t.Errorf("category=%q want HARM_CATEGORY_HATE_SPEECH", parsed.SafetySettings[0].Category)
	}
}

// TestSend_NoSettingsLeavesGenerationConfigEmpty verifies that omitting
// CallSettings entirely keeps generationConfig out of the wire payload.
func TestSend_NoSettingsLeavesGenerationConfigEmpty(t *testing.T) {
	const term = "data: {}\n\n"
	srv, captured := captureRequest(t, "/v1beta/models/gemini-test:streamGenerateContent", term)

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}
	if strings.Contains(*captured, "generationConfig") {
		t.Errorf("generationConfig should be omitted when no settings; body=%s", *captured)
	}
}
