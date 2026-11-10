package web

import psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"

// Inspector board fixtures. Each starts from the Main conversation and
// changes what its board changes.

func inspList(live bool) listVM {
	l := boardList()
	rows := append([]rowVM(nil), l.Rows...)
	rows[0].Live = live
	l.Rows = rows
	return l
}

const (
	fxA1 = "The lazy stack is the cause. Rows above the viewport report estimated heights until they render, so when the finished reply swaps in, every offset above it shifts and the scroll position lands somewhere new.\n\nTwo changes fix it: render the transcript eagerly, then follow the stream and park when it ends."
	fxA2 = "Yes, the same mechanism. The card is taller once the summary lands, and it sits above the fold, so every offset above it shifts when it settles.\n\nThe same fix applies: render the card eagerly with its final height reserved, and park the scroll position when the summary finishes."
)

func fxItem(id, role, parent, text string) msgItem {
	return msgItem{ID: id, ConvID: "c-scroll", ParentID: parent, Role: role, Text: text, HTML: renderMarkdown(text)}
}

// settledTranscript is the boards' transcript once the second reply has
// finished; short drops the first exchange.
func settledTranscript(short bool) []msgItem {
	u1 := fxItem("u1", "user", "", "Why does the transcript jump when a long reply finishes?")
	a1 := fxItem("a1", "assistant", "u1", fxA1)
	a1.Thinking = &thinkVM{Label: "Thought for 6.2s"}
	a1.Tools = []toolVM{{Name: "search_docs", Summary: "LazyVStack estimated heights", Dur: "0.8s"}}
	u2 := fxItem("u2", "user", "a1", "And the compression summary card: same problem?")
	u2.Branch = &branchVM{Index: 2, Count: 3, PrevID: "u2a", NextID: "u2c"}
	a2 := fxItem("a2", "assistant", "u2", fxA2)
	a2.Usage = &usageVM{Model: "Opus 4.7", Tokens: "412 tokens", Cached: "96% cached", Cost: "$0.009"}
	if short {
		return []msgItem{u2, a2}
	}
	return []msgItem{u1, a1, u2, a2}
}

func settledConv() convVM {
	c := boardConv()
	c.RunID, c.Live, c.Draft, c.Pending = "", liveInit{}, "", nil
	return c
}

func fxCompressCard(kind string) *slotVM {
	s := &slotVM{Kind: kind, ConvID: "c-scroll", CtxLabel: "Context 2", NextLabel: "Context 3", Tokens: 82140, Turns: 18,
		Guide:     "Summarize the conversation so far for a fresh context. Keep decisions, open questions, names and numbers. Drop anything a later turn superseded.",
		GuideFrom: "From the Demo profile. Edits apply to this run only.",
		Selected:  "anthropic|claude-haiku-4-5",
		Fit:       fitOf(82140, 200000),
	}
	opt := func(v, l string, w int64) cmpOptVM { return cmpOptVM{Value: v, Label: l, Window: w} }
	s.Groups = []cmpGroupVM{
		{Label: "Favorites", Options: []cmpOptVM{opt("anthropic|claude-opus-4-7", "Claude Opus 4.7", 200000), opt("anthropic|claude-haiku-4-5", "Claude Haiku 4.5", 200000)}},
		{Label: "Anthropic", Options: []cmpOptVM{opt("anthropic|claude-opus-4-7", "Claude Opus 4.7", 200000), opt("anthropic|claude-sonnet-4-5", "Claude Sonnet 4.5", 200000), opt("anthropic|claude-haiku-4-5", "Claude Haiku 4.5", 200000)}},
		{Label: "OpenRouter", Options: []cmpOptVM{opt("or|gpt-5.1", "GPT-5.1", 400000), opt("or|gemini-3-flash", "Gemini 3 Flash", 1000000)}},
		{Label: "Ollama on nas.local", Options: []cmpOptVM{opt("ollama|qwen3:8b", "qwen3:8b", 40960)}},
	}
	sel := s.Selected
	if kind == "failed" {
		sel = "ollama|qwen3:8b"
		s.Selected = sel
		s.Fit = fitOf(82140, 40960)
		s.ModelMeta = "qwen3:8b · Ollama on nas.local"
		s.Error = "qwen3:8b can't fit this context. Context 2 is 82,140 tokens and its window holds 40,960."
		s.ErrorHint = "Context 2 is unchanged. Choose a model with a larger window, then retry."
	}
	for i := range s.Groups {
		if s.Groups[i].Label == "Favorites" {
			if kind != "failed" {
				s.Groups[i].Options[1].Selected = true
			}
			continue
		}
		for j := range s.Groups[i].Options {
			s.Groups[i].Options[j].Selected = kind == "failed" && s.Groups[i].Options[j].Value == sel
		}
	}
	return s
}

