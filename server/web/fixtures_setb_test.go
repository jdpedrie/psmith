package web

// Board fixtures for the settings-b screens: profiles, plugins, MCP
// servers, embedder, Langfuse and speech, as drawn on the canvas.

func fxModelGroups() []modelGroup {
	return []modelGroup{
		{Provider: "Anthropic", Models: []modelVM{{Value: "a|opus", Label: "Claude Opus 4.7"}, {Value: "a|sonnet", Label: "Claude Sonnet 4.5"}, {Value: "a|haiku", Label: "Claude Haiku 4.5"}}},
		{Provider: "OpenRouter", Models: []modelVM{{Value: "o|ds", Label: "DeepSeek V3.1"}, {Value: "o|gem", Label: "Gemini 2.5 Pro"}}},
		{Provider: "Ollama on nas.local", Models: []modelVM{{Value: "l|qwen", Label: "qwen3:32b"}, {Value: "l|llama", Label: "llama3.3:70b"}}},
	}
}

func fxDemoHead(tab string) profileHeadVM {
	return profileHeadVM{ID: fxDemo, Name: "Demo", Color: profileColor(fxDemo), ParentID: fxChief, ParentName: "Chief of staff", Tab: tab}
}

func boardProfiles() profileListVM {
	return profileListVM{MenuOpen: fxPirate, Rows: []profileListRowVM{
		{ID: fxChief, Name: "Chief of staff", Sub: "Plans, priorities and follow-ups. Parent of Demo.", Model: "Claude Opus 4.7", Color: profileColor(fxChief), IsDefault: true},
		{ID: fxDemo, Name: "Demo", Sub: "Architecture reviews for the iOS app. Inherits from Chief of staff.", Model: "Claude Opus 4.7", Color: profileColor(fxDemo), Depth: 1},
		{ID: fxPirate, Name: "Pirate tutor", Sub: "Teaches anything, in pirate.", Model: "Claude Sonnet 4.5", Color: profileColor(fxPirate)},
		{ID: fxCouncil, Name: "Council", Sub: "Skeptic, Optimist and Economist argue it out.", Model: "Claude Opus 4.7", Color: profileColor(fxCouncil)},
	}}
}

func boardProfileGeneral() profileGeneralVM {
	return profileGeneralVM{
		Head: fxDemoHead("general"), Name: "Demo", Description: "Architecture reviews for the iOS app.",
		ParentOpts:  []sbOpt{{Value: "", Label: "No parent"}, {Value: fxChief, Label: "Chief of staff", Selected: true}, {Value: fxCouncil, Label: "Council"}, {Value: fxPirate, Label: "Pirate tutor"}},
		DefaultName: "Chief of staff", Favorite: true,
		System: "You are a senior iOS engineer reviewing architecture for the Psmith app. Answer with the decision first, then the reason. Cite file names when you have them. When two designs both work, say which one you would ship and why.",
		Dirty:  1,
	}
}

func boardProfileModels() profileModelsVM {
	g := fxModelGroups()
	return profileModelsVM{
		Head:       fxDemoHead("models"),
		ReplyOpts:  modelSelectOpts(g, "Inherit (Claude Sonnet 4.5)", "a|opus"),
		CompOpts:   modelSelectOpts(g, "Inherit (Claude Haiku 4.5)", "a|haiku"),
		TitleOpts:  modelSelectOpts(g, "Inherit (Claude Haiku 4.5)", "a|haiku"),
		Mode:       "REPLACE",
		CompGuide:  "Keep decisions, file names and open questions. Drop pleasantries.",
		TitleGuide: "Name the component, like Composer or Scroll.",
		Temp:       "0.7", TempInherited: "1.0",
		MaxPlaceholder: "16,384 from Claude Opus 4.7",
		EffortOpts:     []sbOpt{{Value: "", Label: "Inherit (Medium)"}, {Value: "off", Label: "Off"}, {Value: "low", Label: "Low"}, {Value: "medium", Label: "Medium"}, {Value: "high", Label: "High", Selected: true}, {Value: "xhigh", Label: "Extra high"}},
		EffortChanged:  "Inherit (Medium)",
		CacheOpts:      []sbOpt{{Value: "", Label: "Inherit (On)", Selected: true}, {Value: "on", Label: "On"}, {Value: "off", Label: "Off"}},
		SlotNote:       "Leave a slot on Inherit to use what Chief of staff picks. With no title model anywhere in the chain, auto-titling is off.",
		CallNote:       "These apply to every conversation on Demo. Blank fields inherit from the model, then the provider. A conversation can still override any of them.",
		Dirty:          1,
	}
}

