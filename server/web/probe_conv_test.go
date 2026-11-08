package web

import (
	"testing"

	"github.com/a-h/templ"
)

func TestProbeConv(t *testing.T) {
	scr := func(c func() convVM) func() templ.Component {
		return func() templ.Component { return conversationScreen(boardList(), c()) }
	}
	probeAll(t, []probeCase{
		{"Main", scr(boardConv)},
		{"Streaming", scr(boardStreaming)},
		{"Thinking", scr(boardThinking)},
		{"MessageMenu", scr(boardMessageMenu)},
		{"MessageStates", scr(boardMessageStates)},
		{"MessageUsage", scr(boardMessageUsage)},
		{"Branches", scr(boardBranches)},
		{"Attachments", scr(boardAttachments)},
		{"ImageViewer", func() templ.Component { return imagePage(boardImageViewer()) }},
		{"ComposerAttach", scr(boardComposerAttach)},
		{"Council", func() templ.Component {
			l := boardList()
			l.ActiveID = "c-council"
			for i := range l.Rows {
				l.Rows[i].Active = l.Rows[i].ID == "c-council"
			}
			return conversationScreen(l, boardCouncil())
		}},
		{"SystemStrip", scr(boardSystemStrip)},
		{"Harness", scr(boardHarness)},
		{"RenameTitle", scr(boardRenameTitle)},
		{"Fragments", scr(boardFragments)},
		{"Phone", scr(boardPhone)},
	}, map[string]bool{"Main": true})
}
