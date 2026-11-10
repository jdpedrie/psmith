package web

import (
	"context"
	"strconv"
	"strings"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/protoconv"
)

// callSettingsVM is the inspector's Settings tab: the conversation's model
// and every call setting, each with the value it would inherit and the
// layer that value comes from.
type callSettingsVM struct {
	ConvID    string
	ModelName string
	ModelSub  string // "Anthropic · from the Demo profile"
	Intro     string
	Rows      []setRowVM
	// The active provider's extras.
	ProviderTitle string
	ProviderNote  string
	ProviderRows  []setRowVM
	Harness       *harnessVM
	Dirty         int // unsaved changes the page opens with (fixtures)
}

// setRowVM is one setting.
type setRowVM struct {
	Name        string // form field
	Label       string
	Kind        string // "input" or "select"
	Wide        bool   // 124px control instead of 84px
	Value       string // the conversation's own value; "" inherits
	Placeholder string
	Options     []enumOption // selects: the first is Inherit, value ""
	From        string       // where the inherited value comes from
	Inherits    string       // the inherited value, as shown
	Dirty       bool
	// Locked says why the model fixes this setting ("Locked at 1.0 by
	// GPT-5"); the row shows the fixed value and can't be edited.
	Locked string
}

// Set reports whether the conversation sets this field itself.
func (r setRowVM) Set() bool { return r.Value != "" }

// Sub is the line under the label.
func (r setRowVM) Sub() string {
	if r.Locked != "" {
		return r.Locked
	}
	if !r.Set() && !r.Dirty {
		return r.From
	}
	s := "Set here"
	if r.Dirty {
		s += ", unsaved"
	}
	if r.Inherits != "" {
		return s + ". Inherits " + r.Inherits
	}
	return s
}

// layer is one level below the conversation, highest precedence first.
type layer struct {
	from string // "From the Demo profile"
	cs   *psmithv1.CallSettings
}

// pick finds the highest layer that sets a field.
func pick(layers []layer, get func(*psmithv1.CallSettings) (string, bool)) (val, from string) {
	for _, l := range layers {
		if l.cs == nil {
			continue
		}
		if v, ok := get(l.cs); ok {
			return v, l.from
		}
	}
	return "", "Not set at any layer"
}

// callSettings builds the Settings tab for a conversation.
func (h *Handler) callSettings(ctx context.Context, conv *psmithv1.Conversation, model modelChipVM) *callSettingsVM {
	profName := h.profileName(ctx, conv.GetProfileId())
	prof := h.resolvedProfile(ctx, conv.GetProfileId())
	vm := &callSettingsVM{ConvID: conv.GetId(), Harness: harnessVMFrom(conv.GetHarness())}
	vm.ModelName, vm.ModelSub = model.Name, model.Provider
	if currentSettingsModel(conv) == "" {
		vm.ModelSub = joinDot(model.Provider, "from the "+profName+" profile")
	} else {
		vm.ModelSub = joinDot(model.Provider, "set here")
	}
	vm.Intro = "Empty fields inherit from the " + profName + " profile, then the model, then the provider. A dot marks a value set here."

	var provCS, modelCS *psmithv1.CallSettings
	var provLabel, provType string
	var limits *psmithv1.ModelConstraints
	if pid, mid, ok := splitModelValue(model.Value); ok {
		if e := h.findModel(ctx, pid, mid); e != nil {
			limits = e.GetModel().GetConstraints()
			provCS, modelCS = e.GetProvider().GetDefaultSettings(), e.GetModel().GetDefaultSettings()
			provLabel = orName(e.GetProvider().GetLabel(), e.GetProvider().GetType())
			provType = e.GetProvider().GetType()
		}
	}
	layers := []layer{
		{"From the " + profName + " profile", prof.GetDefaultSettings().GetCallSettings()},
		{"From " + model.Name, modelCS},
		{"From the " + provLabel + " provider", provCS},
	}
	own := conv.GetSettings().GetCallSettings()
	vm.Rows, vm.ProviderRows, vm.ProviderTitle = buildSetRows(own, layers, conv.GetSettings(), prof.GetDefaultSettings(), profName, provType)
	lockRows(vm.Rows, limits, model.Name)
	lockRows(vm.ProviderRows, limits, model.Name)
	if vm.ProviderTitle != "" {
		vm.ProviderTitle = provLabel
		vm.ProviderNote = "Applies while this conversation runs on " + provLabel + "."
	}
	return vm
}

func joinDot(a, b string) string {
	if a == "" {
		return b
	}
	return a + " · " + b
}