func boardProfilePlugins() profilePluginsVM {
	return profilePluginsVM{
		Head: fxDemoHead("plugins"),
		Inherited: []inhPluginVM{
			{Name: "basic_grounding", Display: "Basic Grounding", Desc: "Puts the date and time in front of each message, hidden from the transcript.", Tags: []sbTagVM{{Label: "Outgoing"}, {Label: "Display"}}, On: true},
			{Name: "memory", Display: "Memory", Desc: "Searches older messages when the context has been compressed. Off for Demo.", Tags: []sbTagVM{{Label: "Tool"}}},
		},
		Attached: []attPluginVM{
			{Index: 0, Name: "brave_search", Display: "Brave Search", Desc: "Gives the model a web_search tool backed by the Brave Search API.", Tags: []sbTagVM{{Label: "Tool"}, {Label: "Needs an API key in Plugins", Warn: true}}},
			{Index: 1, Name: "imagegen", Display: "Image Generation", Desc: "Gives the model a generate_image tool backed by an image model you choose.", Tags: []sbTagVM{{Label: "Tool"}, {Label: "1 required field", Warn: true}}},
			{Index: 2, Name: "mcp:linear", Display: "Linear", Desc: "MCP server at mcp.linear.app. 6 tools, prefixed linear_.", Tags: []sbTagVM{{Label: "Tool"}, {Label: "MCP"}}},
		},
		Add: []addPluginVM{
			{Name: "context_packs", Display: "Context Packs", Desc: "Named background packs, sent on demand"},
			{Name: "council", Display: "Council", Desc: "A panel of personas answers and discusses"},
			{Name: "lettered_choices", Display: "Lettered Choices", Desc: "Lettered options the reply ends with"},
			{Name: "text_injector", Display: "Text Injector", Desc: "Fixed text at set places in the prompt"},
		},
		AddMCP:   []addPluginVM{{Name: "mcp:firecrawl", Display: "Firecrawl", Desc: "MCP server · failing, test it in MCP servers"}},
		AddOpen:  true,
		CredName: "Brave Search",
		Dirty:    2,
	}
}

func boardProfileShare() profileShareVM {
	head := fxDemoHead("share")
	return profileShareVM{
		Head: head, ChainLen: 2, Filename: "demo.psmithprofile",
		Notices: []string{"The Brave Search API key", "Linear's HTTP headers"},
		Import: &importReviewVM{
			FileName: "pirate-tutor.psmithprofile", Summary: "1 profile · exported by Ana", Payload: "x",
			Warnings: []importWarnVM{
				{Renamed: "Pirate tutor (2)", Original: "Pirate tutor", Neutral: true},
				{Text: "Needs an OpenRouter provider. Its default model stays empty until you pick one."},
				{Text: "Needs an MCP server named Firecrawl. That plugin is left off until you register one."},
			},
		},
		Delete: sbConfirmVM{ID: "sb-delete", Open: true, Question: "Delete Demo?", Detail: "This can't be undone. Its prompt, models and plugins go with it.", Verb: "Delete", CancelHref: "#", Action: "#"},
	}
}

func boardGlobalPlugins() pluginsPageVM {
	row := func(name, display, status, kind string, tags ...string) globalPluginRowVM {
		return globalPluginRowVM{Name: name, Display: display, Tags: tags, Status: status, Kind: kind}
	}
	return pluginsPageVM{
		Builtin: []globalPluginRowVM{
			row("basic_grounding", "Basic Grounding", "None", "none", "Outgoing", "Display"),
			row("brave_search", "Brave Search", "Needs an API key", "warn", "Tool"),
			row("component_builder", "Component Builder", "None", "none", "System", "History", "Display"),
			row("context_packs", "Context Packs", "None", "none", "System", "Panel"),
			row("council", "Council", "None", "none", "Assistant", "History"),
			row("mcp", "Custom MCP server", "None", "none", "Tool"),
			row("game_master", "Game Master", "None", "none", "Tool", "Assistant", "Display"),
			row("imagegen", "Image Generation", "None", "none", "Tool"),
			row("lettered_choices", "Lettered Choices", "None", "none", "System", "History", "Display"),
			row("memory", "Memory", "", "embedder", "Tool"),
			row("text_injector", "Text Injector", "None", "none", "System", "History"),
		},
		MCP: []mcpPluginRowVM{
			{ID: "firecrawl", Name: "Firecrawl", Tags: []string{"Tool"}, Status: "Failing · exit status 1"},
			{ID: "linear", Name: "Linear", Tags: []string{"Tool"}, Status: "6 tools", OK: true},
		},
	}
}

