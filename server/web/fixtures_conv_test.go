package web

// Board fixtures for the conversation's boards: the transcript, header and
// composer content each one draws.

func fxUser(id, text string) msgItem {
	return msgItem{ID: id, ConvID: "c-scroll", Role: "user", Text: text, HTML: renderMarkdown(text)}
}

func fxReply(id, parent, text string, u *usageVM) msgItem {
	return msgItem{ID: id, ConvID: "c-scroll", ParentID: parent, Role: "assistant", Text: text, HTML: renderMarkdown(text), Usage: u,
		ModelValue: "anthropic|claude-opus-4-7", ModelLabel: "Claude Opus 4.7 · Anthropic"}
}

func fxUsage(model, tokens, cached, cost string) *usageVM {
	return &usageVM{Model: model, Tokens: tokens + " tokens", Cached: cached, Cost: cost}
}

// fxConv is the shared frame: Scroll architecture review, idle, inspector open.
func fxConv(items ...msgItem) convVM {
	c := boardConv()
	c.Items, c.RunID, c.Live, c.Draft, c.Pending = items, "", liveInit{}, "", nil
	return c
}

var fxLazy = "The lazy stack is the cause. Rows above the viewport report estimated heights until they render, so when the finished reply swaps in, every offset above it shifts and the scroll position lands somewhere new.\n\nTwo changes fix it: render the transcript eagerly, then follow the stream and park when it ends."

func fxFirstReply() msgItem {
	r := fxReply("a1", "u1", fxLazy, fxUsage("Opus 4.7", "1,284", "94% cached", "$0.021"))
	r.Thinking = &thinkVM{Label: "Thought for 6.2s"}
	r.Tools = []toolVM{{Name: "search_docs", Summary: "LazyVStack estimated heights", Dur: "0.8s"}}
	return r
}

func boardStreaming() convVM {
	r1 := fxReply("a1", "u1", "Yes, up to a point. Swap the lazy stack for an eager one and the offsets stop moving, because every row has its real height from the first layout.\n\nThe cost is building every row up front. Below a few hundred messages that is cheap: we measured 38 ms for the first layout at 500 rows.",
		fxUsage("Opus 4.7", "642", "91% cached", "$0.017"))
	r1.Thinking = &thinkVM{Label: "Thought for 4.1s"}
	c := fxConv(fxUser("u1", "Should the transcript stay eager once it gets long?"), r1,
		fxUser("u2", "And past a few hundred? Check what the docs say about LazyVStack estimates."))
	c.RunID, c.Draft, c.JumpShown = "run-1", "Then compare it with paging by date", true
	c.Live = liveInit{
		Chips: []liveChipVM{
			{Label: "Thinking", Live: true, Thinking: true, Secs: "3.2s"},
			{Name: "search_docs", Label: "LazyVStack estimates · running", Live: true, Secs: "1.2s"},
		},
		HTML: "<p>Past a few hundred rows, keep the eager stack for the newest 200 and page older history in above it.</p><p>A lazy stack estimates the height of every row it has not rendered yet, then corrects the estimate once the row appears. Each correction moves everything below it, which is the jump you saw. Paging keeps the eager window small enough that the first layout stays under a frame, and the pages above it only load while the reader is parked<span class=\"caret\"></span></p>",
	}
	return c
}

func boardThinking() convVM {
	r := fxReply("a1", "u1", "About 38 ms to lay out the first time and 21 MB held. Appending a row causes no relayout of the rows above it, which is the whole point.\n\nBoth numbers are fine for a desktop browser. I could not open the design note to compare with the earlier build, so these are the only figures I have.",
		fxUsage("Opus 4.7", "1,204", "94% cached", "$0.034"))
	r.Thinking = &thinkVM{Label: "Thought for 6.2s", Open: true, HTML: renderMarkdown("The user wants numbers for the eager stack, not a description. The cheapest honest answer is to measure it: lay out 500 rows once and read the timer and the resident memory.\n\nIf the benchmark tool is missing, fall back to the figures in the scroll design note and say they are from an earlier build.")}
	r.Tools = []toolVM{
		{Name: "bench_layout", Summary: "500 rows, eager", Dur: "2.4s", Open: true, Input: "{\n  \"rows\": 500,\n  \"stack\": \"eager\"\n}", Output: "{\n  \"first_layout_ms\": 38,\n  \"memory_mb\": 21,\n  \"relayouts_on_append\": 0\n}"},
		{Name: "read_file", Dur: "0.1s", Error: "no such file"},
	}
	return fxConv(fxUser("u1", "What does the eager stack cost at 500 rows? Give me numbers."), r)
}

