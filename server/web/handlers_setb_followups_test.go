package web

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
)

// shown follows a POST's redirect to the page it kept, the way a browser
// would, and returns that page.
func (e setbEnv) shown(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	wantStatus(t, rec, http.StatusSeeOther)
	loc := rec.Header().Get("Location")
	if !strings.Contains(loc, "shown=") {
		t.Fatalf("redirected to %q, which shows nothing kept", loc)
	}
	req := httptest.NewRequest("GET", loc, nil).WithContext(e.ctx)
	return wantStatus(t, do(e.h.shownOr(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("GET %s didn't find the kept page", loc)
	}), req), http.StatusOK)
}

// A refused save answers with a redirect to the page's own URL, so a
// refresh is a GET; the page it shows there still has what was typed and
// the error. Only the user who posted sees it, only at that path.
func TestSetbShown_RefusedSaveIsAGet(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	id := e.profile(t, "Demo", "")
	rec := e.post(e.h.handleProfileUpdate, "/settings/profiles/"+id, map[string]string{"id": id}, url.Values{"name": {" "}, "description": {"typed and kept"}})
	wantStatus(t, rec, http.StatusSeeOther)
	loc := rec.Header().Get("Location")
	if !strings.HasPrefix(loc, "/settings/profiles/"+id+"?shown=") {
		t.Fatalf("refusal redirected to %q", loc)
	}
	body := e.shown(t, rec)
	for _, want := range []string{"A profile needs a name.", "typed and kept", `data-initial="`} {
		if !strings.Contains(body, want) {
			t.Errorf("kept page missing %q", want)
		}
	}

	fresh := func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("fresh")) }
	get := func(ctx context.Context, target string) string {
		return do(e.h.shownOr(fresh), httptest.NewRequest("GET", target, nil).WithContext(ctx)).Body.String()
	}
	if got := get(e.ctx, loc); !strings.Contains(got, "typed and kept") {
		t.Error("a refresh lost the kept page")
	}
	other := auth.ContextWithUser(context.Background(), auth.User{ID: uuid.New()})
	if got := get(other, loc); got != "fresh" {
		t.Error("another user was shown the kept page")
	}
	tok := strings.TrimPrefix(loc, "/settings/profiles/"+id+"?shown=")
	if got := get(e.ctx, "/settings/profiles/"+id+"/models?shown="+tok); got != "fresh" {
		t.Error("the kept page showed at another path")
	}
	shownPages.Lock()
	p := shownPages.m[tok]
	p.at = time.Now().Add(-shownTTL - time.Second)
	shownPages.m[tok] = p
	shownPages.Unlock()
	if got := get(e.ctx, loc); got != "fresh" {
		t.Error("an expired page was still shown")
	}
}

// Langfuse refuses Send traces without a secret. The page that says so
// keeps the host and public key that were typed, with the save bar up,
// rather than redrawing what is stored.
func TestSetbLangfuse_RefusalKeepsTyping(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	rec := e.post(e.h.handleLangfuseSave, "/settings/langfuse", nil, url.Values{"host": {"https://lf.example"}, "public_key": {"pk-typed"}, "enabled": {"true"}})
	body := e.shown(t, rec)
	for _, want := range []string{`value="https://lf.example"`, `value="pk-typed"`, `class="result bad"`} {
		if !strings.Contains(body, want) {
			t.Errorf("refused Langfuse save missing %q", want)
		}
	}
	if strings.Contains(body, `data-savebar data-initial="0" hidden`) {
		t.Error("save bar hidden after a refused save")
	}
}

