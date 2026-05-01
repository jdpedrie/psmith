package google

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/jdpedrie/clark/internal/providers"
)

// errorReadLimit caps how much error-body we retain to surface in error
// messages. Gemini error payloads are typically <2k; bigger means something's
// wrong upstream and we don't want to log megabytes back.
const errorReadLimit = 8 * 1024

// --- Wire-shape types ----------------------------------------------------
//
// We intentionally model the request and response shapes here rather than
// pulling in the go-genai SDK — the surface is small, well-documented, and
// stable enough that a few hand-typed structs are easier to reason about
// (and easier to evolve) than wrapping the SDK.

// generateContentRequest is the body POSTed to streamGenerateContent.
type generateContentRequest struct {
	Contents          []geminiContent      `json:"contents,omitempty"`
	SystemInstruction *geminiContent       `json:"system_instruction,omitempty"`
	GenerationConfig  *generationConfig    `json:"generationConfig,omitempty"`
	SafetySettings    []geminiSafetySetting `json:"safetySettings,omitempty"`

	// CachedContent references a previously-created cachedContents resource
	// (see Driver.CreateCachedContent). Format: "cachedContents/<id>". When
	// set, Gemini reuses the cached prefix and bills only the unique
	// suffix — usage shows up as cachedContentTokenCount.
	CachedContent string `json:"cachedContent,omitempty"`
}

type geminiContent struct {
	Role  string       `json:"role,omitempty"` // "user" or "model"; omitted for system_instruction
	Parts []geminiPart `json:"parts"`
}

type geminiPart struct {
	Text    string `json:"text,omitempty"`
	Thought bool   `json:"thought,omitempty"`
}

type generationConfig struct {
	Temperature      *float64         `json:"temperature,omitempty"`
	TopP             *float64         `json:"topP,omitempty"`
	TopK             *int             `json:"topK,omitempty"`
	MaxOutputTokens  *int             `json:"maxOutputTokens,omitempty"`
	StopSequences    []string         `json:"stopSequences,omitempty"`
	CandidateCount   *int             `json:"candidateCount,omitempty"`
	ResponseMimeType *string          `json:"responseMimeType,omitempty"`
	ResponseSchema   json.RawMessage  `json:"responseSchema,omitempty"`
	ThinkingConfig   *thinkingConfig  `json:"thinkingConfig,omitempty"`
}

type thinkingConfig struct {
	IncludeThoughts *bool `json:"includeThoughts,omitempty"`
	ThinkingBudget  *int  `json:"thinkingBudget,omitempty"`
}

type geminiSafetySetting struct {
	Category  string `json:"category"`
	Threshold string `json:"threshold"`
}

// --- Streaming response shape -------------------------------------------

// streamEnvelope is one Server-Sent Event payload from streamGenerateContent.
type streamEnvelope struct {
	Candidates    []candidate    `json:"candidates,omitempty"`
	UsageMetadata *usageMetadata `json:"usageMetadata,omitempty"`
	PromptFeedback *json.RawMessage `json:"promptFeedback,omitempty"`
	Error         *geminiError   `json:"error,omitempty"`
}

type candidate struct {
	Content       geminiContent `json:"content"`
	FinishReason  string        `json:"finishReason,omitempty"`
	Index         int           `json:"index,omitempty"`
	SafetyRatings []json.RawMessage `json:"safetyRatings,omitempty"`
}

type usageMetadata struct {
	PromptTokenCount        int `json:"promptTokenCount,omitempty"`
	CandidatesTokenCount    int `json:"candidatesTokenCount,omitempty"`
	TotalTokenCount         int `json:"totalTokenCount,omitempty"`
	CachedContentTokenCount int `json:"cachedContentTokenCount,omitempty"`
	ThoughtsTokenCount      int `json:"thoughtsTokenCount,omitempty"`
}

