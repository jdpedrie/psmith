package web

import (
	"testing"

	"github.com/a-h/templ"
)

func TestProbeSettingsB(t *testing.T) {
	nav := func(active string) snavVM { return boardSettingsNav(active) }
	probeAll(t, []probeCase{
		{"SettingsProfiles", func() templ.Component { return profilesScreen(nav("profiles"), boardProfiles()) }},
		{"SettingsProfile", func() templ.Component { return profileGeneralScreen(nav("profiles"), boardProfileGeneral()) }},
		{"SettingsProfileModels", func() templ.Component { return profileModelsScreen(nav("profiles"), boardProfileModels()) }},
		{"SettingsProfilePlugins", func() templ.Component { return profilePluginsScreen(nav("profiles"), boardProfilePlugins()) }},
		{"SettingsProfileShare", func() templ.Component { return profileShareScreen(nav("profiles"), boardProfileShare()) }},
		{"SettingsPlugins", func() templ.Component { return globalPluginsScreen(nav("plugins"), boardGlobalPlugins()) }},
		{"SettingsPluginConfig", func() templ.Component { return pluginConfigScreen(nav("plugins"), boardPluginConfig()) }},
		{"SettingsServers", func() templ.Component { return mcpServersScreen(nav("servers"), boardServers()) }},
		{"SettingsServerDetail", func() templ.Component { return mcpDetailScreen(nav("servers"), boardServerDetail()) }},
		{"SettingsAddServer", func() templ.Component { return mcpFormScreen(nav("servers"), boardAddServer()) }},
		{"SettingsLangfuse", func() templ.Component { return langfuseScreen(nav("langfuse"), boardLangfuse()) }},
		{"SettingsEmbedder", func() templ.Component { return embedderScreen(nav("embedder"), boardEmbedder()) }},
		{"SettingsSpeech", func() templ.Component { return speechScreen(nav("speech"), boardSpeech()) }},
		{"SettingsLangfuseSetup", func() templ.Component { return langfuseScreen(nav("langfuse"), boardLangfuseSetup()) }},
		{"SettingsServerFailing", func() templ.Component { return mcpDetailScreen(nav("servers"), boardServerFailing()) }},
		{"SettingsEditServer", func() templ.Component { return mcpFormScreen(nav("servers"), boardEditServer()) }},
	}, nil)
}