// Every Test answers with a redirect: refreshing the result must not run
// the test again.
func TestSetbTests_RedirectToTheirPage(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	for _, tc := range []struct {
		name string
		fn   http.HandlerFunc
		page string
	}{
		{"langfuse", e.h.handleLangfuseTest, "/settings/langfuse?shown="},
		{"embedder", e.h.handleEmbedderTest, "/settings/embedder?shown="},
		{"speech", e.h.handleSpeechTest, "/settings/speech?shown="},
	} {
		rec := e.post(tc.fn, "/", nil, url.Values{})
		wantStatus(t, rec, http.StatusSeeOther)
		if loc := rec.Header().Get("Location"); !strings.HasPrefix(loc, tc.page) {
			t.Errorf("%s test redirected to %q", tc.name, loc)
		}
	}
	rec := e.post(e.h.handleMCPServerTest, "/", map[string]string{"id": "abc"}, url.Values{})
	wantStatus(t, rec, http.StatusSeeOther)
	if loc := rec.Header().Get("Location"); loc != "/settings/mcp-servers/abc" {
		t.Errorf("MCP test redirected to %q", loc)
	}
}

func TestFailureReason(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct{ raw, want string }{
		{`post: Post "http://127.0.0.1:1/api/public/ingestion": dial tcp 127.0.0.1:1: connect: connection refused`, "Nothing is listening at 127.0.0.1:1."},
		{`status 401 Unauthorized`, "Langfuse refused the credentials (HTTP 401)."},
		{`status 404 Not Found`, "Nothing at that address answers this API (HTTP 404). Check the URL."},
		{`openai: HTTP 503: upstream down`, "Langfuse had an error (HTTP 503)."},
		{`speech: provider returned 429: slow down`, "Langfuse is limiting requests (HTTP 429). Try again shortly."},
		{`post: Post "https://lf.nowhere.invalid/x": dial tcp: lookup lf.nowhere.invalid: no such host`, "The name in lf.nowhere.invalid doesn't resolve."},
		{`openai: HTTP: Post "https://slow.example/v1/embeddings": context deadline exceeded`, "slow.example didn't answer in time."},
		{`exit status 1: FIRECRAWL_API_KEY is not set`, "The command exited with status 1."},
		{`exec: "uvx": executable file not found in $PATH`, "The command isn't on the server's PATH."},
		{`no langfuse config saved yet`, "Nothing is saved yet. Save the settings first."},
		{`something odd`, ""},
	} {
		if got := failureReason(tc.raw, "Langfuse"); got != tc.want {
			t.Errorf("failureReason(%q) = %q, want %q", tc.raw, got, tc.want)
		}
	}
	f := testFailed(12, `status 401 Unauthorized`, "Langfuse")
	if f.OK || f.Message != "Test failed after 12 ms. Langfuse refused the credentials (HTTP 401)." || f.Detail != "status 401 Unauthorized" {
		t.Errorf("testFailed = %+v", f)
	}
	if f := connectFailed("weird"); f.Message != "Couldn't connect." || f.Detail != "weird" {
		t.Errorf("connectFailed = %+v", f)
	}
}

// A failed test shows the plain line and the service's error under it.
func TestSetbFailureLines_Render(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	host := "http://127.0.0.1:1"
	pub, sec := "pk", "sk"
	if _, err := e.h.langfuse.UpdateLangfuseConfig(e.ctx, connect.NewRequest(&psmithv1.UpdateLangfuseConfigRequest{Host: &host, PublicKey: &pub, SecretKey: &sec})); err != nil {
		t.Fatal(err)
	}
	body := e.shown(t, e.post(e.h.handleLangfuseTest, "/settings/langfuse/test", nil, url.Values{}))
	for _, want := range []string{"Nothing is listening at 127.0.0.1:1.", `class="sb-rdetail"`, "connection refused"} {
		if !strings.Contains(body, want) {
			t.Errorf("Langfuse failure missing %q", want)
		}
	}

	rec := e.post(e.h.handleMCPServerSave, "/", nil, url.Values{"name": {"Dead"}, "transport": {"http"}, "url": {"http://127.0.0.1:1/mcp"}})
	id := strings.TrimPrefix(rec.Header().Get("Location"), "/settings/mcp-servers/")
	body = wantStatus(t, e.get(e.h.handleMCPServerDetail, "/", map[string]string{"id": id}), http.StatusOK)
	for _, want := range []string{"Couldn&#39;t connect. Nothing is listening at 127.0.0.1:1.", `class="sb-rdetail"`} {
		if !strings.Contains(body, want) {
			t.Errorf("MCP failure missing %q", want)
		}
	}
}