// buildSetRows lays out the rows. It is separate from the RPC reads so the
// provenance rules test without a database.
func buildSetRows(own *psmithv1.CallSettings, layers []layer, ownConv *psmithv1.ConversationSettings, profDefaults *psmithv1.ProfileDefaults, profName, driver string) (rows, extras []setRowVM, extrasTitle string) {
	num := func(name, label string, get func(*psmithv1.CallSettings) (string, bool), shown func(string) string, empty string) setRowVM {
		r := setRowVM{Name: name, Label: label, Kind: "input"}
		if own != nil {
			if v, ok := get(own); ok {
				r.Value = v
			}
		}
		inh, from := pick(layers, get)
		r.From = from
		if inh != "" {
			r.Inherits = shown(inh)
			r.Placeholder = r.Inherits
		} else {
			r.Placeholder = empty
		}
		return r
	}
	sel := func(name, label string, get func(*psmithv1.CallSettings) (string, bool), opts []enumOption, deflt string) setRowVM {
		r := setRowVM{Name: name, Label: label, Kind: "select", Wide: true}
		if own != nil {
			if v, ok := get(own); ok {
				r.Value = v
			}
		}
		inh, from := pick(layers, get)
		r.From = from
		shown := optLabel(opts, inh)
		if shown == "" {
			shown = deflt
		}
		r.Inherits = strings.ToLower(shown)
		inherit := "Inherit"
		if shown != "" {
			inherit += " (" + r.Inherits + ")"
		}
		r.Options = append([]enumOption{{Value: "", Label: inherit}}, opts...)
		if inh == "" {
			r.Inherits = ""
		}
		return r
	}
	f64 := func(p *float64) (string, bool) {
		if p == nil {
			return "", false
		}
		return strconv.FormatFloat(*p, 'f', -1, 64), true
	}
	i32 := func(p *int32) (string, bool) {
		if p == nil {
			return "", false
		}
		return strconv.Itoa(int(*p)), true
	}
	tri := func(p *bool) (string, bool) {
		if p == nil {
			return "", false
		}
		return boolWord(*p), true
	}
	onOff := []enumOption{{Value: "on", Label: "On"}, {Value: "off", Label: "Off"}}

	rows = append(rows,
		num("temperature", "Temperature", func(c *psmithv1.CallSettings) (string, bool) { return f64(c.Temperature) }, oneDecimal, "Default"),
		num("top_p", "Top P", func(c *psmithv1.CallSettings) (string, bool) { return f64(c.TopP) }, oneDecimal, "Default"),
		num("max_output_tokens", "Max output tokens", func(c *psmithv1.CallSettings) (string, bool) { return i32(c.MaxOutputTokens) }, commaInt, "Default"),
		num("top_k", "Top K", func(c *psmithv1.CallSettings) (string, bool) { return i32(c.TopK) }, same, "Default"),
	)
	stop := num("stop_sequences", "Stop sequences", func(c *psmithv1.CallSettings) (string, bool) {
		if len(c.GetStopSequences()) == 0 {
			return "", false
		}
		return strings.Join(c.GetStopSequences(), ", "), true
	}, func(s string) string { return strconv.Itoa(len(splitStops(s))) + " inherited" }, "None")
	stop.Wide = true
	if stop.Inherits != "" {
		stop.Inherits = stop.Placeholder
	}
	rows = append(rows, stop,
		sel("thinking_effort", "Thinking effort", func(c *psmithv1.CallSettings) (string, bool) {
			w := string(protoconv.ThinkingEffort(c.GetThinking().GetEffort()))
			return w, w != ""
		}, thinkingEffortOptions, ""),
		sel("explicit_cache", "Explicit caching", func(c *psmithv1.CallSettings) (string, bool) { return tri(c.ExplicitCache) }, onOff, "Off"),
	)

	// Thinking in history lives on the conversation and profile settings,
	// not in the call settings.
	hist := setRowVM{Name: "include_thinking_in_history", Label: "Thinking in history", Kind: "select", Wide: true, From: "Not set at any layer"}
	if ownConv != nil && ownConv.IncludeThinkingInHistory != nil {
		hist.Value = boolWord(*ownConv.IncludeThinkingInHistory)
	}
	inh := "off"
	if profDefaults != nil && profDefaults.IncludeThinkingInHistory != nil {
		inh, hist.From = boolWord(*profDefaults.IncludeThinkingInHistory), "From the "+profName+" profile"
		hist.Inherits = inh
	}
	hist.Options = append([]enumOption{{Value: "", Label: "Inherit (" + inh + ")"}}, onOff...)
	rows = append(rows, hist)

	switch driver {
	case "anthropic":
		extrasTitle = "anthropic"
		extras = append(extras,
			sel("anth_cache_enabled", "Prompt caching", func(c *psmithv1.CallSettings) (string, bool) {
				if c.GetAnthropic() == nil {
					return "", false
				}
				return tri(c.GetAnthropic().CacheEnabled)
			}, onOff, "On"),
			sel("anth_cache_ttl", "Cache lifetime", func(c *psmithv1.CallSettings) (string, bool) {
				switch c.GetAnthropic().GetCacheTtl() {
				case psmithv1.CacheTTL_CACHE_TTL_5M:
					return "5m", true
				case psmithv1.CacheTTL_CACHE_TTL_1H:
					return "1h", true
				}
				return "", false
			}, []enumOption{{Value: "5m", Label: "5 min"}, {Value: "1h", Label: "1 hour"}}, "5 min"),
		)
	case "openai", "openrouter":
		extrasTitle = "openai"
		seed := num("oai_seed", "Seed", func(c *psmithv1.CallSettings) (string, bool) {
			if c.GetOpenai() == nil {
				return "", false
			}
			return i32(c.GetOpenai().Seed)
		}, same, "Random")
		freq := num("oai_frequency_penalty", "Frequency penalty", func(c *psmithv1.CallSettings) (string, bool) {
			if c.GetOpenai() == nil {
				return "", false
			}
			return f64(c.GetOpenai().FrequencyPenalty)
		}, oneDecimal, "Default")
		pres := num("oai_presence_penalty", "Presence penalty", func(c *psmithv1.CallSettings) (string, bool) {
			if c.GetOpenai() == nil {
				return "", false
			}
			return f64(c.GetOpenai().PresencePenalty)
		}, oneDecimal, "Default")
		par := sel("oai_parallel_tool_calls", "Parallel tool calls", func(c *psmithv1.CallSettings) (string, bool) {
			if c.GetOpenai() == nil {
				return "", false
			}
			return tri(c.GetOpenai().ParallelToolCalls)
		}, onOff, "On")
		extras = append(extras, seed, freq, pres, par)
	case "google":
		extrasTitle = "google"
		extras = append(extras, num("goog_candidate_count", "Candidates", func(c *psmithv1.CallSettings) (string, bool) {
			if c.GetGoogle() == nil {
				return "", false
			}
			return i32(c.GetGoogle().CandidateCount)
		}, same, "1"))
	}
	return rows, extras, extrasTitle
}

