package web

import psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"

// Board fixtures for the settings-a screens: General, Appearance, Usage,
// providers and models, users. Settings (the Anthropic page) uses
// boardProvider in fixtures_test.go.

func saBoardGeneral(index bool) generalVM {
	return generalVM{Index: index, WarnSel: "100000", UserName: "John", Login: "john", Initial: "J", Admin: true,
		Server: "psmith.home", Version: "0.14.2", PwResult: &testVM{OK: true, Message: "Password changed just now"}}
}

func saBoardAppearance() appearanceVM {
	a := appearanceVM{Mode: "auto", TextSize: 100}
	for _, id := range themeIDs {
		a.Themes = append(a.Themes, themeCardVM{ID: id, Name: themeNames[id], Blurb: saThemeBlurbs[id], On: id == "slate"})
	}
	return a
}

func saBoardUsage() spendVM {
	return spendVM{Range: "month", Period: "November 1 to 7, 2026", Total: "$41.20", Turns: "449 turns", TotalTurns: "449",
		Rows: []spendRowVM{
			{ID: "anthropic", Name: "Anthropic", Type: "Anthropic", Turns: "312", Spend: "$28.64"},
			{ID: "openrouter", Name: "OpenRouter", Type: "OpenAI-compatible", Turns: "137", Spend: "$12.56"},
			{ID: "ollama", Name: "Ollama on nas.local", Type: "OpenAI-compatible", Turns: "No events", Spend: "$0.00", None: true},
		}}
}

func saBoardProviders() providersPageVM {
	return providersPageVM{CanRefresh: true, CatalogLine: "118 providers, 3,412 models · refreshed Nov 5",
		Rows: []provRowVM{
			{ID: "anthropic", Name: "Anthropic", Initial: "A", Sub: "anthropic · 3 of 4 models on", Status: "ok", StatusText: "Connected"},
			{ID: "openrouter", Name: "OpenRouter", Initial: "O", Sub: "openai-compatible · 12 models on", Status: "ok", StatusText: "Connected"},
			{ID: "ollama", Name: "Ollama on nas.local", Initial: "O", Sub: "openai-compatible · nas.local:11434 · 4 models on", Status: "bad", StatusText: "Last test failed"},
		}}
}

func saBoardAddProvider() addProviderVM {
	tiles := []provTileVM{
		{Key: "google", Name: "Google", Initial: "G", Sub: "google"},
		{Key: "openai", Name: "OpenAI", Initial: "O", Sub: "api.openai.com"},
		{Key: "xai", Name: "xAI Grok", Initial: "X", Sub: "api.x.ai"},
		{Key: "deepseek", Name: "DeepSeek", Initial: "D", Sub: "api.deepseek.com"},
		{Key: "groq", Name: "Groq", Initial: "G", Sub: "api.groq.com", On: true},
		{Key: "mistral", Name: "Mistral", Initial: "M", Sub: "api.mistral.ai"},
		{Key: "together", Name: "Together AI", Initial: "T", Sub: "api.together.xyz"},
		{Key: "cerebras", Name: "Cerebras", Initial: "C", Sub: "api.cerebras.ai"},
		{Key: "qwen", Name: "Qwen", Initial: "Q", Sub: "dashscope-intl.aliyuncs.com"},
		{Key: "perplexity", Name: "Perplexity", Initial: "P", Sub: "api.perplexity.ai"},
		{Key: "custom", Name: "Custom", Initial: "+", Sub: "Any compatible endpoint"},
	}
	return addProviderVM{Tiles: tiles, Sel: "groq", Driver: "OpenAI-compatible, Groq preset", Name: "Groq",
		Key: "gsk_7Hq2vT9pXw4LmN0aRc8YbE3k", KeyHint: "Paste your GROQ_API_KEY", BaseURL: "https://api.groq.com/openai/v1"}
}

