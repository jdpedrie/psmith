package modelproviders

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

// Capability probing: ask the model what it can do by making it do it.
//
// Capabilities on a user_model come from catalog metadata and hand-editing, so
// they are a claim. Claims go stale and catalogs lie by omission, and a custom
// endpoint has no catalog at all. The failure is asymmetric: a capability the
// model has but we do not know about stays switched off, and
// validateModelCapabilities then refuses sends that would have worked.
//
// A probe is the empirical counterpart to RefreshUserModelMetadata. That
// refreshes what the catalog says; this reports what the model does.

// probeOutcome is what one probe learned.
type probeOutcome int

const (
	// outcomeInconclusive is the default on purpose. Anything that does not
	// clearly demonstrate support or clearly demonstrate refusal lands here,
	// including every network failure, so a bad minute never gets recorded as
	// a fact about a model.
	outcomeInconclusive probeOutcome = iota
	outcomeSupported
	outcomeUnsupported
	// outcomeSkipped means the capability is not worth probing. Stated rather
	// than silently omitted, so a user reading the results knows the
	// difference between "we asked and could not tell" and "we did not ask".
	outcomeSkipped
)

// capabilityProbe is one test.
type capabilityProbe struct {
	name string
	// skip, when non-empty, means do not spend a call; the string is why.
	skip string
	// build returns the request that demonstrates the capability.
	build func(modelID string) providers.SendRequest
	// judge reads what came back and decides.
	judge func(o observed) (probeOutcome, string)
}

// observed is the drained result of one probe call.
type observed struct {
	sendErr    error
	streamErr  string
	text       string
	chunkCount int
	textChunks int
	toolUse    bool
	thinking   bool
	latency    time.Duration
}

// A 1x1 transparent PNG. The smallest thing that is unambiguously an image:
// a vision probe should cost a rounding error, and a real photo would bill
// tokens for content nobody reads.
const onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

func probes() []capabilityProbe {
	return []capabilityProbe{
		{
			name: "streaming",
			build: func(id string) providers.SendRequest {
				return providers.SendRequest{
					ModelID:  id,
					Messages: []providers.WireMessage{{Role: "user", Content: "Reply with the single word: ok"}},
				}
			},
			judge: func(o observed) (probeOutcome, string) {
				if o.sendErr != nil {
					return outcomeInconclusive, firstLine(o.sendErr.Error())
				}
				if o.streamErr != "" {
					return outcomeInconclusive, o.streamErr
				}
				if o.textChunks > 0 {
					return outcomeSupported, "returned text over a stream"
				}
				return outcomeInconclusive, "stream produced no text"
			},
		},
		{
			name: "tool_use",
			build: func(id string) providers.SendRequest {
				return providers.SendRequest{
					ModelID: id,
					Messages: []providers.WireMessage{{
						Role:    "user",
						Content: "Call the echo tool with value \"probe\". Do not reply in text.",
					}},
					Tools: []providers.ToolDef{{
						Name:        "echo",
						Description: "Echoes a value back. Call this when asked to.",
						InputSchema: []byte(`{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}`),
					}},
				}
			},
			judge: func(o observed) (probeOutcome, string) {
				// An API that cannot do tools rejects the request outright,
				// which is the one signal clean enough to call unsupported.
				if o.sendErr != nil {
					if mentionsTools(o.sendErr.Error()) {
						return outcomeUnsupported, firstLine(o.sendErr.Error())
					}
					return outcomeInconclusive, firstLine(o.sendErr.Error())
				}
				if o.toolUse {
					return outcomeSupported, "emitted a tool call"
				}
				if o.streamErr != "" {
					return outcomeInconclusive, o.streamErr
				}
				// Accepted the tools and answered in prose instead. The API
				// supports tools; this model just declined to use one, which
				// is a judgement call we cannot make from here.
				return outcomeInconclusive, "accepted tools but answered in text"
			},
		},
		{
			name: "vision",
			build: func(id string) providers.SendRequest {
				img, _ := base64.StdEncoding.DecodeString(onePixelPNG)
				return providers.SendRequest{
					ModelID: id,
					Messages: []providers.WireMessage{{
						Role:    "user",
						Content: "Reply with the single word: ok",
						Attachments: []providers.Attachment{{
							Kind:     providers.AttachmentImage,
							MimeType: "image/png",
							Filename: "probe.png",
							Data:     img,
						}},
					}},
				}
			},
			judge: func(o observed) (probeOutcome, string) {
				if o.sendErr != nil {
					if mentionsImages(o.sendErr.Error()) {
						return outcomeUnsupported, firstLine(o.sendErr.Error())
					}
					return outcomeInconclusive, firstLine(o.sendErr.Error())
				}
				if o.streamErr != "" {
					if mentionsImages(o.streamErr) {
						return outcomeUnsupported, o.streamErr
					}
					return outcomeInconclusive, o.streamErr
				}
				if o.textChunks > 0 {
					return outcomeSupported, "accepted an image attachment"
				}
				return outcomeInconclusive, "no reply to an image attachment"
			},
		},
		{
			name: "thinking",
			build: func(id string) providers.SendRequest {
				return providers.SendRequest{
					ModelID: id,
					Messages: []providers.WireMessage{{
						Role:    "user",
						Content: "What is 17 times 23? Work it out.",
					}},
					Settings: providers.CallSettings{
						Thinking: &providers.ThinkingSettings{Effort: providers.ThinkingEffortLow},
					},
				}
			},
			judge: func(o observed) (probeOutcome, string) {
				if o.sendErr != nil {
					if mentionsThinking(o.sendErr.Error()) {
						return outcomeUnsupported, firstLine(o.sendErr.Error())
					}
					return outcomeInconclusive, firstLine(o.sendErr.Error())
				}
				if o.thinking {
					return outcomeSupported, "emitted reasoning"
				}
				if o.streamErr != "" {
					return outcomeInconclusive, o.streamErr
				}
				// Plenty of APIs accept a thinking parameter and ignore it.
				// Silence is not a refusal, so this stays inconclusive.
				return outcomeInconclusive, "accepted the setting but returned no reasoning"
			},
		},
		{
			name: "prompt_caching",
			skip: "needs two calls with a prefix over the provider's minimum, which costs more than the answer is worth",
		},
		{
			name: "generates_images",
			skip: "would bill for a generated image, and the response shape is not comparable across providers",
		},
	}
}

