package web

import (
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

func (e *setbBrowser) setbPlugins(t *testing.T, id string) string {
	t.Helper()
	r, err := e.prof.GetProfilePlugins(e.uctx, connect.NewRequest(&psmithv1.GetProfilePluginsRequest{ProfileId: id}))
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, p := range r.Msg.GetPlugins() {
		s := p.GetPluginName() + " " + string(p.GetConfig())
		if p.GetDisabled() {
			s += " off"
		}
		out = append(out, s)
	}
	return strings.Join(out, "; ")
}

// Add plugin is a button on the tab's form, so it carries whatever is
// unsaved there. Adding keeps those edits instead of quietly dropping a
// config change and an inherited switch.
func TestBrowser_SetbAddPluginKeepsUnsavedEdits(t *testing.T) {
	e := newSetbBrowser(t)
	chief := e.setbProfile(t, "Chief", "")
	demo := e.setbProfile(t, "Demo", chief)
	if _, err := e.prof.SetProfilePlugins(e.uctx, connect.NewRequest(&psmithv1.SetProfilePluginsRequest{ProfileId: chief, Plugins: []*psmithv1.ProfilePlugin{{PluginName: "memory", Config: []byte(`{}`)}}})); err != nil {
		t.Fatal(err)
	}
	if _, err := e.prof.SetProfilePlugins(e.uctx, connect.NewRequest(&psmithv1.SetProfilePluginsRequest{ProfileId: demo, Plugins: []*psmithv1.ProfilePlugin{{PluginName: "brave_search", Config: []byte(`{}`)}}})); err != nil {
		t.Fatal(err)
	}
	e.open(t, "/settings/profiles/"+demo+"/plugins")
	e.setbClick(t, `[data-switch="inh_on_0"]`)
	e.setbClick(t, `[aria-controls="pcfg-0"]`)
	e.setbClearAndType(t, "#p0_cfg_default_count", "7")
	e.setbClick(t, `.sb-addwrap summary`)
	e.setbClick(t, `button[name=plugin_name][value=basic_grounding]`)
	e.setbWaitPath(t, "/settings/profiles/"+demo+"/plugins")
	waitUntil(t, e.browserEnv, "added", `location.search.includes("open=basic_grounding")`, 5*time.Second)
	got := e.setbPlugins(t, demo)
	want := `brave_search {"default_count":7,"safesearch":"moderate"}; basic_grounding {}; memory {} off`
	if got != want {
		t.Fatalf("after Add with unsaved edits:\n got %s\nwant %s", got, want)
	}
}