// Send traces can't be turned on until both keys exist, and Send test
// trace waits for a saved secret, as on the apps.
func TestSetbLangfuse_SwitchLockedUntilKeys(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	body := wantStatus(t, e.get(e.h.handleLangfuse, "/settings/langfuse", nil), http.StatusOK)
	if !strings.Contains(body, `data-switch="enabled" disabled`) || !strings.Contains(body, "Needs a public key and a secret key.") {
		t.Error("switch not locked with nothing saved")
	}
	if !strings.Contains(body, `formaction="/settings/langfuse/test" formnovalidate data-needs-saved disabled`) || !strings.Contains(body, "Save both keys to send a test trace.") {
		t.Error("test not held back with nothing saved")
	}
	pub, sec := "pk", "sk"
	if _, err := e.h.langfuse.UpdateLangfuseConfig(e.ctx, connect.NewRequest(&psmithv1.UpdateLangfuseConfigRequest{PublicKey: &pub, SecretKey: &sec})); err != nil {
		t.Fatal(err)
	}
	body = wantStatus(t, e.get(e.h.handleLangfuse, "/settings/langfuse", nil), http.StatusOK)
	if strings.Contains(body, `data-switch="enabled" disabled`) || strings.Contains(body, "data-needs-saved disabled") {
		t.Error("still locked with both keys saved")
	}
}

// Clear on a stored header or environment removes it when the form saves;
// something typed replaces it; leaving both alone keeps it.
func TestSetbMCP_ClearStoredSecrets(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	head, env := "Authorization: x", "KEY=v"
	resp, err := e.prof.UpsertMCPServer(e.ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{Name: "Web", Transport: "http", Url: "http://127.0.0.1:1/mcp", Headers: &head}))
	if err != nil {
		t.Fatal(err)
	}
	id := resp.Msg.GetServer().GetId()
	body := wantStatus(t, e.get(e.h.handleMCPServerEdit, "/", map[string]string{"id": id}), http.StatusOK)
	if !strings.Contains(body, `name="clear_headers" value="true"`) || strings.Contains(body, `name="clear_env"`) {
		t.Error("edit form should offer Clear for the stored headers only")
	}
	stored := func() *psmithv1.MCPServer {
		servers, _ := e.h.listMCPServers(e.ctx)
		for _, s := range servers {
			if s.GetId() == id {
				return s
			}
		}
		t.Fatal("server gone")
		return nil
	}
	form := url.Values{"id": {id}, "name": {"Web"}, "transport": {"http"}, "url": {"http://127.0.0.1:1/mcp"}}
	wantStatus(t, e.post(e.h.handleMCPServerSave, "/", nil, form), http.StatusSeeOther)
	if !stored().GetHasHeaders() {
		t.Fatal("a save without Clear dropped the headers")
	}
	form.Set("clear_headers", "true")
	wantStatus(t, e.post(e.h.handleMCPServerSave, "/", nil, form), http.StatusSeeOther)
	if stored().GetHasHeaders() {
		t.Fatal("Clear left the headers stored")
	}

	resp, err = e.prof.UpsertMCPServer(e.ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{Name: "Cmd", Transport: "stdio", Command: "npx", Env: &env}))
	if err != nil {
		t.Fatal(err)
	}
	id = resp.Msg.GetServer().GetId()
	form = url.Values{"id": {id}, "name": {"Cmd"}, "transport": {"stdio"}, "command": {"npx"}, "clear_env": {"true"}, "env": {"NEW=1"}}
	wantStatus(t, e.post(e.h.handleMCPServerSave, "/", nil, form), http.StatusSeeOther)
	if !stored().GetHasEnv() {
		t.Fatal("typing a new environment with Clear on should replace it, not clear it")
	}
	form.Del("env")
	wantStatus(t, e.post(e.h.handleMCPServerSave, "/", nil, form), http.StatusSeeOther)
	if stored().GetHasEnv() {
		t.Fatal("Clear left the environment stored")
	}
}

