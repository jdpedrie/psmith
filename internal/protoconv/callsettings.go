// Package protoconv holds pure-function converters between the
// generated protobuf shapes and the internal Go types they map to.
//
// Lives in its own package so multiple services (conversations,
// modelproviders, …) can share the same converter without one
// importing the other and risking a cycle through their domain
// types. Strictly stateless: every function is a deterministic
// map from input to output.
package protoconv

import (
	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/providers"
)

// CallSettings converts the proto wire shape into the internal
// providers.CallSettings struct that drivers consume. nil input maps
// to a zero-value output (every field unset). Used at every site
// that turns a SendMessageRequest / TestUserModelRequest /
// CompactRequest into a driver dispatch.
func CallSettings(s *reevev1.CallSettings) providers.CallSettings {
	if s == nil {
		return providers.CallSettings{}
	}
	out := providers.CallSettings{
		Temperature:   s.Temperature,
		TopP:          s.TopP,
		ExplicitCache: s.ExplicitCache,
	}
	if s.MaxOutputTokens != nil {
		v := int(*s.MaxOutputTokens)
		out.MaxOutputTokens = &v
	}
	if s.TopK != nil {
		v := int(*s.TopK)
		out.TopK = &v
	}
	if len(s.StopSequences) > 0 {
		out.StopSequences = append([]string(nil), s.StopSequences...)
	}
	if t := s.Thinking; t != nil {
		ts := &providers.ThinkingSettings{Enabled: t.Enabled}
		if t.BudgetTokens != nil {
			v := int(*t.BudgetTokens)
			ts.BudgetTokens = &v
		}
		out.Thinking = ts
	}
	if ae := s.Anthropic; ae != nil {
		out.Anthropic = &providers.AnthropicExtras{
			CacheEnabled: ae.CacheEnabled,
			CacheTTL:     CacheTTL(ae.CacheTtl),
		}
	}
	if oe := s.Openai; oe != nil {
		out.OpenAI = &providers.OpenAIExtras{
			FrequencyPenalty:  oe.FrequencyPenalty,
			PresencePenalty:   oe.PresencePenalty,
			ParallelToolCalls: oe.ParallelToolCalls,
		}
		if oe.Seed != nil {
			v := int(*oe.Seed)
			out.OpenAI.Seed = &v
		}
		if oe.TopLogprobs != nil {
			v := int(*oe.TopLogprobs)
			out.OpenAI.TopLogprobs = &v
		}
		if oe.ServiceTier != nil {
			v := ServiceTier(*oe.ServiceTier)
			out.OpenAI.ServiceTier = &v
		}
		if oe.ResponseFormat != nil {
			out.OpenAI.ResponseFormat = ResponseFormat(oe.ResponseFormat)
		}
		if len(oe.LogitBias) > 0 {
			lb := make(map[int32]float64, len(oe.LogitBias))
			for k, v := range oe.LogitBias {
				lb[k] = v
			}
			out.OpenAI.LogitBias = lb
		}
	}
	if ge := s.Google; ge != nil {
		out.Google = &providers.GoogleExtras{
			ResponseMimeType: ge.ResponseMimeType,
		}
		if ge.CandidateCount != nil {
			v := int(*ge.CandidateCount)
			out.Google.CandidateCount = &v
		}
		if len(ge.ResponseSchema) > 0 {
			out.Google.ResponseSchema = append([]byte(nil), ge.ResponseSchema...)
		}
		if ge.SafetySettings != nil {
			out.Google.SafetySettings = &providers.SafetySettings{
				Harassment:       HarmThreshold(ge.SafetySettings.Harassment),
				HateSpeech:       HarmThreshold(ge.SafetySettings.HateSpeech),
				SexuallyExplicit: HarmThreshold(ge.SafetySettings.SexuallyExplicit),
				DangerousContent: HarmThreshold(ge.SafetySettings.DangerousContent),
			}
		}
	}
	return out
}

// CacheTTL converts the Anthropic cache-TTL enum.
func CacheTTL(in *reevev1.CacheTTL) providers.CacheTTL {
	if in == nil {
		return providers.CacheTTLUnspecified
	}
	switch *in {
	case reevev1.CacheTTL_CACHE_TTL_5M:
		return providers.CacheTTL5m
	case reevev1.CacheTTL_CACHE_TTL_1H:
		return providers.CacheTTL1h
	}
	return providers.CacheTTLUnspecified
}

// ServiceTier converts the OpenAI service-tier enum.
func ServiceTier(in reevev1.ServiceTier) providers.ServiceTier {
	switch in {
	case reevev1.ServiceTier_SERVICE_TIER_AUTO:
		return providers.ServiceTierAuto
	case reevev1.ServiceTier_SERVICE_TIER_STANDARD:
		return providers.ServiceTierStandard
	case reevev1.ServiceTier_SERVICE_TIER_PRIORITY:
		return providers.ServiceTierPriority
	}
	return providers.ServiceTierUnspecified
}

// ResponseFormat converts the OpenAI structured-output oneof.
func ResponseFormat(rf *reevev1.ResponseFormat) *providers.ResponseFormat {
	if rf == nil {
		return nil
	}
	out := &providers.ResponseFormat{}
	switch k := rf.Kind.(type) {
	case *reevev1.ResponseFormat_Text:
		v := k.Text
		out.Text = &v
	case *reevev1.ResponseFormat_JsonObject:
		v := k.JsonObject
		out.JSONObject = &v
	case *reevev1.ResponseFormat_JsonSchema:
		if k.JsonSchema != nil {
			out.JSONSchema = &providers.JSONSchema{
				Name:        k.JsonSchema.Name,
				Description: k.JsonSchema.Description,
				Strict:      k.JsonSchema.Strict,
			}
			if len(k.JsonSchema.Schema) > 0 {
				out.JSONSchema.Schema = append([]byte(nil), k.JsonSchema.Schema...)
			}
		}
	}
	return out
}

// HarmThreshold converts the Google safety-threshold enum.
func HarmThreshold(in *reevev1.HarmThreshold) *providers.HarmThreshold {
	if in == nil {
		return nil
	}
	var v providers.HarmThreshold
	switch *in {
	case reevev1.HarmThreshold_HARM_THRESHOLD_BLOCK_NONE:
		v = providers.HarmThresholdBlockNone
	case reevev1.HarmThreshold_HARM_THRESHOLD_BLOCK_LOW_AND_ABOVE:
		v = providers.HarmThresholdBlockLowAndAbove
	case reevev1.HarmThreshold_HARM_THRESHOLD_BLOCK_MEDIUM_AND_ABOVE:
		v = providers.HarmThresholdBlockMediumAndAbove
	case reevev1.HarmThreshold_HARM_THRESHOLD_BLOCK_ONLY_HIGH:
		v = providers.HarmThresholdBlockOnlyHigh
	default:
		v = providers.HarmThresholdUnspecified
	}
	return &v
}
