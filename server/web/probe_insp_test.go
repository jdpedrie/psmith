package web

import (
	"testing"

	"github.com/a-h/templ"
)

func TestProbeInspector(t *testing.T) {
	conv := func(c func() convVM) func() templ.Component {
		return func() templ.Component { return conversationScreen(boardList(), c()) }
	}
	settled := func(c func() convVM) func() templ.Component {
		return func() templ.Component { return conversationScreen(inspList(false), c()) }
	}
	probeAll(t, []probeCase{
		{"InspectorSettings", conv(boardInspSettings)},
		{"InspectorPlugins", conv(boardInspPlugins)},
		{"InspectorModel", conv(boardInspModel)},
		{"InspectorContexts", conv(boardInspContexts)},
		{"ContextView", func() templ.Component { l, c, v := boardContextView(); return contextViewScreen(l, c, v) }},
		{"PluginPanel", conv(boardPluginPanel)},
		{"InspectorInfo", conv(boardInspInfo)},
		{"ContextCharts", conv(boardContextCharts)},
		{"InspectorPluginsEmpty", conv(boardInspPluginsEmpty)},
		{"PluginConfigList", conv(boardPluginConfigList)},
		{"ReviewStopped", settled(boardReviewStopped)},
		{"InspectorInfoError", conv(boardInspInfoError)},
		{"InspectorSettingsLocked", conv(boardInspSettingsLocked)},
		{"Compress", settled(func() convVM { return boardCompress("compress") })},
		{"Compacting", settled(func() convVM { return boardCompress("compacting") })},
		{"Review", settled(func() convVM { return boardCompress("review") })},
		{"ReviewEdit", settled(func() convVM { return boardCompress("edit") })},
		{"CompressFailed", settled(func() convVM { return boardCompress("failed") })},
		{"Archived", func() templ.Component { l, c := boardArchived(); return conversationScreen(l, c) }},
		{"Elicit", conv(boardElicit)},
		{"PhoneInspector", conv(boardPhoneInspector)},
		{"PhoneCompress", settled(boardPhoneCompress)},
	}, nil)
}
