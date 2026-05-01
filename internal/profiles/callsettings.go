package profiles

import (
	"google.golang.org/protobuf/encoding/protojson"

	clarkv1 "github.com/jdpedrie/reeve/gen/clark/v1"
)

// callSettingsMarshaller / callSettingsUnmarshaller pin a protojson config so
// the on-disk shape stays stable across go-protobuf upgrades. Unset scalars
// stay omitted (no UseProtoNames-induced churn) and unknown fields are
// tolerated on read so a downgrade after a future proto field addition
// doesn't fail to load existing rows.
var (
	callSettingsMarshaller = protojson.MarshalOptions{
		UseProtoNames:  true,
		EmitUnpopulated: false,
	}
	callSettingsUnmarshaller = protojson.UnmarshalOptions{
		DiscardUnknown: true,
	}
)

// MarshalCallSettings encodes a *CallSettings to JSONB-compatible bytes.
// Returns (nil, nil) for nil input — the column stays NULL.
func MarshalCallSettings(cs *clarkv1.CallSettings) ([]byte, error) {
	if cs == nil {
		return nil, nil
	}
	return callSettingsMarshaller.Marshal(cs)
}

// UnmarshalCallSettings decodes JSONB bytes back to a *CallSettings. Empty
// input returns (nil, nil). Unknown fields are discarded so old binaries
// gracefully read forward-compatible rows.
func UnmarshalCallSettings(b []byte) (*clarkv1.CallSettings, error) {
	if len(b) == 0 {
		return nil, nil
	}
	var out clarkv1.CallSettings
	if err := callSettingsUnmarshaller.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// MergeCallSettings overlays `higher` on top of `lower`, returning a new
// CallSettings where each scalar field is `higher.field ?? lower.field`. The
// merge is sparse: any unset field on `higher` falls through to `lower`.
//
// Repeated/map fields (`stop_sequences`, `OpenAIExtras.logit_bias`) are
// whole-field overrides — if `higher` has any entries the entire collection
// wins; otherwise `lower` passes through. Concatenation would compose two
// "stop on X" lists from different layers in a way users would have a hard
// time reasoning about, so the resolver picks one or the other.
//
// Nested message fields (`thinking`, `anthropic`, `openai`, `google`) recurse
// one level so a partially-set `higher.openai.seed` (with an unset
// `higher.openai.frequency_penalty`) lets the unset field inherit from
// `lower.openai.frequency_penalty` rather than being clobbered by an
// otherwise-empty `OpenAIExtras` block on top.
//
// Either argument may be nil. If both are nil the result is nil.
func MergeCallSettings(higher, lower *clarkv1.CallSettings) *clarkv1.CallSettings {
	if higher == nil && lower == nil {
		return nil
	}
	if higher == nil {
		// Defensive copy so the caller can't reach back through the
		// returned pointer and mutate the layer we read from.
		return cloneCallSettings(lower)
	}
	if lower == nil {
		return cloneCallSettings(higher)
	}

	out := &clarkv1.CallSettings{}

	// --- scalar fields ---
	out.Temperature = pickFloat(higher.Temperature, lower.Temperature)
	out.TopP = pickFloat(higher.TopP, lower.TopP)
	out.MaxOutputTokens = pickInt32(higher.MaxOutputTokens, lower.MaxOutputTokens)
	out.TopK = pickInt32(higher.TopK, lower.TopK)

	// --- repeated stop_sequences: whole-field replacement ---
	if len(higher.StopSequences) > 0 {
		out.StopSequences = append([]string(nil), higher.StopSequences...)
	} else if len(lower.StopSequences) > 0 {
		out.StopSequences = append([]string(nil), lower.StopSequences...)
	}

	// --- cross-cutting toggles ---
	out.ExplicitCache = pickBool(higher.ExplicitCache, lower.ExplicitCache)

	// --- nested messages: one level of recursive sparse merge ---
	out.Thinking = mergeThinking(higher.Thinking, lower.Thinking)
	out.Anthropic = mergeAnthropicExtras(higher.Anthropic, lower.Anthropic)
	out.Openai = mergeOpenAIExtras(higher.Openai, lower.Openai)
	out.Google = mergeGoogleExtras(higher.Google, lower.Google)

	return out
}

// cloneCallSettings returns a deep copy. Used when only one of higher/lower
// is non-nil so we never hand the caller our input back.
func cloneCallSettings(s *clarkv1.CallSettings) *clarkv1.CallSettings {
	if s == nil {
		return nil
	}
	out := &clarkv1.CallSettings{
		Temperature:     copyFloat(s.Temperature),
		TopP:            copyFloat(s.TopP),
		MaxOutputTokens: copyInt32(s.MaxOutputTokens),
		TopK:            copyInt32(s.TopK),
		ExplicitCache:   copyBool(s.ExplicitCache),
	}
	if len(s.StopSequences) > 0 {
		out.StopSequences = append([]string(nil), s.StopSequences...)
	}
	out.Thinking = cloneThinking(s.Thinking)
	out.Anthropic = cloneAnthropicExtras(s.Anthropic)
	out.Openai = cloneOpenAIExtras(s.Openai)
	out.Google = cloneGoogleExtras(s.Google)
	return out
}

// --- ThinkingSettings -------------------------------------------------------

func mergeThinking(higher, lower *clarkv1.ThinkingSettings) *clarkv1.ThinkingSettings {
	if higher == nil && lower == nil {
		return nil
	}
	if higher == nil {
		return cloneThinking(lower)
	}
	if lower == nil {
		return cloneThinking(higher)
	}
	return &clarkv1.ThinkingSettings{
		Enabled:      pickBool(higher.Enabled, lower.Enabled),
		BudgetTokens: pickInt32(higher.BudgetTokens, lower.BudgetTokens),
	}
}

func cloneThinking(t *clarkv1.ThinkingSettings) *clarkv1.ThinkingSettings {
	if t == nil {
		return nil
	}
	return &clarkv1.ThinkingSettings{
		Enabled:      copyBool(t.Enabled),
		BudgetTokens: copyInt32(t.BudgetTokens),
	}
}

// --- AnthropicExtras --------------------------------------------------------

// mergeAnthropicExtras sparse-merges two AnthropicExtras blocks per-field.
// `higher` wins where set; `lower` fills in unset slots. Either side nil is
// equivalent to that side carrying no fields.
func mergeAnthropicExtras(higher, lower *clarkv1.AnthropicExtras) *clarkv1.AnthropicExtras {
	if higher == nil && lower == nil {
		return nil
	}
	if higher == nil {
		return cloneAnthropicExtras(lower)
	}
	if lower == nil {
		return cloneAnthropicExtras(higher)
	}
	return &clarkv1.AnthropicExtras{
		CacheEnabled: pickBool(higher.CacheEnabled, lower.CacheEnabled),
		CacheTtl:     pickCacheTTL(higher.CacheTtl, lower.CacheTtl),
	}
}

func cloneAnthropicExtras(a *clarkv1.AnthropicExtras) *clarkv1.AnthropicExtras {
	if a == nil {
		return nil
	}
	return &clarkv1.AnthropicExtras{
		CacheEnabled: copyBool(a.CacheEnabled),
		CacheTtl:     copyCacheTTL(a.CacheTtl),
	}
}

func pickCacheTTL(higher, lower *clarkv1.CacheTTL) *clarkv1.CacheTTL {
	if higher != nil {
		v := *higher
		return &v
	}
	if lower != nil {
		v := *lower
		return &v
	}
	return nil
}

func copyCacheTTL(v *clarkv1.CacheTTL) *clarkv1.CacheTTL {
	if v == nil {
		return nil
	}
	x := *v
	return &x
}

// --- OpenAIExtras -----------------------------------------------------------

func mergeOpenAIExtras(higher, lower *clarkv1.OpenAIExtras) *clarkv1.OpenAIExtras {
	if higher == nil && lower == nil {
		return nil
	}
	if higher == nil {
		return cloneOpenAIExtras(lower)
	}
	if lower == nil {
		return cloneOpenAIExtras(higher)
	}
	out := &clarkv1.OpenAIExtras{
		Seed:              pickInt32(higher.Seed, lower.Seed),
		FrequencyPenalty:  pickFloat(higher.FrequencyPenalty, lower.FrequencyPenalty),
		PresencePenalty:   pickFloat(higher.PresencePenalty, lower.PresencePenalty),
		TopLogprobs:       pickInt32(higher.TopLogprobs, lower.TopLogprobs),
		ParallelToolCalls: pickBool(higher.ParallelToolCalls, lower.ParallelToolCalls),
	}
	out.ServiceTier = pickServiceTier(higher.ServiceTier, lower.ServiceTier)
	// response_format: whole-field override (it's a oneof; partial merge has
	// no meaningful semantics — text/json_object/json_schema are mutually
	// exclusive shapes).
	if higher.ResponseFormat != nil {
		out.ResponseFormat = cloneResponseFormat(higher.ResponseFormat)
	} else if lower.ResponseFormat != nil {
		out.ResponseFormat = cloneResponseFormat(lower.ResponseFormat)
	}
	// logit_bias is a map — whole-field replace per the doc.
	if len(higher.LogitBias) > 0 {
		out.LogitBias = cloneLogitBias(higher.LogitBias)
	} else if len(lower.LogitBias) > 0 {
		out.LogitBias = cloneLogitBias(lower.LogitBias)
	}
	return out
}

func cloneOpenAIExtras(o *clarkv1.OpenAIExtras) *clarkv1.OpenAIExtras {
	if o == nil {
		return nil
	}
	out := &clarkv1.OpenAIExtras{
		Seed:              copyInt32(o.Seed),
		FrequencyPenalty:  copyFloat(o.FrequencyPenalty),
		PresencePenalty:   copyFloat(o.PresencePenalty),
		TopLogprobs:       copyInt32(o.TopLogprobs),
		ParallelToolCalls: copyBool(o.ParallelToolCalls),
		ServiceTier:       copyServiceTier(o.ServiceTier),
		ResponseFormat:    cloneResponseFormat(o.ResponseFormat),
	}
	if len(o.LogitBias) > 0 {
		out.LogitBias = cloneLogitBias(o.LogitBias)
	}
	return out
}

func cloneResponseFormat(rf *clarkv1.ResponseFormat) *clarkv1.ResponseFormat {
	if rf == nil {
		return nil
	}
	out := &clarkv1.ResponseFormat{}
	switch k := rf.Kind.(type) {
	case *clarkv1.ResponseFormat_Text:
		out.Kind = &clarkv1.ResponseFormat_Text{Text: k.Text}
	case *clarkv1.ResponseFormat_JsonObject:
		out.Kind = &clarkv1.ResponseFormat_JsonObject{JsonObject: k.JsonObject}
	case *clarkv1.ResponseFormat_JsonSchema:
		var schema *clarkv1.JsonSchema
		if k.JsonSchema != nil {
			schema = &clarkv1.JsonSchema{
				Name:        k.JsonSchema.Name,
				Description: copyString(k.JsonSchema.Description),
				Strict:      copyBool(k.JsonSchema.Strict),
			}
			if len(k.JsonSchema.Schema) > 0 {
				schema.Schema = append([]byte(nil), k.JsonSchema.Schema...)
			}
		}
		out.Kind = &clarkv1.ResponseFormat_JsonSchema{JsonSchema: schema}
	}
	return out
}

func cloneLogitBias(in map[int32]float64) map[int32]float64 {
	out := make(map[int32]float64, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

// --- GoogleExtras -----------------------------------------------------------

func mergeGoogleExtras(higher, lower *clarkv1.GoogleExtras) *clarkv1.GoogleExtras {
	if higher == nil && lower == nil {
		return nil
	}
	if higher == nil {
		return cloneGoogleExtras(lower)
	}
	if lower == nil {
		return cloneGoogleExtras(higher)
	}
	out := &clarkv1.GoogleExtras{
		ResponseMimeType: pickString(higher.ResponseMimeType, lower.ResponseMimeType),
		CandidateCount:   pickInt32(higher.CandidateCount, lower.CandidateCount),
	}
	out.SafetySettings = mergeSafetySettings(higher.SafetySettings, lower.SafetySettings)
	if len(higher.ResponseSchema) > 0 {
		out.ResponseSchema = append([]byte(nil), higher.ResponseSchema...)
	} else if len(lower.ResponseSchema) > 0 {
		out.ResponseSchema = append([]byte(nil), lower.ResponseSchema...)
	}
	return out
}

func cloneGoogleExtras(g *clarkv1.GoogleExtras) *clarkv1.GoogleExtras {
	if g == nil {
		return nil
	}
	out := &clarkv1.GoogleExtras{
		ResponseMimeType: copyString(g.ResponseMimeType),
		CandidateCount:   copyInt32(g.CandidateCount),
	}
	out.SafetySettings = cloneSafetySettings(g.SafetySettings)
	if len(g.ResponseSchema) > 0 {
		out.ResponseSchema = append([]byte(nil), g.ResponseSchema...)
	}
	return out
}

func mergeSafetySettings(higher, lower *clarkv1.SafetySettings) *clarkv1.SafetySettings {
	if higher == nil && lower == nil {
		return nil
	}
	if higher == nil {
		return cloneSafetySettings(lower)
	}
	if lower == nil {
		return cloneSafetySettings(higher)
	}
	return &clarkv1.SafetySettings{
		Harassment:       pickHarmThreshold(higher.Harassment, lower.Harassment),
		HateSpeech:       pickHarmThreshold(higher.HateSpeech, lower.HateSpeech),
		SexuallyExplicit: pickHarmThreshold(higher.SexuallyExplicit, lower.SexuallyExplicit),
		DangerousContent: pickHarmThreshold(higher.DangerousContent, lower.DangerousContent),
	}
}

func cloneSafetySettings(s *clarkv1.SafetySettings) *clarkv1.SafetySettings {
	if s == nil {
		return nil
	}
	return &clarkv1.SafetySettings{
		Harassment:       copyHarmThreshold(s.Harassment),
		HateSpeech:       copyHarmThreshold(s.HateSpeech),
		SexuallyExplicit: copyHarmThreshold(s.SexuallyExplicit),
		DangerousContent: copyHarmThreshold(s.DangerousContent),
	}
}

// --- pointer helpers --------------------------------------------------------

func pickFloat(higher, lower *float64) *float64 {
	if higher != nil {
		v := *higher
		return &v
	}
	if lower != nil {
		v := *lower
		return &v
	}
	return nil
}

func pickInt32(higher, lower *int32) *int32 {
	if higher != nil {
		v := *higher
		return &v
	}
	if lower != nil {
		v := *lower
		return &v
	}
	return nil
}

func pickBool(higher, lower *bool) *bool {
	if higher != nil {
		v := *higher
		return &v
	}
	if lower != nil {
		v := *lower
		return &v
	}
	return nil
}

func pickString(higher, lower *string) *string {
	if higher != nil {
		v := *higher
		return &v
	}
	if lower != nil {
		v := *lower
		return &v
	}
	return nil
}

func pickServiceTier(higher, lower *clarkv1.ServiceTier) *clarkv1.ServiceTier {
	if higher != nil {
		v := *higher
		return &v
	}
	if lower != nil {
		v := *lower
		return &v
	}
	return nil
}

func copyServiceTier(v *clarkv1.ServiceTier) *clarkv1.ServiceTier {
	if v == nil {
		return nil
	}
	x := *v
	return &x
}

func pickHarmThreshold(higher, lower *clarkv1.HarmThreshold) *clarkv1.HarmThreshold {
	if higher != nil {
		v := *higher
		return &v
	}
	if lower != nil {
		v := *lower
		return &v
	}
	return nil
}

func copyFloat(v *float64) *float64 {
	if v == nil {
		return nil
	}
	x := *v
	return &x
}

func copyInt32(v *int32) *int32 {
	if v == nil {
		return nil
	}
	x := *v
	return &x
}

func copyBool(v *bool) *bool {
	if v == nil {
		return nil
	}
	x := *v
	return &x
}

func copyString(v *string) *string {
	if v == nil {
		return nil
	}
	x := *v
	return &x
}

func copyHarmThreshold(v *clarkv1.HarmThreshold) *clarkv1.HarmThreshold {
	if v == nil {
		return nil
	}
	x := *v
	return &x
}