func boardPluginConfig() pluginConfigPageVM {
	return pluginConfigPageVM{
		Name: "brave_search", Display: "Brave Search",
		Desc: "Gives the model a web_search tool backed by the Brave Search API. Each call returns the top web results (title, URL, snippet) for a query.",
		Shared: []configFieldVM{{Name: "api_key", Display: "API key", Type: "text", Required: true, Secret: true, Value: "BSAx7Qm2kR9vT4nL8pW3",
			Description: "Brave Search subscription token. Get one at api.search.brave.com."}},
		PerProfile: []perProfileFieldVM{
			{Display: "Default result count", Summary: "Default 5. Brave caps at 20."},
			{Display: "Safe search", Summary: "Default Moderate"},
			{Display: "Country bias", Summary: "Not set by default"},
		},
		Dirty: 1,
	}
}

func boardServers() []mcpRowVM {
	return []mcpRowVM{
		{ID: "firecrawl", Name: "Firecrawl", Summary: "stdio · npx -y firecrawl-mcp", Error: "exit status 1: FIRECRAWL_API_KEY is not set"},
		{ID: "linear", Name: "Linear", Summary: "http · https://mcp.linear.app/mcp", Tools: 6, OK: true},
	}
}

func boardServerDetail() mcpDetailVM {
	s := mcpServerVM{ID: "linear", Name: "Linear", Transport: "http", URL: "https://mcp.linear.app/mcp", HasHeaders: true, ToolPrefix: "linear_"}
	vm := mcpDetailVM{Server: s, Status: &testVM{OK: true, Message: "Connected and listed 6 tools, just now"},
		Tools: []string{"list_issues", "get_issue", "create_issue", "update_issue", "list_projects", "search_documentation"}}
	vm.Delete = mcpDeleteConfirm(s, true)
	return vm
}

func boardAddServer() mcpFormVM {
	return mcpFormVM{Server: mcpServerVM{Name: "GitHub", Transport: "http", URL: "https://api.githubcopilot.com/mcp/", ToolPrefix: "github_"},
		Headers: "Authorization: Bearer ghp_R8kQ2mV7xN4pL9tW3yZ6"}
}

func boardLangfuse() sbLangfuseVM {
	return sbLangfuseVM{
		Host: "https://us.cloud.langfuse.com", PublicKey: "pk-lf-7c41e2d9-3b8a-4f6e-9d12-a5c0e8b4f713", SecretSet: true, Enabled: true,
		LastEmit: "4 min ago · 10:42",
		Status:   &testVM{OK: true, Message: "Test trace sent in 312 ms, just now. Look for it in your Langfuse Traces tab."},
		Remove:   langfuseRemove(true),
	}
}

func boardEmbedder() sbEmbedderVM {
	return sbEmbedderVM{
		TypeOpts: []sbOpt{{Value: "openai", Label: "openai", Selected: true}},
		BaseURL:  "http://nas.local:11434/v1", Model: "embeddinggemma", ModelOrig: "nomic-embed-text",
		Enabled: true, Waiting: "1,204", Active: true, Dirty: 1, Remove: embedderRemove(false),
	}
}

func boardSpeech() sbSpeechVM {
	return sbSpeechVM{
		KindOpts: []sbOpt{{Value: "apple_local", Label: "On-device"}, {Value: "grok", Label: "Grok (xAI)"}, {Value: "openai-compatible", Label: "OpenAI-compatible", Selected: true}},
		Voice:    "alloy", Model: "gpt-4o-mini-tts", Speed: "1.0", KeySet: true,
		ProviderOpts: []sbOpt{{Value: "", Label: "None", Selected: true}, {Value: "a", Label: "Anthropic"}, {Value: "o", Label: "OpenRouter"}, {Value: "l", Label: "Ollama on nas.local"}},
		Note:         speechKindNotes["openai-compatible"],
		Status:       &testVM{OK: true, Message: "Synthesized 18,432 bytes of audio in 640 ms, just now"},
		Reset:        speechReset(false),
	}
}