const fxSummary = "**Topic.** Why the transcript jumps when a long reply finishes, and whether the compression summary card has the same problem.\n\n**Decided**\n\n- Render the transcript eagerly. Estimated heights with correction passes were rejected because every correction moves the reader.\n- Follow the stream while a reply runs, then park when it ends.\n- Reserve the summary card's final height so it settles without shifting the rows above it.\n\n**Open**\n\n- Paging older history above the last 200 rows. Jamie wants numbers for 500 and 2,000 messages before choosing.\n- Paging by date as the alternative, measured against the same two sizes.\n- Ask Jamie whether 2,000 is a realistic ceiling."

const fxSummaryEdit = "## Topic\nWhy the transcript jumps when a long reply finishes, and whether the compression summary card has the same problem.\n\n## Decided\n- Render the transcript eagerly. Estimated heights with correction passes were rejected because every correction moves the reader.\n- Follow the stream while a reply runs, then park when it ends.\n- Reserve the summary card's final height so it settles without shifting the rows above it.\n\n## Open\n- Paging older history above the last 200 rows. Jamie wants numbers for 500 and 2,000 messages before choosing.\n- Paging by date as the alternative, measured against the same two sizes.\n- Ask Jamie whether 2,000 is a realistic ceiling."

func boardCompress(kind string) convVM {
	c := settledConv()
	c.Items = settledTranscript(kind == "compacting" || kind == "review" || kind == "edit")
	card := fxCompressCard(kind)
	switch kind {
	case "compress", "failed":
		c.Inspector.Compress = "open"
	case "compacting":
		card.RunID, card.ModelName = "run-c", "Claude Haiku 4.5"
		card.SummaryHTML = "<p><strong>Topic.</strong> Why the transcript jumps when a long reply finishes, and whether the compression summary card has the same problem.</p>\n<p><strong>Decided</strong></p>\n<ul><li>Render the transcript eagerly. Estimated heights with correction passes were rejected because every correction moves the reader.</li><li>Follow the stream while a reply runs, then park when it ends.</li><li>Reserve the summary card's final height so it settles without shifting the rows above it.</li></ul>\n<p><strong>Open</strong></p>\n<ul><li>Paging older history above the last 200 rows. Jamie wants numbers for 500 and<span class=\"caret\"></span></li></ul>"
		c.Inspector.Compress = "running"
	case "review", "edit":
		card.MessageID, card.ModelName = "sum-1", "Claude Haiku 4.5"
		card.SummaryHTML, card.SummaryText = renderMarkdown(fxSummary), fxSummaryEdit
		card.Usage = "In 82,140 (64,900 cached) · out 1,684 · $0.0321"
		c.Inspector.Compress = "review"
	}
	c.Inspector.Card = card
	return c
}