// mentionsTools and friends look for the upstream telling us a capability is
// absent. Deliberately narrow: matching loosely would turn an unrelated 400
// into a recorded "unsupported", which is the one mistake that makes a probe
// worse than no probe.
func mentionsTools(s string) bool {
	return containsAny(strings.ToLower(s), "tool", "function call", "functions are not")
}

func mentionsImages(s string) bool {
	return containsAny(strings.ToLower(s), "image", "vision", "multimodal", "does not support media")
}

func mentionsThinking(s string) bool {
	return containsAny(strings.ToLower(s), "thinking", "reasoning", "extended thought")
}

func containsAny(hay string, needles ...string) bool {
	for _, n := range needles {
		if strings.Contains(hay, n) {
			return true
		}
	}
	return false
}

// runProbe issues one probe and drains the stream.
func runProbe(ctx context.Context, p providers.StatelessProvider, req providers.SendRequest) observed {
	start := time.Now()
	var o observed

	src, err := p.Send(ctx, req)
	if err != nil {
		o.sendErr = err
		o.latency = time.Since(start)
		return o
	}
	var text strings.Builder
	for ch := range src {
		o.chunkCount++
		switch ch.Type {
		case providers.ChunkText:
			o.textChunks++
			if text.Len() < 200 {
				text.WriteString(chunkText(ch))
			}
		case providers.ChunkThinking, providers.ChunkThinkingSignature:
			o.thinking = true
		case providers.ChunkToolUseStart, providers.ChunkToolUseDelta, providers.ChunkToolUseEnd:
			o.toolUse = true
		case providers.ChunkError:
			o.streamErr = firstLine(chunkErrorText(ch))
		}
	}
	o.text = text.String()
	o.latency = time.Since(start)
	return o
}

// applyProbeResults folds probe outcomes into a capability set.
//
// Additive only. A probe may turn a capability ON and may never turn one OFF,
// for three reasons that all point the same way: an "unsupported" verdict can
// come from a quirk of the probe's own prompt, a user may have set the flag
// deliberately and knows something we do not, and clearing a flag silently
// breaks sends that were working. The asymmetry is the point — a probe that
// can only help is one a user can run without reading the code first.
//
// Returns the new set and the names of everything it switched on.
func applyProbeResults(current modelmeta.Capabilities, results map[string]probeOutcome) (modelmeta.Capabilities, []string) {
	next := current
	var enabled []string
	set := func(name string, field *bool) {
		if results[name] == outcomeSupported && !*field {
			*field = true
			enabled = append(enabled, name)
		}
	}
	set("streaming", &next.Streaming)
	set("tool_use", &next.ToolUse)
	set("vision", &next.Vision)
	set("thinking", &next.Thinking)
	set("prompt_caching", &next.PromptCaching)
	set("generates_images", &next.GeneratesImages)
	return next, enabled
}

// disagreements lists capabilities the stored definition claims but the probe
// could not demonstrate.
//
// Reported, never acted on. It is the useful half of a result the probe
// refuses to apply: a model marked vision-capable that rejects an image is
// worth a user's attention even though we will not clear the flag ourselves.
func disagreements(current modelmeta.Capabilities, results map[string]probeOutcome) []string {
	var out []string
	check := func(name string, claimed bool) {
		if claimed && results[name] == outcomeUnsupported {
			out = append(out, name)
		}
	}
	check("streaming", current.Streaming)
	check("tool_use", current.ToolUse)
	check("vision", current.Vision)
	check("thinking", current.Thinking)
	check("prompt_caching", current.PromptCaching)
	check("generates_images", current.GeneratesImages)
	return out
}

