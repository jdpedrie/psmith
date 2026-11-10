package web

import (
	"testing"

	"github.com/a-h/templ"
)

func TestProbeSettingsA(t *testing.T) {
	nav := boardSettingsNav
	probeAll(t, []probeCase{
		{"SettingsGeneral", func() templ.Component { return generalScreen(nav("general"), saBoardGeneral(false)) }},
		{"SettingsAppearance", func() templ.Component { return appearanceScreen(nav("appearance"), saBoardAppearance()) }},
		{"SettingsUsage", func() templ.Component { return spendScreen(nav("usage"), saBoardUsage()) }},
		{"SettingsProviders", func() templ.Component { return providersScreen(nav("providers"), saBoardProviders()) }},
		{"SettingsAddProvider", func() templ.Component { return addProviderScreen(nav("providers"), saBoardAddProvider()) }},
		{"SettingsDiscover", func() templ.Component { return discoverScreen(nav("providers"), saBoardDiscover()) }},
		{"SettingsModelDetail", func() templ.Component { return modelScreen(nav("providers"), saBoardModel()) }},
		{"SettingsProviderDefaults", func() templ.Component { return defaultsScreen(nav("providers"), saBoardDefaults()) }},
		{"SettingsAddModel", func() templ.Component { return addModelScreen(nav("providers"), saBoardAddModel()) }},
		{"SettingsUsers", func() templ.Component { return usersScreen(nav("users"), saBoardUsers()) }},
		{"PhoneSettings", func() templ.Component { return generalScreen(nav(""), saBoardGeneral(true)) }},
		{"PhoneSettingsPage", func() templ.Component { return providerScreen(nav("providers"), boardProvider()) }},
		{"SettingsProviderCompat", func() templ.Component { return providerScreen(nav("providers"), saBoardProviderCompat()) }},
		{"SettingsModelManual", func() templ.Component { return modelScreen(nav("providers"), saBoardModelManual()) }},
	}, map[string]bool{"SettingsAppearance": true})
}