func optLabel(opts []enumOption, v string) string {
	for _, o := range opts {
		if o.Value == v {
			return o.Label
		}
	}
	return ""
}

func same(s string) string { return s }

// oneDecimal shows a whole number as "1.0", the way the boards write
// sampling values.
func oneDecimal(s string) string {
	if !strings.Contains(s, ".") {
		return s + ".0"
	}
	return s
}

func commaInt(s string) string {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return s
	}
	return commas(n)
}

// constraintRows maps the dotted CallSettings paths a model's constraints
// name to the rows that edit them.
var constraintRows = map[string]string{
	"temperature":                "temperature",
	"top_p":                      "top_p",
	"max_output_tokens":          "max_output_tokens",
	"stop_sequences":             "stop_sequences",
	"top_k":                      "top_k",
	"thinking":                   "thinking_effort",
	"explicit_cache":             "explicit_cache",
	"anthropic.cache_enabled":    "anth_cache_enabled",
	"anthropic.cache_ttl":        "anth_cache_ttl",
	"openai.seed":                "oai_seed",
	"openai.frequency_penalty":   "oai_frequency_penalty",
	"openai.presence_penalty":    "oai_presence_penalty",
	"openai.parallel_tool_calls": "oai_parallel_tool_calls",
	"google.candidate_count":     "goog_candidate_count",
}

// lockRows draws what the model fixes as fixed: a temperature it locks
// shows that value, a setting it rejects shows that it isn't supported.
// Neither posts, so a save clears any value the conversation held.
func lockRows(rows []setRowVM, c *psmithv1.ModelConstraints, model string) {
	if c == nil {
		return
	}
	unsupported := map[string]bool{}
	for _, p := range c.GetUnsupported() {
		if name, ok := constraintRows[p]; ok {
			unsupported[name] = true
		}
	}
	for i := range rows {
		r := &rows[i]
		switch {
		case unsupported[r.Name]:
			r.Locked, r.Value, r.Placeholder, r.Dirty = "Not supported by "+model, "", "Off", false
		case r.Name == "temperature" && c.GetTemperature().LockedAt != nil:
			v := oneDecimal(strconv.FormatFloat(c.GetTemperature().GetLockedAt(), 'f', -1, 64))
			r.Locked, r.Value, r.Dirty = "Locked at "+v+" by "+model, v, false
		}
	}
}
