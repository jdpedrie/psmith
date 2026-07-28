package all_test

import (
	"os"
	"testing"

	"github.com/jdpedrie/psmith/pluginapi"
	_ "github.com/jdpedrie/psmith/plugins/all"
)

// TestEveryPluginIsLinked catches the failure mode this package exists to
// create. A plugin registers itself from init(), so one missing blank import
// means the plugin silently does not exist: no build error, no test failure,
// just a profile that references a plugin the registry has never heard of.
//
// The expected set is derived from the directory listing rather than written
// out, so adding a plugin folder and forgetting all.go fails here instead of
// in production.
func TestEveryPluginIsLinked(t *testing.T) {
	t.Parallel()

	entries, err := os.ReadDir("..")
	if err != nil {
		t.Fatalf("read plugins dir: %v", err)
	}

	registered := make(map[string]bool)
	for _, name := range pluginapi.ListRegistered() {
		registered[name] = true
	}

	var want int
	for _, e := range entries {
		// Each plugin's directory name is its registered name. `all` is this
		// package, not a plugin.
		if !e.IsDir() || e.Name() == "all" {
			continue
		}
		want++
		if !registered[e.Name()] {
			t.Errorf("plugins/%s exists but is not registered; add a blank import to all.go", e.Name())
		}
	}

	if want == 0 {
		t.Fatal("found no plugin directories; the listing is wrong")
	}
	if len(registered) != want {
		t.Errorf("registered %d plugins from %d directories: %v", len(registered), want, pluginapi.ListRegistered())
	}
}