func boardMessageMenu() convVM {
	r1 := fxFirstReply()
	r1.State = "regen"
	r1.Regen = []providerGroupVM{{Label: "Anthropic", Models: []pickerModelVM{
		{Value: "anthropic|claude-opus-4-7", DisplayName: "Claude Opus 4.7"},
		{Value: "anthropic|claude-sonnet-4-5", DisplayName: "Claude Sonnet 4.5"},
		{Value: "anthropic|claude-haiku-4-5", DisplayName: "Claude Haiku 4.5"},
	}}}
	return fxConv(fxUser("u1", "Why does the transcript jump when a long reply finishes?"), r1,
		fxUser("u2", "And the compression summary card: same problem?"),
		fxReply("a2", "u2", "Yes, the same mechanism. The card is taller once the summary lands, and it sits above the fold, so its growth pushes the reader down by exactly the difference.", fxUsage("Opus 4.7", "412", "96% cached", "$0.012")))
}

func boardMessageStates() convVM {
	del := fxUser("u1", "Is the lazy stack the problem?")
	del.State = "delete"
	edit := fxReply("a1", "u1", "It is. Rows above the viewport report estimated heights until they render, so the finished reply lands somewhere new.\n\nRender the transcript eagerly and every offset is exact.", nil)
	edit.State = "edit"
	failed := fxReply("a2", "u2", "Past a few hundred rows", nil)
	failed.Error = "Anthropic returned 529: the API is overloaded. Try again in a moment."
	return fxConv(del, edit, fxUser("u2", "So what does a jump cost past a few hundred rows? Give me numbers."), failed)
}

func boardMessageUsage() convVM {
	r := fxReply("a1", "u1", "About 38 ms to lay out the first time and 21 MB held. Appending a row causes no relayout of the rows above it.\n\nBoth are fine for a desktop browser. Past a few thousand rows the first layout crosses a frame, which is where paging starts to pay.",
		&usageVM{Model: "Opus 4.7", Tokens: "1,284 tokens", Cached: "94% cached", Cost: "$0.098", Open: true,
			ModelName: "Claude Opus 4.7", Provider: "Anthropic", Stop: "end_turn", Sent: "10:42",
			Input: "2,882", CacheR: "77,210", CacheW: "2,048", Output: "1,284", Reason: "312",
			InCost: "$0.0144", CacheRC: "$0.0386", CacheWC: "$0.0128", OutCost: "$0.0321", Total: "$0.0979",
			CachedPct: 94, Saved: "$0.3474"})
	r.Tools = []toolVM{{Name: "bench_layout", Summary: "500 rows, eager", Dur: "2.4s"}}
	return fxConv(fxUser("u1", "What does the eager stack cost at 500 rows?"), r)
}

func boardBranches() convVM {
	u2 := fxUser("u2", "And the compression summary card: does it jump for the same reason, or is that a different bug?")
	u2.Edited, u2.Branch = true, &branchVM{Index: 2, Count: 2, PrevID: "u2a"}
	r2 := fxReply("a2", "u2", "Same reason. The card sits above the fold and grows when the summary lands, so everything below it moves by the difference.\n\nThe eager stack fixes both. There is no second bug: once the card has its real height from the first layout, nothing above the reader changes size.",
		fxUsage("Sonnet 4.5", "388", "92% cached", "$0.004"))
	r2.Thinking = &thinkVM{Label: "Thought for 3.8s"}
	r2.Branch = &branchVM{Index: 2, Count: 3, PrevID: "a2a", NextID: "a2c"}
	vm := fxConv(fxUser("u1", "Why does the transcript jump when a long reply finishes?"),
		fxReply("a1", "u1", "The lazy stack is the cause. Rows above the viewport report estimated heights until they render, so when the finished reply swaps in, every offset above it shifts.", fxUsage("Opus 4.7", "1,284", "94% cached", "$0.021")),
		u2, r2)
	vm.Inspector.Branches = branchRows(vm.Items)
	return vm
}

func boardAttachments() convVM {
	u1 := fxUser("u1", "This is the jump on device, mid-stream.")
	u1.Images = []attachVM{{ID: "f1", Name: "scroll-jump-before.png"}}
	u2 := fxUser("u2", "Before and after the eager stack, plus the trace. What moves?")
	u2.Images = []attachVM{{ID: "f1", Name: "scroll-jump-before.png"}, {ID: "f2", Name: "scroll-jump-after.png"}, {ID: "f3", Name: "eager-stack.png"}}
	u2.Files = []attachVM{{ID: "f4", Name: "scroll-trace.pdf", Kind: "PDF", Size: "1.2 MB"}}
	return fxConv(u1,
		fxReply("a1", "u1", "The reply’s top sits well below where it started. That is the estimate correcting as rows above it render.", fxUsage("Opus 4.7", "296", "93% cached", "$0.011")),
		u2,
		fxReply("a2", "u2", "In the first shot the reply’s top sits 214 pixels lower than in the second. The trace agrees: page 3 shows a layout pass on every row above the viewport when the stream ends, and with the eager stack that pass is gone.", fxUsage("Opus 4.7", "1,032", "94% cached", "$0.031")))
}