type geminiError struct {
	Code    int    `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
	Status  string `json:"status,omitempty"`
}

// --- Public API ---------------------------------------------------------

// Send dispatches a turn through Gemini's streamGenerateContent SSE endpoint
// and translates the upstream stream into the normalized chunk vocabulary
// defined by providers.Chunk.
//
// Event mapping:
//
//	candidates[].content.parts[].text (thought=true)  → ChunkThinking
//	candidates[].content.parts[].text (thought=false) → ChunkText
//	usageMetadata                                     → ChunkUsage
//	error                                             → ChunkError
//	(stream end)                                      → ChunkDone
//
// Non-2xx responses surface as a single ChunkError followed by ChunkDone
// (or, for pre-stream errors, an error from Send itself).
func (d *Driver) Send(ctx context.Context, req providers.SendRequest) (<-chan providers.Chunk, error) {
	if req.ModelID == "" {
		return nil, errors.New("google: model_id is required")
	}

	body, err := buildRequestBody(req)
	if err != nil {
		return nil, err
	}
	bodyJSON, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("google: marshal request: %w", err)
	}

	endpoint, err := d.streamEndpoint(req.ModelID)
	if err != nil {
		return nil, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(bodyJSON))
	if err != nil {
		return nil, fmt.Errorf("google: build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")

	resp, err := d.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("google: send: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body := readBoundedError(resp)
		_ = resp.Body.Close()
		// Surface the failure as a chunk + Done so the supervisor's normal
		// terminal-state handling fires. We could equivalently return an
		// error from Send; the supervisor handles both, but the chunk path
		// keeps behaviour closer to the OpenAI/Anthropic streams which only
		// fail mid-stream.
		out := make(chan providers.Chunk, 2)
		emit(out, providers.ChunkError, map[string]any{
			"message": fmt.Sprintf("HTTP %d: %s", resp.StatusCode, body),
			"code":    fmt.Sprintf("%d", resp.StatusCode),
		})
		emit(out, providers.ChunkDone, map[string]any{})
		close(out)
		return out, nil
	}

	out := make(chan providers.Chunk, 16)
	go d.pumpStream(ctx, resp.Body, out)
	return out, nil
}

// streamEndpoint builds the SSE URL: /v1beta/models/{model}:streamGenerateContent?alt=sse&key=...
func (d *Driver) streamEndpoint(modelID string) (string, error) {
	u, err := url.Parse(d.baseURL + "/models/" + url.PathEscape(modelID) + ":streamGenerateContent")
	if err != nil {
		return "", fmt.Errorf("google: build endpoint: %w", err)
	}
	q := u.Query()
	q.Set("alt", "sse")
	q.Set("key", d.cfg.APIKey)
	u.RawQuery = q.Encode()
	return u.String(), nil
}

// pumpStream consumes the SSE body, decodes per-event JSON envelopes, and
// translates them into the chunk vocabulary. It always emits exactly one
// ChunkDone before closing the channel — even on error paths, so subscribers
// see a clean terminator.
func (d *Driver) pumpStream(ctx context.Context, body io.ReadCloser, out chan<- providers.Chunk) {
	defer close(out)
	defer body.Close()

	// Aggregate usage across the stream. Gemini emits usageMetadata on the
	// final event, but in practice it can show up on any event — keep the
	// last-seen values and emit one ChunkUsage right before ChunkDone.
	var lastUsage *usageMetadata
	var lastUsageRaw json.RawMessage

	scanner := bufio.NewScanner(body)
	// Allow large SSE events — Gemini frames can include long thought blocks.
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	var dataAccum strings.Builder
	flush := func() bool {
		if dataAccum.Len() == 0 {
			return true
		}
		raw := dataAccum.String()
		dataAccum.Reset()
		// Skip explicit terminators just in case (Gemini doesn't send "[DONE]"
		// but mirroring OpenAI behaviour costs nothing).
		if strings.TrimSpace(raw) == "[DONE]" {
			return true
		}
		var env streamEnvelope
		if err := json.Unmarshal([]byte(raw), &env); err != nil {
			emit(out, providers.ChunkError, map[string]string{
				"message": fmt.Sprintf("decode SSE event: %v", err),
			})
			return true
		}
		if env.Error != nil {
			emit(out, providers.ChunkError, map[string]any{
				"message": env.Error.Message,
				"code":    env.Error.Status,
			})
		}
		for _, c := range env.Candidates {
			for _, p := range c.Content.Parts {
				if p.Text == "" {
					continue
				}
				if p.Thought {
					emit(out, providers.ChunkThinking, map[string]string{"text": p.Text})
				} else {
					emit(out, providers.ChunkText, map[string]string{"text": p.Text})
				}
			}
		}
		if env.UsageMetadata != nil {
			lastUsage = env.UsageMetadata
			lastUsageRaw, _ = json.Marshal(env.UsageMetadata)
		}
		return true
	}

	for scanner.Scan() {
		select {
		case <-ctx.Done():
			emit(out, providers.ChunkError, map[string]string{"message": ctx.Err().Error()})
			emit(out, providers.ChunkDone, map[string]any{})
			return
		default:
		}
		line := scanner.Text()
		if line == "" {
			// SSE event boundary.
			if !flush() {
				return
			}
			continue
		}
		// SSE format: lines starting with "data: " carry the payload; ":"
		// is a comment, anything else (event:, id:) is metadata we ignore.
		if strings.HasPrefix(line, ":") {
			continue
		}
		if strings.HasPrefix(line, "data:") {
			payload := strings.TrimPrefix(line, "data:")
			payload = strings.TrimPrefix(payload, " ")
			if dataAccum.Len() > 0 {
				dataAccum.WriteByte('\n')
			}
			dataAccum.WriteString(payload)
		}
		// "event:", "id:", "retry:" lines are silently dropped — Gemini
		// doesn't use them but the format allows them.
	}
	// Trailing event without a blank line terminator.
	flush()

	if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
		emit(out, providers.ChunkError, map[string]string{"message": err.Error()})
	}

	if lastUsage != nil {
		emitUsage(out, *lastUsage, lastUsageRaw)
	}
	emit(out, providers.ChunkDone, map[string]any{})
}

// emitUsage normalizes a usageMetadata into ChunkUsage. CachedContentTokenCount
// maps to cache_read_tokens; ThoughtsTokenCount to reasoning_tokens.
func emitUsage(out chan<- providers.Chunk, u usageMetadata, raw json.RawMessage) {
	in := u.PromptTokenCount
	outTok := u.CandidatesTokenCount
	usage := providers.Usage{}
	if in > 0 {
		usage.InputTokens = &in
	}
	if outTok > 0 {
		usage.OutputTokens = &outTok
	}
	if u.CachedContentTokenCount > 0 {
		v := u.CachedContentTokenCount
		usage.CacheReadTokens = &v
	}
	if u.ThoughtsTokenCount > 0 {
		v := u.ThoughtsTokenCount
		usage.ReasoningTokens = &v
	}
	if usage.InputTokens == nil && usage.OutputTokens == nil &&
		usage.CacheReadTokens == nil && usage.ReasoningTokens == nil {
		return
	}
	usage.ProviderRaw = raw
	payload, err := json.Marshal(usage)
	if err != nil {
		return
	}
	out <- providers.Chunk{Type: providers.ChunkUsage, Payload: payload}
}

// emit marshals and pushes one chunk. JSON-marshal failures fall back to "{}"
// — the payloads in this driver are static maps and never fail in practice.
func emit(out chan<- providers.Chunk, typ providers.ChunkType, payload any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		raw = []byte(`{}`)
	}
	out <- providers.Chunk{Type: typ, Payload: raw}
}

// readBoundedError reads up to errorReadLimit bytes from a non-2xx response
// body for use in error messages. Doesn't close the body.
func readBoundedError(resp *http.Response) string {
	if resp == nil || resp.Body == nil {
		return ""
	}
	r := io.LimitReader(resp.Body, errorReadLimit)
	b, _ := io.ReadAll(r)
	return strings.TrimSpace(string(b))
}

// --- Request building ---------------------------------------------------

// buildRequestBody translates Clark's wire shape into Gemini's request body.
//
// Roles:
//   - "system" → system_instruction (separate field; not part of contents).
//     Multiple system messages concatenate into a single system_instruction
//     with one part per message — Gemini accepts multiple parts.
//   - "user"   → contents[] role="user".
//   - "assistant" → contents[] role="model" (Gemini's name for the assistant
//     side).
//
// CallSettings translation:
//   - common temperature/top_p/top_k/max_output_tokens/stop_sequences →
//     generationConfig.{temperature, topP, topK, maxOutputTokens, stopSequences}.
//   - Thinking.{Enabled, BudgetTokens} → generationConfig.thinkingConfig.
//   - Google extras (safety, response_mime_type, response_schema, candidate_count) → corresponding fields.
//
// Unsupported fields are silently dropped — driver translation is intentionally
// lossy on the way down (the per-driver test suite asserts the wire shape).
func buildRequestBody(req providers.SendRequest) (*generateContentRequest, error) {
	body := &generateContentRequest{}

	for _, m := range req.Messages {
		switch m.Role {
		case "system":
			if body.SystemInstruction == nil {
				body.SystemInstruction = &geminiContent{}
			}
			body.SystemInstruction.Parts = append(body.SystemInstruction.Parts, geminiPart{
				Text: m.Content,
			})
		case "user":
			body.Contents = append(body.Contents, geminiContent{
				Role:  "user",
				Parts: []geminiPart{{Text: m.Content}},
			})
		case "assistant":
			body.Contents = append(body.Contents, geminiContent{
				Role:  "model",
				Parts: []geminiPart{{Text: m.Content}},
			})
		default:
			return nil, fmt.Errorf("google: unsupported wire role %q", m.Role)
		}
	}

	gc := generationConfigFromSettings(req.Settings)
	if gc != nil {
		body.GenerationConfig = gc
	}

	if g := req.Settings.Google; g != nil {
		if g.SafetySettings != nil {
			body.SafetySettings = safetySettingsToWire(g.SafetySettings)
		}
		if g.CachedContent != nil && *g.CachedContent != "" {
			body.CachedContent = *g.CachedContent
		}
	}

	return body, nil
}

// generationConfigFromSettings collapses CallSettings into Gemini's
// generationConfig. Returns nil if every field is empty so the field is
// omitted from the wire entirely.
func generationConfigFromSettings(s providers.CallSettings) *generationConfig {
	gc := &generationConfig{}
	any := false
	if s.Temperature != nil {
		gc.Temperature = s.Temperature
		any = true
	}
	if s.TopP != nil {
		gc.TopP = s.TopP
		any = true
	}
	if s.TopK != nil {
		gc.TopK = s.TopK
		any = true
	}
	if s.MaxOutputTokens != nil {
		gc.MaxOutputTokens = s.MaxOutputTokens
		any = true
	}
	if len(s.StopSequences) > 0 {
		gc.StopSequences = append([]string(nil), s.StopSequences...)
		any = true
	}
	if t := s.Thinking; t != nil {
		tc := &thinkingConfig{}
		set := false
		if t.Enabled != nil {
			tc.IncludeThoughts = t.Enabled
			set = true
		}
		if t.BudgetTokens != nil {
			tc.ThinkingBudget = t.BudgetTokens
			set = true
		}
		if set {
			gc.ThinkingConfig = tc
			any = true
		}
	}
	if g := s.Google; g != nil {
		if g.ResponseMimeType != nil && *g.ResponseMimeType != "" {
			gc.ResponseMimeType = g.ResponseMimeType
			any = true
		}
		if len(g.ResponseSchema) > 0 {
			// The schema field on the wire takes a parsed JSON value, not a
			// string. Round-trip the bytes so we don't double-encode them.
			var decoded json.RawMessage
			if err := json.Unmarshal(g.ResponseSchema, &decoded); err == nil {
				gc.ResponseSchema = decoded
			} else {
				// Malformed bytes — pass them through; the API will reject.
				gc.ResponseSchema = json.RawMessage(g.ResponseSchema)
			}
			any = true
		}
		if g.CandidateCount != nil {
			gc.CandidateCount = g.CandidateCount
			any = true
		}
	}
	if !any {
		return nil
	}
	return gc
}

// safetySettingsToWire translates Clark's SafetySettings struct into the
// Gemini wire shape. Each non-nil threshold becomes one entry. Unset
// thresholds are simply omitted (Gemini falls back to its default).
func safetySettingsToWire(s *providers.SafetySettings) []geminiSafetySetting {
	if s == nil {
		return nil
	}
	var out []geminiSafetySetting
	addIf := func(category string, t *providers.HarmThreshold) {
		if t == nil {
			return
		}
		threshold := harmThresholdToWire(*t)
		if threshold == "" {
			return // unspecified — drop
		}
		out = append(out, geminiSafetySetting{
			Category:  category,
			Threshold: threshold,
		})
	}
	addIf("HARM_CATEGORY_HARASSMENT", s.Harassment)
	addIf("HARM_CATEGORY_HATE_SPEECH", s.HateSpeech)
	addIf("HARM_CATEGORY_SEXUALLY_EXPLICIT", s.SexuallyExplicit)
	addIf("HARM_CATEGORY_DANGEROUS_CONTENT", s.DangerousContent)
	return out
}

// harmThresholdToWire maps Clark's enum to Gemini's enum strings.
func harmThresholdToWire(t providers.HarmThreshold) string {
	switch t {
	case providers.HarmThresholdBlockNone:
		return "BLOCK_NONE"
	case providers.HarmThresholdBlockLowAndAbove:
		return "BLOCK_LOW_AND_ABOVE"
	case providers.HarmThresholdBlockMediumAndAbove:
		return "BLOCK_MEDIUM_AND_ABOVE"
	case providers.HarmThresholdBlockOnlyHigh:
		return "BLOCK_ONLY_HIGH"
	}
	return ""
}
