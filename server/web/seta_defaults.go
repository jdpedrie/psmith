package web

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// csForm is CallSettings as the defaults pages edit it: every field a string
// or a choice, "" meaning not set. It maps to and from the proto so the pages
// round-trip every field, including ones they don't draw open.
type csForm struct {
	Temp, TopP, MaxTok, TopK string
	Stops                    []string
	Effort                   string // "" off low medium high xhigh
	Explicit                 string // "" on off
	PCache                   string // "" on off
	TTL                      string // "" 5m 1h
	Seed, Freq, Pres, Logp   string
	PTC                      string // "" on off
	Tier                     string // "" auto standard priority
	RFmt                     string // "" text json_object json_schema
	SchemaName, SchemaDesc   string
	Schema                   string
	SchemaStrict             bool
	Bias                     string
	Harass, Hate, Sex, Dang  string // "" none low medium high
	Mime, RSchema, Cand      string
}

var effortByName = map[string]psmithv1.ThinkingEffort{
	"off": psmithv1.ThinkingEffort_THINKING_EFFORT_OFF, "low": psmithv1.ThinkingEffort_THINKING_EFFORT_LOW,
	"medium": psmithv1.ThinkingEffort_THINKING_EFFORT_MEDIUM, "high": psmithv1.ThinkingEffort_THINKING_EFFORT_HIGH,
	"xhigh": psmithv1.ThinkingEffort_THINKING_EFFORT_XHIGH,
}

