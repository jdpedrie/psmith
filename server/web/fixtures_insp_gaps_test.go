package web

import psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"

// Fixtures for the boards that draw the inspector's later states: the run
// charts, an empty Plugins tab, a list setting, a stopped summary, a title
// that didn't save and a locked call setting.

func boardContextCharts() convVM {
	c := boardConv()
	tokens := []int64{3120, 6840, 9410, 14200, 17950, 21300, 26800, 30150, 35900, 39400, 44100, 49800, 54300, 58900, 64600, 70100, 76400, 82140}
	cost := []float64{0.004, 0.006, 0.007, 0.009, 0.011, 0.012, 0.041, 0.016, 0.018, 0.019, 0.021, 0.023, 0.025, 0.026, 0.058, 0.030, 0.032, 0.034}
	var s []turnSample
	for i := range tokens {
		s = append(s, turnSample{Tokens: tokens[i], Cost: cost[i], Priced: true, CacheMiss: i == 6 || i == 14})
	}
	c.Inspector.Charts = runCharts(s, 75000)
	c.Inspector.Unpriced = "qwen3:8b"
	return c
}

func boardInspPluginsEmpty() convVM {
	c := boardConv()
	c.Inspector.Tab = "plugins"
	c.Inspector.Plugins = &pluginsTabVM{ConvID: c.ID, Profile: "Demo", Addable: []plugOptVM{{Name: "imagegen", Display: "Image generation"}}}
	return c
}

func boardPluginConfigList() convVM {
	c := boardConv()
	c.Inspector.Tab, c.Inspector.View = "plugins", "config"
	text := func(name, display, value, desc string) configFieldVM {
		return configFieldVM{Name: listInputName("packs", 0, name), Display: display, Type: "text", Value: value, Description: desc}
	}
	open := listRowVM{N: 0, IDField: "id", ID: "swift", Title: "Swift style guide", Open: true, Fields: []configFieldVM{
		text("name", "Name", "Swift style guide", ""),
		text("description", "When it is relevant", "House rules for SwiftUI views, naming and tests.", "One line. The model sees this and nothing else about the pack until you deliver it."),
		{Name: listInputName("packs", 0, "body"), Display: "Contents", Type: "textarea", Value: "Views stay under 200 lines. Name a view for what it shows, not where it sits. Every new view gets a snapshot test, and every input view gets an event test.", Description: "Delivered verbatim, once."},
	}}
	rows := []listRowVM{open}
	for i, t := range []string{"Jamie’s review checklist", "Release calendar", "Scroll architecture notes"} {
		rows = append(rows, listRowVM{N: i + 1, IDField: "id", ID: t, Title: t})
	}
	c.Inspector.Config = &pluginConfigVM{ConvID: c.ID, Name: "context_packs", Display: "Context packs", Items: []cfgItemVM{
		{List: &listFieldVM{Name: "packs", Display: "Packs", Description: "Each pack is delivered once, when you choose it from the composer.", Rows: rows}},
		{Field: &configFieldVM{Name: "announce_to_model", Display: "Tell the model which packs exist", Type: "boolean", Checked: true,
			Description: "Adds pack names and descriptions (never bodies) to the system prompt so the model can say it needs one."}},
	}}
	return c
}

const fxSummaryStopped = "**Topic.** Why the transcript jumps when a long reply finishes, and whether the compression summary card has the same problem.\n\n**Decided**\n\n- Render the transcript eagerly. Estimated heights with correction passes were rejected because every correction moves the reader.\n- Follow the stream while a reply runs, then park when it ends.\n- Reserve the summary card's final height so it settles without shifting the rows above it.\n\n**Open**\n\n- Paging older history above the last 200 rows. Jamie wants numbers for 500 and"

func boardReviewStopped() convVM {
	c := boardCompress("review")
	c.Inspector.Card.Stopped = true
	c.Inspector.Card.SummaryHTML, c.Inspector.Card.SummaryText = renderMarkdown(fxSummaryStopped), fxSummaryStopped
	c.Inspector.Card.Usage = "In 82,140 (64,900 cached) · out 512 · $0.0124"
	return c
}

func boardInspInfoError() convVM {
	c := boardInspInfo()
	c.Inspector.Info.Confirm = false
	c.Inspector.Info.Title = "Scroll architecture, paging decision"
	c.Inspector.Info.TitleError = "Couldn’t save the title. The server didn’t answer in time."
	return c
}

func boardInspSettingsLocked() convVM {
	c := boardInspSettings()
	one := 1.0
	lockRows(c.Inspector.Settings.Rows, &psmithv1.ModelConstraints{Temperature: &psmithv1.Range{LockedAt: &one}}, "Claude Opus 4.7")
	return c
}