func boardImageViewer() imagePageVM {
	return imagePageVM{ConvID: "c-scroll", ConvTitle: "Scroll architecture review", MsgID: "u1", Name: "scroll-jump-before.png", Meta: "PNG · 412 KB · sent by you today at 10:31"}
}

func boardComposerAttach() convVM {
	c := fxConv(fxUser("u1", "Here’s the jump on device. What moves?"),
		fxReply("a1", "u1", "The reply’s top sits well below where it started. That is the estimate correcting as rows above it render.\n\nIf you have an Instruments trace from the same run, attach it and I can point at the layout pass.", fxUsage("Opus 4.7", "296", "93% cached", "$0.011")))
	c.Draft = "Here’s the trace. Where does the 38 ms go?"
	c.Pending = []attachVM{{ID: "f1", Name: "trace.png", Size: "112 KB"}, {Name: "scroll-trace.pdf", Kind: "PDF", Size: "1.2 MB", Pct: 64}}
	c.Uploading, c.Dropping, c.DropNote = 1, true, "Claude Opus 4.7 takes images and PDFs."
	return c
}

func boardCouncil() convVM {
	voice := func(id, parent, name string, n int, text string) msgItem {
		r := fxReply(id, parent, text, nil)
		r.ConvID, r.Persona, r.PersonaN = "c-council", name, n
		return r
	}
	u := fxUser("u1", "Should launch pricing include a free tier? We sell to self-hosters and small teams.")
	u.ConvID = "c-council"
	e := voice("a3", "a2", "Economist", 2, "Both work if the cap sits below where a team needs it. A one-user cap converts when the second person joins. Pick the cap first, then the price.")
	e.Usage = fxUsage("Sonnet 4.5", "214", "88% cached", "$0.003")
	items := []msgItem{u,
		voice("a1", "u1", "Skeptic", 0, "A free tier anchors the price at zero. Self-hosters who never pay still file issues. Charge from day one and offer a 14-day trial instead."),
		voice("a2", "a1", "Optimist", 1, "Self-hosters try before they buy, and they tell their teams. A free tier capped at one user costs us almost nothing to run, because they run it."),
		e,
	}
	finishItems(items)
	return convVM{
		ID: "c-council", Title: "Council: pricing debate", Profile: "Council", Color: 4, Personas: personasOf(items), ContinueID: "a3",
		Model:       modelChipVM{Value: "anthropic|claude-sonnet-4-5", Name: "Claude Sonnet 4.5", Provider: "Anthropic"},
		Gauge:       gaugeVM{Tokens: 6000, Window: 200000, Label: "6k"},
		Placeholder: "Message Council", Items: items,
	}
}

func boardSystemStrip() convVM {
	start := msgItem{Role: "start", ConvID: "c-scroll", Strip: "Context 2 · started from a summary of 46 turns", Start: &startVM{
		Open: true, PromptFrom: "Demo", PromptID: "s1", SummaryID: "x1", SummaryTitle: "Summary of context 1", SummaryMeta: "46 turns · compressed Oct 30",
		Prompt:  renderMarkdown("You are a senior reviewer for a SwiftUI and Go codebase. Answer in short paragraphs, cite the file and line you mean, and say plainly when you are guessing.\n\nPrefer measured numbers over adjectives."),
		Summary: renderMarkdown("We traced the transcript jump to the lazy stack. Rows above the viewport report estimated heights, and the finished reply swapping in shifts every offset above it.\n\n- Decided: render the transcript eagerly and follow the stream, then park when it ends.\n- Measured: 38 ms first layout and 21 MB at 500 rows, eager.\n- Open: how to page older history once a conversation passes a few hundred rows."),
	}}
	return fxConv(start, fxUser("u1", "Picking up from the summary: how do we page older history?"),
		fxReply("a1", "u1", "Keep the newest 200 rows eager and load older ones in pages above them. Insert each page only while the reader is parked, then restore the offset of the first visible row so nothing moves under them.", fxUsage("Opus 4.7", "486", "95% cached", "$0.014")))
}

