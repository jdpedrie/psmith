package pluginapi_test

import (
	"os/exec"
	"strings"
	"testing"
)

const modulePath = "github.com/jdpedrie/psmith"

// TestContractDependencyWeight pins what the plugin contract drags in.
//
// pluginapi is the surface an out-of-tree plugin imports, so every package it
// depends on is compiled into that author's binary. Separating it from
// `plugins` was meant to keep that surface honest, and dependency creep is how
// it would quietly stop being honest — one convenience import of a service
// package pulls in the database layer and nobody notices in review.
//
// A ratchet, not a ban. If a new dependency is genuinely warranted, add it
// here deliberately.
func TestContractDependencyWeight(t *testing.T) {
	t.Parallel()

	allowed := map[string]bool{
		// WireMessage and Chunk are aliased from providers rather than
		// redefined, so there is one definition of each in the tree.
		// modelmeta arrives transitively with it.
		modulePath + "/server/providers": true,
		modulePath + "/server/modelmeta": true,
	}

	for _, d := range psmithDeps(t, modulePath+"/pluginapi") {
		if strings.HasPrefix(d, modulePath+"/pluginapi") || allowed[d] {
			continue
		}
		t.Errorf("%s is now compiled into the plugin contract, and therefore into "+
			"every out-of-tree plugin. Add it to `allowed` if that is intended.", d)
	}
}

// TestHostIsSelfContained is the stricter half. The host shims are interfaces
// plus small value types by design — the concrete implementations live
// server-side — so this package should reach nothing in the module at all. If
// it starts importing a service package, an interface has grown a concrete
// dependency and the shim has stopped being a shim.
func TestHostIsSelfContained(t *testing.T) {
	t.Parallel()
	for _, d := range psmithDeps(t, modulePath+"/pluginapi/host") {
		if d != modulePath+"/pluginapi/host" {
			t.Errorf("pluginapi/host should depend on nothing else in this module; got %s", d)
		}
	}
}

// psmithDeps lists this module's packages that pkg transitively depends on.
//
// Uses a fully-qualified import path rather than a ./relative one: the test
// binary runs with its own package directory as cwd, so a relative path
// resolves against the wrong place. It fails rather than skips on error — a
// dependency guard that silently skips is worse than none, since it reports
// success in exactly the situation where it has checked nothing.
func psmithDeps(t *testing.T, pkg string) []string {
	t.Helper()
	out, err := exec.Command("go", "list", "-deps", pkg).CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps %s: %v\n%s", pkg, err, out)
	}
	var deps []string
	for line := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
		if strings.HasPrefix(line, modulePath+"/") {
			deps = append(deps, line)
		}
	}
	if len(deps) == 0 {
		t.Fatalf("go list -deps %s returned no module-local packages; the query is wrong", pkg)
	}
	return deps
}
