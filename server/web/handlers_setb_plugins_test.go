package web

import (
	"net/http"
	"net/url"
	"testing"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// Without script, a row's trash button posts the whole tab to remove. The
// other rows' unsaved edits go in with it.
func TestPluginRemove_NoScriptKeepsTheRestOfTheForm(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	id := e.profile(t, "Chief", "")
	if _, err := e.prof.SetProfilePlugins(e.ctx, connect.NewRequest(&psmithv1.SetProfilePluginsRequest{ProfileId: id, Plugins: []*psmithv1.ProfilePlugin{
		{PluginName: "brave_search", Config: []byte(`{}`)}, {PluginName: "memory", Config: []byte(`{}`), Ordinal: 1},
	}})); err != nil {
		t.Fatal(err)
	}
	form := url.Values{"pname_0": {"brave_search"}, "p0_cfg_default_count": {"9"}, "pname_1": {"memory"}, "remove": {"memory"}}
	wantStatus(t, e.post(e.h.handlePluginRemove, "/", map[string]string{"id": id}, form), http.StatusSeeOther)
	resp, err := e.prof.GetProfilePlugins(e.ctx, connect.NewRequest(&psmithv1.GetProfilePluginsRequest{ProfileId: id}))
	if err != nil {
		t.Fatal(err)
	}
	ps := resp.Msg.GetPlugins()
	if len(ps) != 1 || ps[0].GetPluginName() != "brave_search" || string(ps[0].GetConfig()) != `{"default_count":9}` {
		t.Fatalf("plugins after remove: %v", ps)
	}
}
