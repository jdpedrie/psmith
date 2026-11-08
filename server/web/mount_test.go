package web

import (
	"net/http"
	"testing"
)

// Every area registers its own routes; a pattern two areas both claim makes
// ServeMux panic, which would take psmithd down at startup.
func TestMount_RoutesDontConflict(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("Mount panicked: %v", r)
		}
	}()
	New(Deps{}).Mount(http.NewServeMux())
}