func boardInspSettings() convVM {
	c := boardConv()
	c.Inspector.Tab = "settings"
	f := func(v float64) *float64 { return &v }
	i := func(v int32) *int32 { return &v }
	b := func(v bool) *bool { return &v }
	own := &psmithv1.CallSettings{Temperature: f(0.7)}
	layers := []layer{
		{"From the Demo profile", &psmithv1.CallSettings{Temperature: f(1), TopP: f(0.95), Thinking: &psmithv1.ThinkingSettings{Effort: psmithv1.ThinkingEffort_THINKING_EFFORT_MEDIUM}}},
		{"From Claude Opus 4.7", &psmithv1.CallSettings{MaxOutputTokens: i(16384), ExplicitCache: b(false)}},
		{"From the Anthropic provider", &psmithv1.CallSettings{StopSequences: []string{"</answer>", "STOP"}, Anthropic: &psmithv1.AnthropicExtras{CacheEnabled: b(true)}}},
	}
	rows, extras, _ := buildSetRows(own, layers, nil, &psmithv1.ProfileDefaults{IncludeThinkingInHistory: b(true)}, "Demo", "anthropic")
	for k := range rows {
		if rows[k].Name == "thinking_effort" {
			rows[k].Value, rows[k].Dirty = "high", true
		}
	}
	c.Inspector.Settings = &callSettingsVM{ConvID: c.ID, ModelName: "Claude Opus 4.7", ModelSub: "Anthropic · from the Demo profile",
		Intro: "Empty fields inherit from the Demo profile, then the model, then the provider. A dot marks a value set here.",
		Rows:  rows, ProviderRows: extras, ProviderTitle: "Anthropic", ProviderNote: "Applies while this conversation runs on Anthropic.", Dirty: 1}
	return c
}

func boardInspPlugins() convVM {
	c := boardConv()
	c.Inspector.Tab = "plugins"
	c.Inspector.Plugins = &pluginsTabVM{ConvID: c.ID, Profile: "Demo", Dirty: 1, Overrides: 2, Rows: []plugRowVM{
		{N: 1, Name: "basic_grounding", Display: "Basic grounding", Kind: "inherited"},
		{N: 2, Name: "memory", Display: "Memory", Kind: "inherited"},
		{N: 3, Name: "mcp", Display: "MCP tools", Kind: "inherited"},
		{N: 4, Name: "context_packs", Display: "Context packs", Kind: "inherited", Panel: true},
		{N: 5, Name: "lettered_choices", Display: "Lettered choices", Kind: "off"},
		{N: 6, Name: "brave_search", Display: "Brave search", Kind: "conversation", Configure: true},
	}, Addable: []plugOptVM{{Name: "imagegen", Display: "Image generation"}}}
	return c
}

func boardPickerData() pickerData {
	caps3 := capsVM{Vision: true, ToolUse: true, Thinking: true}
	m := func(pid, id, name, ctx, cost string, caps capsVM, fav bool) pickerModelVM {
		return pickerModelVM{ProviderID: pid, ModelID: id, Value: pid + "|" + id, DisplayName: name, ContextLabel: ctx, CostBucket: cost, Caps: caps, Favorite: fav}
	}
	opus := m("anthropic", "claude-opus-4-7", "Claude Opus 4.7", "200k", "$$$", caps3, true)
	opus.Selected = true
	gemma := m("ollama", "gemma3:12b", "gemma3:12b", "128k", "", capsVM{Vision: true}, false)
	gemma.Disabled, gemma.Missing = true, []string{"tool use"}
	return pickerData{ConvID: "c-scroll", Groups: []providerGroupVM{
		{ProviderID: "anthropic", Label: "Anthropic", Models: []pickerModelVM{opus,
			m("anthropic", "claude-sonnet-4-5", "Claude Sonnet 4.5", "200k", "$$", caps3, false),
			m("anthropic", "claude-haiku-4-5", "Claude Haiku 4.5", "200k", "$", capsVM{Vision: true, ToolUse: true}, true)}},
		{ProviderID: "or", Label: "OpenRouter", Models: []pickerModelVM{
			m("or", "gpt-5.1", "GPT-5.1", "400k", "$$", caps3, false),
			m("or", "gemini-3-flash", "Gemini 3 Flash", "1M", "$", caps3, false)}},
		{ProviderID: "ollama", Label: "Ollama on nas.local", Models: []pickerModelVM{
			m("ollama", "qwen3:8b", "qwen3:8b", "40k", "", capsVM{ToolUse: true, Thinking: true}, false), gemma}},
	}}
}

