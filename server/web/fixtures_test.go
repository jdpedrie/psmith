package web

// Board fixtures: the content each board on the "Psmith web design" canvas
// draws, as view models. The probe renders templates with these so the
// output lines up with the board renders. Profile ids are picked so the
// FNV hash lands each profile on its board color: Chief of staff 1, Demo 2,
// Pirate tutor 3, Council 4.

const (
	fxChief   = "prof-chief-3"
	fxDemo    = "prof-demo-4"
	fxPirate  = "prof-pirate-3"
	fxCouncil = "prof-council-0"
)

func boardChips(filter string) []chipVM {
	return []chipVM{
		{Label: "All", Href: "/chats", On: filter == "all"},
		{Label: "Archived", Href: "/chats?f=archived", On: filter == "archived"},
		{Label: "Chief of staff", Href: "/chats?f=" + fxChief, Color: 1, On: filter == fxChief},
		{Label: "Demo", Href: "/chats?f=" + fxDemo, Color: 2, On: filter == fxDemo},
		{Label: "Pirate tutor", Href: "/chats?f=" + fxPirate, Color: 3, On: filter == fxPirate},
		{Label: "Council", Href: "/chats?f=" + fxCouncil, Color: 4, On: filter == fxCouncil},
	}
}

func boardRows() []rowVM {
	return []rowVM{
		{ID: "c-scroll", Title: "Scroll architecture review", Time: "10:42", Group: "Today", Profile: "Demo", Color: 2, Active: true, Live: true},
		{ID: "c-tax", Title: "Tax documents checklist", Time: "9:15", Profile: "Chief of staff", Color: 1, Draft: "Add the 1099-B from the brokerage"},
		{ID: "c-council", Title: "Council: pricing debate", Time: "8:03", Profile: "Council", Color: 4},
		{ID: "c-ada", Title: "Fractions with Captain Ada", Time: "Thu", Group: "Yesterday", Profile: "Pirate tutor", Color: 3},
		{ID: "c-md", Title: "Markdown showcase", Time: "Thu", Profile: "Demo", Color: 2},
		{ID: "c-q4", Title: "Q4 offsite agenda", Time: "Nov 3", Group: "Previous 7 days", Profile: "Chief of staff", Color: 1},
		{ID: "c-tour", Title: "Architecture tour", Time: "Oct 31", Profile: "Demo", Color: 2},
		{ID: "c-hire", Title: "Hiring loop for the platform role", Time: "Oct 30", Profile: "Chief of staff", Color: 1},
	}
}

func boardList() listVM {
	return listVM{Rows: boardRows(), Filter: "all", Sort: "used", ActiveID: "c-scroll", Chips: boardChips("all"),
		UserName: "John", Initial: "J", Server: "psmith.home", IsAdmin: true}
}

func boardConv() convVM {
	reply := "The lazy stack is the cause. Rows above the viewport report estimated heights until they render, so when the finished reply swaps in, every offset above it shifts and the scroll position lands somewhere new.\n\nTwo changes fix it: render the transcript eagerly, then follow the stream and park when it ends.\n\n```swift\nif streamActive, !model.isStreaming {\n    endStream(proxy)   // park before any pin\n}\n```"
	return convVM{
		ID: "c-scroll", Title: "Scroll architecture review", Profile: "Demo", Color: 2, CtxLabel: "Context 2 of 2",
		Model:       modelChipVM{Value: "anthropic|claude-opus-4-7", Name: "Claude Opus 4.7", Provider: "Anthropic"},
		Gauge:       gaugeVM{Tokens: 82140, Window: 200000, Warn: 75000, Label: "82k", State: "warn", Percent: 41, WarnPct: 37.5},
		Placeholder: "Message Demo",
		Draft:       "Then compare it with paging by date",
		Pending:     []attachVM{{ID: "f1", Name: "trace.png", Size: "112 KB", URL: "#"}},
		RunID:       "run-1",
		Live: liveInit{
			Chips: []liveChipVM{{Name: "grep", Label: "CompressionSummaryCard · running", Live: true}},
			HTML:  "<p>Yes, the same mechanism. The card is taller once the summary lands, and it sits above the fold<span class=\"caret\"></span></p>",
		},
		Items: []msgItem{
			{Role: "strip", Strip: "Context 2 · started from a summary of 46 turns", StripLink: "#"},
			{ID: "u1", ConvID: "c-scroll", Role: "user", Text: "Why does the transcript jump when a long reply finishes?", HTML: renderMarkdown("Why does the transcript jump when a long reply finishes?")},
			{ID: "a1", ConvID: "c-scroll", ParentID: "u1", Role: "assistant", Text: reply, HTML: renderMarkdown(reply),
				Thinking: &thinkVM{Label: "Thought for 6.2s"},
				Tools:    []toolVM{{Name: "search_docs", Summary: "LazyVStack estimated heights", Dur: "0.8s"}},
				Usage:    &usageVM{Model: "Opus 4.7", Tokens: "1,284 tokens", Cached: "94% cached", Cost: "$0.021"}},
			{ID: "u2", ConvID: "c-scroll", ParentID: "a1", Role: "user", Text: "And the compression summary card: same problem?", HTML: renderMarkdown("And the compression summary card: same problem?"),
				Branch: &branchVM{Index: 2, Count: 3, PrevID: "u2a", NextID: "u2c"}},
		},
		ShowInsp: true,
		Inspector: inspVM{Tab: "context", Cost: "$0.4183", Turns: 18, Cache: "94% hit", Changes: 1, Contexts: []ctxRowVM{
			{ID: "x2", Label: "Context 2", Detail: "From a summary · 18 turns · 82k", Active: true},
			{ID: "x1", Label: "Context 1", Detail: "46 turns · compressed Oct 30 · $1.92"},
		}},
	}
}

func boardSettingsNav(active string) snavVM {
	return snavVM{Active: active, UsageTotal: "$41.20", Providers: 3, Profiles: 4, ServersBad: 1, Users: 3, IsAdmin: true,
		UserName: "John", Initial: "J", Server: "psmith.home"}
}

func boardProvider() providerPageVM {
	caps3 := []string{"Vision", "Tools", "Thinking"}
	return providerPageVM{
		ID: "anthropic", Name: "Anthropic", KeyMasked: "sk-ant-••••••••••••4f2a",
		Test: &testVM{OK: true, Message: "Connected in 312 ms, just now"},
		Models: []providerModelVM{
			{Name: "Claude Opus 4.7", ID: "claude-opus-4-7", Context: "200k", Cost: "$$$", Caps: caps3, On: true},
			{Name: "Claude Sonnet 4.5", ID: "claude-sonnet-4-5", Context: "200k", Cost: "$$", Caps: caps3, On: true},
			{Name: "Claude Haiku 4.5", ID: "claude-haiku-4-5", Context: "200k", Cost: "$", Caps: []string{"Vision", "Tools"}, On: true},
		},
		NewCount: 3, MaxTokens: "16,384", MaxChanged: "8,192", Caching: true, Dirty: 1,
	}
}