// The order the arrows set is the order saved, with script (positions in
// the form) and without (the arrow posts and saves at once).
func TestSetbPlugins_Reorder(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	id := e.profile(t, "Demo", "")
	set := func(names ...string) {
		var pl []*psmithv1.ProfilePlugin
		for _, n := range names {
			pl = append(pl, &psmithv1.ProfilePlugin{PluginName: n, Config: []byte("{}")})
		}
		if _, err := e.prof.SetProfilePlugins(e.ctx, connect.NewRequest(&psmithv1.SetProfilePluginsRequest{ProfileId: id, Plugins: numbered(pl)})); err != nil {
			t.Fatal(err)
		}
	}
	order := func() string {
		var out []string
		for _, p := range e.h.profilePlugins(e.ctx, id) {
			out = append(out, p.GetPluginName())
		}
		return strings.Join(out, ",")
	}
	set("brave_search", "memory", "context_packs")
	body := wantStatus(t, e.get(e.h.handlePluginsPage, "/", map[string]string{"id": id}), http.StatusOK)
	if !strings.Contains(body, `aria-label="Move Brave Search up" disabled`) || !strings.Contains(body, `aria-label="Move Context Packs down" disabled`) || strings.Contains(body, `aria-label="Move Memory up" disabled`) {
		t.Error("the arrows at the ends should be off, the rest on")
	}

	tab := url.Values{"pname_0": {"brave_search"}, "pname_1": {"memory"}, "pname_2": {"context_packs"}, "ppos_0": {"2"}, "ppos_1": {"0"}, "ppos_2": {"1"}}
	wantStatus(t, e.post(e.h.handlePluginsSave, "/", map[string]string{"id": id}, tab), http.StatusSeeOther)
	if got := order(); got != "memory,context_packs,brave_search" {
		t.Fatalf("saved with positions: %s, want memory,context_packs,brave_search", got)
	}

	tab = url.Values{"pname_0": {"memory"}, "pname_1": {"context_packs"}, "pname_2": {"brave_search"}, "move": {"up:brave_search"}}
	wantStatus(t, e.post(e.h.handlePluginMove, "/", map[string]string{"id": id}, tab), http.StatusSeeOther)
	if got := order(); got != "memory,brave_search,context_packs" {
		t.Fatalf("after moving Brave Search up: %s, want memory,brave_search,context_packs", got)
	}
	wantStatus(t, e.post(e.h.handlePluginMove, "/", map[string]string{"id": id}, url.Values{"move": {"up:memory"}}), http.StatusSeeOther)
	if got := order(); got != "memory,brave_search,context_packs" {
		t.Fatalf("moving the first up changed the order: %s", got)
	}
	wantStatus(t, e.post(e.h.handlePluginMove, "/", map[string]string{"id": id}, url.Values{"move": {"down:memory"}}), http.StatusSeeOther)
	if got := order(); got != "brave_search,memory,context_packs" {
		t.Fatalf("after moving Memory down: %s, want brave_search,memory,context_packs", got)
	}
}

// "Needs an API key in Plugins" links to the plugin's shared settings,
// where the key is set, as the Mac's Open in Plugins does.
func TestSetbPlugins_NeedsKeyLinks(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	id := e.profile(t, "Demo", "")
	if _, err := e.prof.SetProfilePlugins(e.ctx, connect.NewRequest(&psmithv1.SetProfilePluginsRequest{ProfileId: id, Plugins: []*psmithv1.ProfilePlugin{{PluginName: "brave_search", Config: []byte("{}")}}})); err != nil {
		t.Fatal(err)
	}
	body := wantStatus(t, e.get(e.h.handlePluginsPage, "/", map[string]string{"id": id}), http.StatusOK)
	if !strings.Contains(body, `<a class="sb-taglink warn" href="/settings/plugins/brave_search">Needs an API key in Plugins`) {
		t.Error("the needs-a-key tag isn't a link to Brave Search's settings")
	}
}