func boardInspModel() convVM {
	c := boardConv()
	c.Inspector.View = "model"
	p := buildPicker(boardPickerData(), "", capsVM{ToolUse: true}, "Demo")
	p.ProfileModel = "Demo uses Claude Opus 4.7"
	c.Inspector.Picker = p
	return c
}

func boardInspContexts() convVM {
	c := boardConv()
	c.CtxLabel = "Context 3 of 3"
	c.Items[0].Strip = "Context 3 · started from a summary of 22 turns"
	c.Inspector.View = "contexts"
	c.Inspector.Rename, c.Inspector.Confirm = "x3", "x1"
	c.Inspector.Contexts = []ctxRowVM{
		{N: 1, ID: "x1", Label: "Context 1", Title: "Context 1", Turns: 46, Summary: "Context 1 · 46 turns · compressed Oct 30 · $1.92"},
		{N: 2, ID: "x2", Label: "Context 2", Title: "Compression card height", Turns: 22, Summary: "Context 2 · 22 turns · compressed Nov 4 · $0.71"},
		{N: 3, ID: "x3", Label: "Context 3", Title: "Paging by date", Active: true, Turns: 18, Summary: "Context 3 · active · 18 turns"},
	}
	return c
}

func boardContextView() (listVM, convVM, ctxViewVM) {
	c := settledConv()
	c.Inspector.Contexts = []ctxRowVM{
		{ID: "x2", Label: "Context 2", Detail: "From a summary · 18 turns · 82k", Active: true},
		{ID: "x1", Label: "Context 1", Detail: "46 turns · compressed Oct 30 · $1.92", Viewing: true},
	}
	c.Inspector.Card = &slotVM{Kind: "readonly", ConvID: c.ID, ContextID: "x1", CtxLabel: "Context 1", ActiveLabel: "Context 2"}
	v := ctxViewVM{ID: "x1", Label: "Context 1", ActiveLabel: "Context 2", Range: "Context 1 · Oct 22 to Oct 30 · 46 turns",
		Tokens: 151200, Window: 200000, Percent: 76, Warn: 75000, WarnPct: 37.5, Cost: "$1.9204", Turns: 46, Cache: "91% hit", Changes: 0,
		Items: []ctxItemVM{
			{Role: "user", HTML: renderMarkdown("Can we keep the lazy stack and correct the estimates after layout?")},
			{Role: "assistant", HTML: renderMarkdown("We could, but every correction moves the reader. Each pass lands after the row renders, so the offset changes under their thumb at the moment they are reading.\n\nEager rendering costs a little memory and removes the problem.")},
			{Role: "user", HTML: renderMarkdown("Write it up as a decision record.")},
			{Role: "assistant", HTML: renderMarkdown("Decision: render the transcript eagerly and follow, then park. Rejected: estimated heights with correction passes, because every correction moves the reader.")},
			{Role: "summary", Model: "Claude Haiku 4.5", Started: "started Context 2", HTML: renderMarkdown("Topic: why the transcript jumps when a long reply finishes. Decided: render eagerly, follow the stream, park when it ends. Open: paging above the last 200 rows.")},
		}}
	return inspList(false), c, v
}

func boardPluginPanel() convVM {
	c := boardConv()
	c.Inspector.Tab, c.Inspector.View = "plugins", "panel"
	c.Inspector.Panel = &panelVM{ConvID: c.ID, Plugin: "context_packs", Title: "Context packs", Subtitle: "Deliver background the model does not have yet",
		Parts: []panelPartVM{{Kind: "cards", Cards: []panelCardVM{
			{Title: "Swift style guide", Description: "House rules for SwiftUI views, naming and tests.", Badges: []string{"Sends next"}, Action: "disarm", Params: map[string]string{"id": "swift"}, Chosen: true},
			{Title: "Jamie's review checklist", Description: "What Jamie checks before approving a UI change.", Action: "arm", Params: map[string]string{"id": "jamie"}},
			{Title: "Release calendar", Description: "Dates for the next three TestFlight builds.", Action: "arm", Params: map[string]string{"id": "release"}},
			{Title: "Scroll architecture notes", Description: "The eager-render decision record and the measurements behind it.", Badges: []string{"Delivered"}},
		}}}}
	return c
}