var errNotStateless = errors.New("probing needs a stateless provider")

func chunkText(ch providers.Chunk) string {
	var p struct {
		Text string `json:"text"`
	}
	_ = json.Unmarshal(ch.Payload, &p)
	return p.Text
}

func chunkErrorText(ch providers.Chunk) string {
	var p struct {
		Message string `json:"message"`
		Error   string `json:"error"`
	}
	_ = json.Unmarshal(ch.Payload, &p)
	if p.Message != "" {
		return p.Message
	}
	if p.Error != "" {
		return p.Error
	}
	return string(ch.Payload)
}

// ProbeUserModel exercises the model and folds what it learned into the stored
// capabilities.
//
// User-triggered, never automatic: every probe bills a few tokens on the
// user's own key, and spending someone's money on a background sweep they did
// not ask for is not a trade to make on their behalf.
//
// Defaults to a dry run. `apply` has to be set explicitly, so the first thing
// a user does is look at the results rather than discover a changed
// definition.
func (s *Service) ProbeUserModel(
	ctx context.Context,
	req *connect.Request[psmithv1.ProbeUserModelRequest],
) (*connect.Response[psmithv1.ProbeUserModelResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	modelID := strings.TrimSpace(req.Msg.ModelId)
	if modelID == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("model_id is required"))
	}
	existing, err := s.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: row.ID,
		ModelID:             modelID,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeNotFound, fmt.Errorf("model %q is not enabled on this provider", modelID))
	}

	driver, err := s.opener().Build(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, err)
	}
	stateless, ok := driver.(providers.StatelessProvider)
	if !ok {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errNotStateless)
	}

	var current modelmeta.Capabilities
	if len(existing.Capabilities) > 0 {
		_ = json.Unmarshal(existing.Capabilities, &current)
	}

	results := make([]*psmithv1.CapabilityProbeResult, 0, len(probes()))
	outcomes := make(map[string]probeOutcome, len(probes()))

	for _, p := range probes() {
		if p.skip != "" {
			outcomes[p.name] = outcomeSkipped
			results = append(results, &psmithv1.CapabilityProbeResult{
				Capability: p.name,
				Outcome:    psmithv1.ProbeOutcome_PROBE_OUTCOME_SKIPPED,
				Detail:     p.skip,
			})
			continue
		}
		// Per-probe timeout. One slow capability must not hold the others
		// hostage; a probe that hangs is inconclusive, same as any failure.
		pctx, cancel := context.WithTimeout(ctx, modelTestTimeout)
		o := runProbe(pctx, stateless, p.build(modelID))
		cancel()

		outcome, detail := p.judge(o)
		outcomes[p.name] = outcome
		results = append(results, &psmithv1.CapabilityProbeResult{
			Capability: p.name,
			Outcome:    probeOutcomeToProto(outcome),
			Detail:     detail,
			LatencyMs:  o.latency.Milliseconds(),
		})
	}

	next, enabled := applyProbeResults(current, outcomes)
	contradicted := disagreements(current, outcomes)

	if req.Msg.Apply && len(enabled) > 0 {
		blob, merr := json.Marshal(next)
		if merr != nil {
			return nil, connect.NewError(connect.CodeInternal, merr)
		}
		if _, uerr := s.queries.UpdateUserModelCapabilities(ctx, store.UpdateUserModelCapabilitiesParams{
			UserModelProviderID: row.ID,
			ModelID:             modelID,
			Capabilities:        blob,
		}); uerr != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("write capabilities: %w", uerr))
		}
	}

	// Report the set the caller would see on a re-read: the merged one when we
	// wrote, the stored one when we did not.
	shown := current
	if req.Msg.Apply {
		shown = next
	}
	return connect.NewResponse(&psmithv1.ProbeUserModelResponse{
		Results:      results,
		Capabilities: capabilitiesToProto(shown),
		Enabled:      enabled,
		Contradicted: contradicted,
	}), nil
}

func probeOutcomeToProto(o probeOutcome) psmithv1.ProbeOutcome {
	switch o {
	case outcomeSupported:
		return psmithv1.ProbeOutcome_PROBE_OUTCOME_SUPPORTED
	case outcomeUnsupported:
		return psmithv1.ProbeOutcome_PROBE_OUTCOME_UNSUPPORTED
	case outcomeSkipped:
		return psmithv1.ProbeOutcome_PROBE_OUTCOME_SKIPPED
	default:
		return psmithv1.ProbeOutcome_PROBE_OUTCOME_INCONCLUSIVE
	}
}