func saBoardDiscover() discoverVM {
	c3 := []string{"Vision", "Tools", "Thinking"}
	return discoverVM{ProvID: "anthropic", ProvName: "Anthropic", NewCount: 3, Checked: 2, Rows: []discRowVM{
		{ID: "claude-opus-4-7", Name: "Claude Opus 4.7", Context: "200k", Cost: "$$$", Caps: c3, On: true},
		{ID: "claude-sonnet-4-5", Name: "Claude Sonnet 4.5", Context: "200k", Cost: "$$", Caps: c3, On: true},
		{ID: "claude-haiku-4-5", Name: "Claude Haiku 4.5", Context: "200k", Cost: "$", Caps: []string{"Vision", "Tools"}, On: true},
		{ID: "claude-opus-4-1", Name: "Claude Opus 4.1", Context: "200k", Cost: "$$$", Caps: c3, Checked: true},
		{ID: "claude-sonnet-4-0", Name: "Claude Sonnet 4", Context: "200k", Cost: "$$", Caps: c3, Checked: true},
		{ID: "claude-3-7-sonnet-latest", Name: "Claude 3.7 Sonnet", Context: "200k", Cost: "$$", Caps: c3},
	}}
}

func saBoardModel() modelPageVM {
	caps := saCapToggles(nil)
	for i := range caps {
		caps[i].On = caps[i].Value != "generates_images"
	}
	return modelPageVM{ProvID: "anthropic", ProvName: "Anthropic", ProvType: "anthropic", ID: "claude-opus-4-7", Name: "Claude Opus 4.7",
		Favorite: true, Result: &testVM{OK: true, Message: "Replied “OK” in 840 ms · 14 tokens in, 2 out · just now"},
		MetaLine: "From the models.dev catalog, Nov 2", Ctx: "200,000", Out: "32,000", In: "15.00", OutP: "75.00", CR: "1.50", CW: "18.75",
		Caps: caps, Mods: saModToggles([]string{"text", "image", "pdf"}),
		TempHint: "Model default", MaxInherit: "16,384", MaxHint: "Inherits 16,384 from Anthropic",
		Effort: "high", EffortInherit: "Medium", EffortPrev: "Inherit (Medium)", Dirty: 1}
}

func saBoardDefaults() defaultsPageVM {
	return defaultsPageVM{
		Crumbs: []saCrumb{{"Providers", "#"}, {"Anthropic", "#"}},
		Title:  "Anthropic defaults",
		Lede:   "Every Anthropic model starts here. A model’s own settings win, then the profile’s, then the conversation’s. Not set means the model’s own default.",
		Action: "#", Level: "provider", ProvName: "Anthropic", ProvType: "anthropic",
		F:     csForm{MaxTok: "16,384", Stops: []string{"</report>"}, Effort: "medium", PCache: "on", TTL: "1h"},
		Prev:  map[string]string{"effort": "Not set", "cache_ttl": "Not set"},
		Dirty: 2,
	}
}

func saBoardAddModel() addModelVM {
	return addModelVM{ProvID: "ollama", ProvName: "Ollama on nas.local", ModelID: "qwen3-coder:30b", Name: "Qwen3 Coder 30B", Ctx: "262,144",
		Caps:  saCapToggles(&psmithv1.ModelCapabilities{Streaming: true, ToolUse: true}),
		Mods:  saModToggles([]string{"text"}),
		Calls: defaultsPageVM{Level: "model", ProvName: "Ollama on nas.local", ProvType: "openai-compatible"}}
}

func saBoardUsers() usersVM {
	u := usersVM{Server: "psmith.home", NewOpen: true, Rows: []userRowVM{
		{ID: "u-john", Name: "John", Login: "john", Initial: "J", Added: "Mar 3, 2025", Admin: true, Self: true},
		{ID: "u-sarah", Name: "Sarah", Login: "sarah", Initial: "S", Added: "Jun 9, 2025", Mode: "reset"},
		{ID: "u-demo", Name: "Demo", Login: "demo", Initial: "D", Added: "Oct 12, 2026"},
	}}
	u.NewUser.Login, u.NewUser.Name = "maya", "Maya"
	return u
}
