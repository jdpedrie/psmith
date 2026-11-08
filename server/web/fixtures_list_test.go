package web

// Board fixtures for the list area: the list column's states, the start
// page, the draft, the shortcuts panel, command results, sign in and setup.

func boardPinnedRows() []rowVM {
	return []rowVM{
		{ID: "c-week", Title: "Weekly planning", Time: "Mon", Group: "Pinned", Profile: "Chief of staff", Color: 1, Pinned: true},
		{ID: "c-notes", Title: "Psmith release notes", Time: "Oct 28", Profile: "Demo", Color: 2, Pinned: true},
	}
}

func boardListWith(f func(*listVM)) listVM {
	l := boardList()
	f(&l)
	return l
}

// boardListIdle is the list with nothing open.
func boardListIdle() listVM {
	return boardListWith(func(l *listVM) {
		l.ActiveID = ""
		for i := range l.Rows {
			l.Rows[i].Active = false
		}
	})
}

func boardCards() []profileCardVM {
	return []profileCardVM{
		{ID: fxDemo, Name: "Demo", Color: 2, Desc: "Shows off tools and fragments. Good for testing a new model.", Model: "Claude Opus 4.7 · Anthropic", ModelValue: "anthropic|claude-opus-4-7"},
		{ID: fxChief, Name: "Chief of staff", Color: 1, Desc: "Planning, follow-ups and the weekly memo. Terse and direct.", Model: "Claude Sonnet 4.5 · Anthropic", ModelValue: "anthropic|claude-sonnet-4-5", Default: true},
		{ID: fxPirate, Name: "Pirate tutor", Color: 3, Desc: "Teaches fractions to a nine-year-old, in pirate voice.", Model: "Claude Haiku 4.5 · Anthropic", ModelValue: "anthropic|claude-haiku-4-5"},
		{ID: fxCouncil, Name: "Council", Color: 4, Desc: "Skeptic, Optimist and Economist debate, then you decide.", Model: "Claude Sonnet 4.5 · Anthropic", ModelValue: "anthropic|claude-sonnet-4-5"},
	}
}

func boardWelcome(first bool) welcomeVM {
	w := welcomeVM{First: first, Profiles: boardCards()}
	if !first {
		w.Recent = boardListIdle().Rows[:4]
	}
	return w
}

func boardDraft(withProfiles bool) draftVM {
	opus := draftModelVM{Value: "anthropic|claude-opus-4-7", Name: "Claude Opus 4.7", Provider: "Anthropic"}
	d := draftVM{Models: []draftModelVM{opus, {Value: "anthropic|claude-sonnet-4-5", Name: "Claude Sonnet 4.5", Provider: "Anthropic"}}}
	if !withProfiles {
		d.Placeholder = "Create a profile to start"
		return d
	}
	d.Profiles = boardCards()
	d.Current = &d.Profiles[0]
	d.Model = opus
	d.Placeholder = "Message Demo"
	return d
}

func boardSearchList() listVM {
	return boardListWith(func(l *listVM) {
		l.Query, l.Archived = "tax", true
		l.Rows = []rowVM{
			{ID: "c-tax", Title: "Tax documents checklist", Time: "9:15", Profile: "Chief of staff", Color: 1, Draft: "Add the 1099-B from the brokerage"},
			{ID: "c-2025", Title: "2025 tax return questions", Time: "Oct 18", Profile: "Chief of staff", Color: 1},
			{ID: "c-syn", Title: "Syntax highlighting in the web client", Time: "Oct 9", Profile: "Demo", Color: 2},
			{ID: "c-etsy", Title: "Sales tax for the Etsy shop", Time: "Sep 22", Profile: "Chief of staff", Color: 1},
			{ID: "c-prop", Title: "Property tax appeal", Time: "Aug 4", Profile: "Chief of staff", Color: 1, Archived: true},
		}
		for i := range l.Rows {
			l.Rows[i].Hits = highlight(l.Rows[i].Title, l.Query)
		}
	})
}

