package web

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

func (e *setbBrowser) setbLangfuse(t *testing.T, host string) {
	t.Helper()
	pub, sec, on := "pk-lf-1", "sk-lf-1", true
	if _, err := e.lf.UpdateLangfuseConfig(e.uctx, connect.NewRequest(&psmithv1.UpdateLangfuseConfigRequest{Host: &host, PublicKey: &pub, SecretKey: &sec, Enabled: &on})); err != nil {
		t.Fatalf("UpdateLangfuseConfig: %v", err)
	}
}

// Send test trace against a host that answers 404, one that rejects the
// keys, and one that isn't there: each reads as a red failure naming why,
// never as the green "sent" line, and says the test failed the way the
// apps and the provider page do.
func TestBrowser_SetbLangfuseTestShowsFailures(t *testing.T) {
	e := newSetbBrowser(t)
	status := http.StatusNotFound
	lfHost := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) }))
	defer lfHost.Close()

	for _, tc := range []struct {
		name, host, want string
		code             int
	}{
		{"404", lfHost.URL, "404", http.StatusNotFound},
		{"bad key", lfHost.URL, "401", http.StatusUnauthorized},
		{"dead host", "http://127.0.0.1:1", "refused", 0},
	} {
		status = tc.code
		e.setbLangfuse(t, tc.host)
		e.open(t, "/settings/langfuse")
		e.setbClick(t, `button[formaction="/settings/langfuse/test"]`)
		waitUntil(t, e.browserEnv, tc.name+" result", `!!document.querySelector('[role=status].result')`, 15*time.Second)
		got := eval[string](t, e.browserEnv, `(() => { const r = document.querySelector('[role=status].result'); return r.className + '|' + r.innerText + '|' + getComputedStyle(r).color })()`)
		parts := strings.SplitN(got, "|", 3)
		if !strings.Contains(parts[0], "bad") || !strings.HasPrefix(parts[1], "Test failed") || !strings.Contains(parts[1], tc.want) {
			t.Errorf("%s: result %q, want a bad result mentioning %q", tc.name, got, tc.want)
		}
		e.setbShot(t, "lf-"+strings.ReplaceAll(tc.name, " ", "-"))
	}
}

// After Revert, the Test button works again: the bar is gone, so nothing
// unsaved stands between the test and what is saved.
func TestBrowser_SetbRevertReenablesTest(t *testing.T) {
	e := newSetbBrowser(t)
	e.setbLangfuse(t, "http://127.0.0.1:1")
	e.open(t, "/settings/langfuse")
	e.setbTypeInto(t, "#lfhost", "x")
	waitUntil(t, e.browserEnv, "test waits", `document.querySelector('[data-needs-saved]').getAttribute('aria-disabled') === 'true'`, 3*time.Second)
	e.setbClick(t, `[data-savebar] button[type=reset]`)
	time.Sleep(300 * time.Millisecond)
	got := eval[string](t, e.browserEnv, `document.querySelector('[data-savebar]').hidden + ' ' + document.querySelector('[data-needs-saved]').getAttribute('aria-disabled') + ' ' + document.querySelector('[data-needs-saved-note]').hidden`)
	if got != "true null true" {
		t.Fatalf("after Revert: bar hidden, test aria-disabled, note hidden = %q, want \"true null true\"", got)
	}
}