func boardHarness() convVM {
	h := &harnessVM{ProviderID: "cc", ProviderLabel: "Claude Code", DriverType: "claude_code", FrozenPrompt: true, NoAttachments: true}
	c := fxConv(msgItem{Role: "harness", ConvID: "c-scroll", Harness: h},
		fxUser("u1", "Run the scroll tests and tell me which ones still fail."),
		fxReply("a1", "u1", "Two of the six fail, both in `TranscriptScrollTests`. `aLongReplyParksWithItsStartInView` lands 18 points low, and `sendingCatchesUpFromAnywhere` times out waiting for the first frame.\n\nThe first is the clip height: it uses the viewport before the composer measures. The second looks like the test, not the code. It waits for a layout pass that the eager stack no longer needs.", fxUsage("Opus 4.7", "1,912", "", "$0.064")),
		fxUser("u2", "Fix the clip height and leave the test alone for now."),
		fxReply("a2", "u2", "Done. The clip now reads the composer’s measured height before it pins, and `aLongReplyParksWithItsStartInView` passes. The other failure is unchanged, as you asked.", fxUsage("Opus 4.7", "644", "", "$0.021")))
	c.Harness, c.ProfileID = h, "p-demo"
	c.Inspector.Tab = "settings"
	return c
}

func boardRenameTitle() convVM {
	c := fxConv(msgItem{Role: "strip", Strip: "Context 2 · started from a summary of 46 turns", StripLink: "#"},
		fxUser("u1", "Why does the transcript jump when a long reply finishes?"), fxFirstReply(),
		fxUser("u2", "And past a few hundred rows? Is eager still the answer?"),
		fxReply("a2", "u2", "Up to a point. Keep the newest 200 rows eager and page older history in above them, inserting each page only while the reader is parked.", fxUsage("Opus 4.7", "486", "95% cached", "$0.014")))
	c.Rename, c.Title = true, "Scroll jump: eager stack vs paging"
	return c
}

func boardFragments() convVM {
	r := fxReply("a1", "u1", "", fxUsage("Opus 4.7", "702", "93% cached", "$0.022"))
	r.Parts = []fragVM{
		fragmentOf("text", []byte(`{"text":"Two references worth reading, then the numbers from our own run."}`)),
		fragmentOf("card_list", []byte(`{"items":[{"title":"ScrollPosition and anchored inserts","description":"Keep the first visible row fixed while content is inserted above it.","url":"https://developer.apple.com/documentation/swiftui/scrollposition","badges":["Apple docs","iOS 18"]},{"title":"Chat scroll design note","description":"Follow, then park. Why the stack is eager and when that stops being cheap.","url":"https://psmith.home/docs/clients/chat-scroll.md","badges":["docs/clients"]}]}`)),
		fragmentOf("key_value", []byte(`{"pairs":[{"key":"Rows","value":"412"},{"key":"First layout","value":"11.8 ms"},{"key":"Largest jump","value":"0 px"}]}`)),
		fragmentOf("text", []byte(`{"text":"Nothing jumped at 412 rows. Which should we build next?"}`)),
		fragmentOf("choice_list", []byte(`{"items":[{"label":"A. Anchor inserts with ScrollPosition, then page by 100 rows","value":"A","action":"send:A"},{"label":"B. Page by day, so each insert is one date header and its rows","value":"B","action":"send:B"},{"label":"C. No paging yet: measure at 2,000 rows first","value":"C","action":"send:C"}]}`)),
	}
	r.Parts[4].Choices[1].Chosen = true
	return fxConv(fxUser("u1", "Find me references on restoring scroll position, then the numbers from our run."), r)
}

func boardPhone() convVM {
	r := fxReply("a1", "u1", "The lazy stack is the cause. Rows above the viewport report estimated heights until they render, so when the finished reply swaps in, every offset above it shifts.\n\nTwo changes fix it: render the transcript eagerly, then follow the stream and park when it ends.",
		fxUsage("Opus 4.7", "1,284", "94% cached", "$0.021"))
	r.Thinking = &thinkVM{Label: "Thought for 6.2s"}
	r.Tools = []toolVM{{Name: "search_docs", Summary: "LazyVStack estimated heights", Dur: "0.8s"}}
	c := fxConv(fxUser("u1", "Why does the transcript jump when a long reply finishes?"), r, fxUser("u2", "And the compression summary card: same problem?"))
	c.ShowInsp = false
	c.RunID = "run-1"
	c.Live = liveInit{Chips: []liveChipVM{{Name: "grep", Label: "running", Live: true}},
		HTML: "<p>Yes, the same mechanism. The card is taller once the summary lands<span class=\"caret\"></span></p>"}
	return c
}