func boardArchivedList() listVM {
	return boardListWith(func(l *listVM) {
		l.Filter, l.Chips = "archived", boardChips("archived")
		l.HoverID = "c-k8s"
		l.Rows = []rowVM{
			{ID: "c-q3", Title: "Q3 board memo draft", Time: "Nov 2", Group: "November", Profile: "Chief of staff", Color: 1, Archived: true},
			{ID: "c-k8s", Title: "Kubernetes ingress notes", Time: "Oct 24", Group: "October", Profile: "Demo", Color: 2, Archived: true},
			{ID: "c-div", Title: "Long division with Captain Ada", Time: "Oct 21", Profile: "Pirate tutor", Color: 3, Archived: true},
			{ID: "c-hire2", Title: "Council: hiring a second engineer", Time: "Oct 14", Profile: "Council", Color: 4, Archived: true},
			{ID: "c-lis", Title: "Lisbon flights, first pass", Time: "Sep 30", Group: "September", Profile: "Chief of staff", Color: 1, Archived: true},
			{ID: "c-pg", Title: "Postgres 16 upgrade checklist", Time: "Sep 12", Profile: "Demo", Color: 2, Archived: true},
			{ID: "c-grant", Title: "Grant application outline", Time: "Aug 27", Group: "August", Profile: "Chief of staff", Color: 1, Archived: true},
			{ID: "c-prop", Title: "Property tax appeal", Time: "Aug 4", Profile: "Chief of staff", Color: 1, Archived: true},
		}
	})
}

func boardCommand() commandVM {
	return commandVM{
		Query:    "comp",
		Commands: []cmdVM{{Label: "Compress this context", Hits: firstHit("Compress this context", "comp"), Hint: "82k tokens", Icon: "compress", Href: "#", Selected: true}},
		Convs: []rowVM{
			{ID: "c-card", Title: "Compression summary card", Hits: highlight("Compression summary card", "comp"), Time: "Thu", Profile: "Demo", Color: 2},
			{ID: "c-comp", Title: "Compensation bands for 2027", Hits: highlight("Compensation bands for 2027", "comp"), Time: "Oct 22", Profile: "Chief of staff", Color: 1, Archived: true},
		},
		Settings: []cmdVM{
			{Label: "Compaction model", Hits: firstHit("Compaction model", "comp"), Hint: "Demo profile", Icon: "gear16", Href: "#"},
			{Label: "Compaction guide", Hits: firstHit("Compaction guide", "comp"), Hint: "Demo profile", Icon: "gear16", Href: "#"},
		},
	}
}

// boardOfflineConv is Main's conversation with the reply that was streaming
// cut off and its question back in the composer.
func boardOfflineConv() convVM {
	c := boardConv()
	c.Items = c.Items[:3]
	c.RunID, c.Live, c.Pending = "", liveInit{}, nil
	c.Draft = "And the compression summary card: same problem?"
	return c
}

func boardTemplates() []tplVM {
	n := func(id, name, mono string) tplVM {
		return tplVM{ID: id, Name: name, Mono: mono, Kind: "Native driver", Driver: id}
	}
	o := func(id, name, mono string) tplVM {
		return tplVM{ID: id, Name: name, Mono: mono, Kind: "OpenAI-compatible", Driver: "openai-compatible", Preset: id}
	}
	t := []tplVM{
		n("anthropic", "Anthropic", "A"), n("google", "Google Gemini", "G"),
		o("openai", "OpenAI", "O"), o("openrouter", "OpenRouter", "R"), o("xai", "xAI Grok", "X"), o("mistral", "Mistral", "M"),
		o("deepseek", "DeepSeek", "D"), o("groq", "Groq", "G"), o("ollama", "Ollama", "O"), o("perplexity", "Perplexity", "P"),
		{ID: customTemplate, Name: "Custom", Mono: "C", Kind: "Any OpenAI-compatible URL", Driver: "openai-compatible", NeedsURL: true},
	}
	t[0].Base = "https://api.anthropic.com"
	t[8].Kind = "Local, OpenAI-compatible"
	return t
}

func boardSetupModels() []setupModelVM {
	c3 := []string{"Vision", "Tools", "Thinking"}
	c2 := []string{"Vision", "Tools"}
	return []setupModelVM{
		{Name: "Claude Opus 4.7", ID: "claude-opus-4-7", Context: "200k", Cost: "$$$", Caps: c3, On: true},
		{Name: "Claude Sonnet 4.5", ID: "claude-sonnet-4-5", Context: "200k", Cost: "$$", Caps: c3, On: true},
		{Name: "Claude Haiku 4.5", ID: "claude-haiku-4-5", Context: "200k", Cost: "$", Caps: c2, On: true},
		{Name: "Claude Opus 4.1", ID: "claude-opus-4-1", Context: "200k", Cost: "$$$", Caps: c3},
		{Name: "Claude Sonnet 4", ID: "claude-sonnet-4-0", Context: "200k", Cost: "$$", Caps: c3},
		{Name: "Claude Haiku 3.5", ID: "claude-3-5-haiku-latest", Context: "200k", Cost: "$", Caps: c2},
	}
}