func boardInspInfo() convVM {
	c := boardConv()
	c.Inspector.View = "info"
	c.Inspector.Info = &infoVM{ConvID: c.ID, Title: "Scroll architecture review", ProfileID: fxDemo, Profile: "Demo", Color: 2,
		Model: "Claude Opus 4.7", ModelSub: "Anthropic · from the profile", Created: "Oct 22, 2026, 4:12 PM", Last: "Today, 10:42 AM",
		Contexts: "2 · 64 turns", Cost: "$2.34", Confirm: true, DeleteNote: "Both contexts and all 64 turns are deleted for good. Archive keeps them instead."}
	return c
}

func boardArchived() (listVM, convVM) {
	l := boardList()
	l.Filter, l.Chips = "archived", boardChips("archived")
	l.Rows = []rowVM{
		{ID: "c-scroll", Title: "Scroll architecture review", Time: "Oct 28", Group: "October", Profile: "Demo", Color: 2, Active: true},
		{ID: "c-lis", Title: "Conference travel, Lisbon", Time: "Oct 21", Profile: "Chief of staff", Color: 1},
		{ID: "c-move", Title: "Council: office move", Time: "Sep 30", Group: "September", Profile: "Council", Color: 4},
		{ID: "c-knots", Title: "Knots and tides", Time: "Sep 12", Profile: "Pirate tutor", Color: 3},
	}
	c := settledConv()
	c.Items = settledTranscript(false)
	c.Slot, c.CtxLabel, c.ShowInsp = "archived", "Archived Oct 28", false
	c.Inspector.Card = &slotVM{Kind: "archived", ConvID: c.ID, Archived: "Archived Oct 28"}
	return l, c
}

func boardElicit() convVM {
	c := settledConv()
	u1 := fxItem("u1", "user", "", "Why does the transcript jump when a long reply finishes?")
	a1 := fxItem("a1", "assistant", "u1", fxA1)
	a1.Thinking = &thinkVM{Label: "Thought for 6.2s"}
	a1.Tools = []toolVM{{Name: "search_docs", Summary: "LazyVStack estimated heights", Dur: "0.8s"}}
	c.Items = []msgItem{u1, a1, fxItem("u3", "user", "a1", "File the jump on finish as an issue in the iOS repo, with the repro steps.")}
	c.RunID = "run-e"
	c.Live = liveInit{Chips: []liveChipVM{{Name: "create_issue", Label: "GitHub · waiting for you", Live: true}},
		HTML: "<p>I'll file it in jdpedrie/psmith-ios with the steps from the top of this thread and a link back here.</p>"}
	c.Inspector.Card = &slotVM{Kind: "elicit", ConvID: c.ID, Elicit: &elicitVM{ID: "el-1", Tool: "create_issue",
		Message: "create_issue needs a personal access token with repo scope to file issues in jdpedrie/psmith-ios.",
		Fields: []elicitField{
			{Name: "owner", Label: "Repository owner", Type: "text", Default: "jdpedrie"},
			{Name: "remember", Label: "Remember for this session", Type: "checkbox"},
			{Name: "token", Label: "Personal access token", Type: "password", Required: true, Default: "github-pat-placeholder-value"},
		}}}
	return c
}

func boardPhoneInspector() convVM {
	c := boardConv()
	c.Inspector.Page = true
	return c
}

func boardPhoneCompress() convVM {
	c := boardCompress("compress")
	c.CtxLabel = "Context 2"
	c.Items = []msgItem{settledTranscript(true)[0], settledTranscript(true)[1]}
	c.Items[1].Text = "Yes, the same mechanism. The card is taller once the summary lands, so reserve its final height and park when it settles."
	c.Items[1].HTML = renderMarkdown(c.Items[1].Text)
	c.Items[0].Branch = nil
	return c
}