var effortLabels = map[string]string{"": "Not set", "off": "Off", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra high"}

var harmByName = map[string]psmithv1.HarmThreshold{
	"none": psmithv1.HarmThreshold_HARM_THRESHOLD_BLOCK_NONE, "low": psmithv1.HarmThreshold_HARM_THRESHOLD_BLOCK_LOW_AND_ABOVE,
	"medium": psmithv1.HarmThreshold_HARM_THRESHOLD_BLOCK_MEDIUM_AND_ABOVE, "high": psmithv1.HarmThreshold_HARM_THRESHOLD_BLOCK_ONLY_HIGH,
}

var tierByName = map[string]psmithv1.ServiceTier{
	"auto": psmithv1.ServiceTier_SERVICE_TIER_AUTO, "standard": psmithv1.ServiceTier_SERVICE_TIER_STANDARD, "priority": psmithv1.ServiceTier_SERVICE_TIER_PRIORITY,
}

func saNameOf[T comparable](m map[string]T, v T) string {
	for k, x := range m {
		if x == v {
			return k
		}
	}
	return ""
}

func saOptBool(b *bool) string {
	if b == nil {
		return ""
	}
	if *b {
		return "on"
	}
	return "off"
}

func csFromProto(cs *psmithv1.CallSettings) csForm {
	var f csForm
	if cs == nil {
		return f
	}
	if cs.Temperature != nil {
		f.Temp = saFloat(cs.GetTemperature())
	}
	if cs.TopP != nil {
		f.TopP = saFloat(cs.GetTopP())
	}
	if cs.MaxOutputTokens != nil {
		f.MaxTok = saGroupInt(int64(cs.GetMaxOutputTokens()))
	}
	if cs.TopK != nil {
		f.TopK = strconv.Itoa(int(cs.GetTopK()))
	}
	f.Stops = append(f.Stops, cs.GetStopSequences()...)
	f.Effort = saNameOf(effortByName, cs.GetThinking().GetEffort())
	f.Explicit = saOptBool(cs.ExplicitCache)
	if a := cs.GetAnthropic(); a != nil {
		f.PCache = saOptBool(a.CacheEnabled)
		switch a.GetCacheTtl() {
		case psmithv1.CacheTTL_CACHE_TTL_5M:
			f.TTL = "5m"
		case psmithv1.CacheTTL_CACHE_TTL_1H:
			f.TTL = "1h"
		}
	}
	if o := cs.GetOpenai(); o != nil {
		if o.Seed != nil {
			f.Seed = strconv.Itoa(int(o.GetSeed()))
		}
		if o.FrequencyPenalty != nil {
			f.Freq = saFloat(o.GetFrequencyPenalty())
		}
		if o.PresencePenalty != nil {
			f.Pres = saFloat(o.GetPresencePenalty())
		}
		if o.TopLogprobs != nil {
			f.Logp = strconv.Itoa(int(o.GetTopLogprobs()))
		}
		f.PTC = saOptBool(o.ParallelToolCalls)
		f.Tier = saNameOf(tierByName, o.GetServiceTier())
		switch k := o.GetResponseFormat().GetKind().(type) {
		case *psmithv1.ResponseFormat_Text:
			f.RFmt = "text"
		case *psmithv1.ResponseFormat_JsonObject:
			f.RFmt = "json_object"
		case *psmithv1.ResponseFormat_JsonSchema:
			f.RFmt = "json_schema"
			f.SchemaName = k.JsonSchema.GetName()
			f.SchemaDesc = k.JsonSchema.GetDescription()
			f.Schema = string(k.JsonSchema.GetSchema())
			f.SchemaStrict = k.JsonSchema.GetStrict()
		}
		if len(o.GetLogitBias()) > 0 {
			m := map[string]float64{}
			for tok, b := range o.GetLogitBias() {
				m[strconv.Itoa(int(tok))] = b
			}
			raw, _ := json.Marshal(m)
			f.Bias = string(raw)
		}
	}
	if g := cs.GetGoogle(); g != nil {
		if s := g.GetSafetySettings(); s != nil {
			harm := func(p *psmithv1.HarmThreshold) string {
				if p == nil {
					return ""
				}
				return saNameOf(harmByName, *p)
			}
			f.Harass, f.Hate, f.Sex, f.Dang = harm(s.Harassment), harm(s.HateSpeech), harm(s.SexuallyExplicit), harm(s.DangerousContent)
		}
		f.Mime = g.GetResponseMimeType()
		f.RSchema = string(g.GetResponseSchema())
		if g.CandidateCount != nil {
			f.Cand = strconv.Itoa(int(g.GetCandidateCount()))
		}
	}
	return f
}

// csFormFromValues reads the defaults form. Stop sequences arrive as one
// "stop" value per chip plus the "stop_new" input.
func csFormFromValues(v url.Values) csForm {
	g := func(k string) string { return strings.TrimSpace(v.Get(k)) }
	f := csForm{
		Temp: g("temperature"), TopP: g("top_p"), MaxTok: g("max_output_tokens"), TopK: g("top_k"),
		Effort: g("effort"), Explicit: g("explicit_cache"), PCache: g("cache_enabled"), TTL: g("cache_ttl"),
		Seed: g("seed"), Freq: g("frequency_penalty"), Pres: g("presence_penalty"), Logp: g("top_logprobs"),
		PTC: g("parallel_tool_calls"), Tier: g("service_tier"), RFmt: g("response_format"),
		SchemaName: g("schema_name"), SchemaDesc: g("schema_description"), Schema: g("schema"), SchemaStrict: v.Get("schema_strict") != "",
		Bias:   g("logit_bias"),
		Harass: g("harassment"), Hate: g("hate_speech"), Sex: g("sexually_explicit"), Dang: g("dangerous_content"),
		Mime: g("response_mime_type"), RSchema: g("response_schema"), Cand: g("candidate_count"),
	}
	for _, s := range append(v["stop"], v.Get("stop_new")) {
		if s != "" {
			f.Stops = append(f.Stops, s)
		}
	}
	return f
}

func saBoolChoice(s string) *bool {
	switch s {
	case "on":
		t := true
		return &t
	case "off":
		f := false
		return &f
	}
	return nil
}

func saInRange[T int32 | float64](name string, p *T, lo, hi T) error {
	if p != nil && (*p < lo || *p > hi) {
		return fmt.Errorf("%s must be between %v and %v", name, lo, hi)
	}
	return nil
}

// toProto validates the form and builds CallSettings. Empty blocks stay nil
// so a cleared page stores nothing.
func (f csForm) toProto() (*psmithv1.CallSettings, error) {
	cs := &psmithv1.CallSettings{}
	var err error
	num := func(name, s string, lo, hi float64) *float64 {
		if err != nil {
			return nil
		}
		var p *float64
		if p, err = saParseFloat(s); err == nil {
			err = saInRange(name, p, lo, hi)
		}
		return p
	}
	whole := func(name, s string, lo, hi int32) *int32 {
		if err != nil {
			return nil
		}
		var p *int32
		if p, err = saParseInt(s); err == nil {
			err = saInRange(name, p, lo, hi)
		}
		return p
	}
	cs.Temperature = num("Temperature", f.Temp, 0, 2)
	cs.TopP = num("Top P", f.TopP, 0, 1)
	cs.MaxOutputTokens = whole("Max output tokens", f.MaxTok, 1, 1<<30)
	cs.TopK = whole("Top K", f.TopK, 1, 500)
	cs.StopSequences = f.Stops
	if e, ok := effortByName[f.Effort]; ok {
		cs.Thinking = &psmithv1.ThinkingSettings{Effort: e}
	}
	cs.ExplicitCache = saBoolChoice(f.Explicit)

	a := &psmithv1.AnthropicExtras{CacheEnabled: saBoolChoice(f.PCache)}
	switch f.TTL {
	case "5m":
		t := psmithv1.CacheTTL_CACHE_TTL_5M
		a.CacheTtl = &t
	case "1h":
		t := psmithv1.CacheTTL_CACHE_TTL_1H
		a.CacheTtl = &t
	}
	if a.CacheEnabled != nil || a.CacheTtl != nil {
		cs.Anthropic = a
	}

	o := &psmithv1.OpenAIExtras{ParallelToolCalls: saBoolChoice(f.PTC)}
	o.Seed = whole("Seed", f.Seed, -1_000_000, 1_000_000)
	o.FrequencyPenalty = num("Frequency penalty", f.Freq, -2, 2)
	o.PresencePenalty = num("Presence penalty", f.Pres, -2, 2)
	o.TopLogprobs = whole("Top logprobs", f.Logp, 0, 5)
	if t, ok := tierByName[f.Tier]; ok {
		o.ServiceTier = &t
	}
	switch f.RFmt {
	case "text":
		o.ResponseFormat = &psmithv1.ResponseFormat{Kind: &psmithv1.ResponseFormat_Text{Text: true}}
	case "json_object":
		o.ResponseFormat = &psmithv1.ResponseFormat{Kind: &psmithv1.ResponseFormat_JsonObject{JsonObject: true}}
	case "json_schema":
		js := &psmithv1.JsonSchema{Name: f.SchemaName, Schema: []byte(f.Schema)}
		if f.SchemaDesc != "" {
			js.Description = &f.SchemaDesc
		}
		if f.SchemaStrict {
			t := true
			js.Strict = &t
		}
		if err == nil && f.Schema != "" && !json.Valid([]byte(f.Schema)) {
			err = fmt.Errorf("the JSON schema isn't valid JSON")
		}
		o.ResponseFormat = &psmithv1.ResponseFormat{Kind: &psmithv1.ResponseFormat_JsonSchema{JsonSchema: js}}
	}
	if f.Bias != "" && err == nil {
		var m map[string]float64
		if jerr := json.Unmarshal([]byte(f.Bias), &m); jerr != nil {
			err = fmt.Errorf("logit bias must be a JSON object of token ID to bias")
		} else {
			o.LogitBias = map[int32]float64{}
			for k, b := range m {
				tok, perr := strconv.ParseInt(k, 10, 32)
				if perr != nil || b < -100 || b > 100 {
					err = fmt.Errorf("logit bias takes token IDs with biases from -100 to 100")
					break
				}
				o.LogitBias[int32(tok)] = b
			}
		}
	}
	if o.ParallelToolCalls != nil || o.Seed != nil || o.FrequencyPenalty != nil || o.PresencePenalty != nil ||
		o.TopLogprobs != nil || o.ServiceTier != nil || o.ResponseFormat != nil || len(o.LogitBias) > 0 {
		cs.Openai = o
	}

	harm := func(s string) *psmithv1.HarmThreshold {
		if t, ok := harmByName[s]; ok {
			return &t
		}
		return nil
	}
	gx := &psmithv1.GoogleExtras{}
	ss := &psmithv1.SafetySettings{Harassment: harm(f.Harass), HateSpeech: harm(f.Hate), SexuallyExplicit: harm(f.Sex), DangerousContent: harm(f.Dang)}
	if ss.Harassment != nil || ss.HateSpeech != nil || ss.SexuallyExplicit != nil || ss.DangerousContent != nil {
		gx.SafetySettings = ss
	}
	if f.Mime != "" {
		gx.ResponseMimeType = &f.Mime
	}
	if f.RSchema != "" {
		if err == nil && !json.Valid([]byte(f.RSchema)) {
			err = fmt.Errorf("the response schema isn't valid JSON")
		}
		gx.ResponseSchema = []byte(f.RSchema)
	}
	gx.CandidateCount = whole("Candidate count", f.Cand, 1, 8)
	if gx.SafetySettings != nil || gx.ResponseMimeType != nil || gx.ResponseSchema != nil || gx.CandidateCount != nil {
		cs.Google = gx
	}
	if err != nil {
		return nil, err
	}
	return cs, nil
}
