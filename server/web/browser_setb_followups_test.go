package web

import (
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// setbFocus puts keyboard focus on sel, as Tab would land there.
func (e *setbBrowser) setbFocus(t *testing.T, sel string) {
	t.Helper()
	if !eval[bool](t, e.browserEnv, `(() => { const el = document.querySelector(`+setbJS(sel)+`); if (!el) return false; el.focus(); return document.activeElement === el })()`) {
		t.Fatalf("can't focus %s", sel)
	}
}

// setbPluginNames is the saved pipeline's plugin names, in order.
func (e *setbBrowser) setbPluginNames(t *testing.T, id string) []string {
	t.Helper()
	r, err := e.prof.GetProfilePlugins(e.uctx, connect.NewRequest(&psmithv1.GetProfilePluginsRequest{ProfileId: id}))
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, p := range r.Msg.GetPlugins() {
		out = append(out, p.GetPluginName())
	}
	return out
}

// rowOrder is the attached plugins as the page shows them: number, name.
func (e *setbBrowser) setbRowOrder(t *testing.T) string {
	t.Helper()
	return eval[string](t, e.browserEnv, `Array.from(document.querySelectorAll('[data-setb-row]')).map(r => r.querySelector('.sb-num').textContent + ' ' + r.querySelector('.sb-plbody .t').textContent).join(', ')`)
}

func (e *setbBrowser) setbAttach(t *testing.T, profileID string, names ...string) {
	t.Helper()
	var pl []*psmithv1.ProfilePlugin
	for _, n := range names {
		pl = append(pl, &psmithv1.ProfilePlugin{PluginName: n, Config: []byte("{}")})
	}
	if _, err := e.prof.SetProfilePlugins(e.uctx, connect.NewRequest(&psmithv1.SetProfilePluginsRequest{ProfileId: profileID, Plugins: numbered(pl)})); err != nil {
		t.Fatal(err)
	}
}

// The Mac drags plugins into order. Here the arrows do it, from the
// keyboard: Enter on "Move down" moves the row, renumbers, keeps focus
// with the row, and the save bar commits the order. Revert puts it back.
func TestBrowser_SetbPluginReorderByKeyboard(t *testing.T) {
	e := newSetbBrowser(t)
	demo := e.setbProfile(t, "Demo", "")
	e.setbAttach(t, demo, "brave_search", "memory", "context_packs")
	e.open(t, "/settings/profiles/"+demo+"/plugins")

	e.setbFocus(t, `[aria-label="Move Brave Search down"]`)
	e.keys(t, chromedp.KeyEvent(kb.Enter))
	if got := e.setbRowOrder(t); got != "1 Memory, 2 Brave Search, 3 Context Packs" {
		t.Fatalf("after one move down: %s", got)
	}
	if got := eval[string](t, e.browserEnv, `document.activeElement.getAttribute('aria-label')`); got != "Move Brave Search down" {
		t.Fatalf("focus went to %q, want it to stay on the moved row", got)
	}
	e.keys(t, chromedp.KeyEvent(kb.Enter))
	if got := e.setbRowOrder(t); got != "1 Memory, 2 Context Packs, 3 Brave Search" {
		t.Fatalf("after two moves down: %s", got)
	}
	// At the bottom Move down is off, so focus moves to Move up.
	if got := eval[string](t, e.browserEnv, `document.activeElement.getAttribute('aria-label') + ' ' + document.querySelector('[aria-label="Move Brave Search down"]').disabled`); got != "Move Brave Search up true" {
		t.Fatalf("at the bottom: focus and Move down disabled = %q", got)
	}
	if eval[bool](t, e.browserEnv, `document.querySelector('[data-savebar]').hidden`) {
		t.Fatal("the save bar didn't come up for a new order")
	}
	e.setbShot(t, "moved")

	e.setbClick(t, `[data-savebar] button[type=submit]`)
	e.setbWaitPath(t, "/settings/profiles/"+demo+"/plugins")
	waitUntil(t, e.browserEnv, "saved", `document.querySelector('[data-savebar]').hidden`, 5*time.Second)
	if got := strings.Join(e.setbPluginNames(t, demo), ","); got != "memory,context_packs,brave_search" {
		t.Fatalf("saved order: %s", got)
	}
	if got := e.setbRowOrder(t); got != "1 Memory, 2 Context Packs, 3 Brave Search" {
		t.Fatalf("page after save: %s", got)
	}

	e.setbClick(t, `[aria-label="Move Memory down"]`)
	e.setbClick(t, `[data-savebar] button[type=reset]`)
	time.Sleep(300 * time.Millisecond)
	if got := e.setbRowOrder(t); got != "1 Memory, 2 Context Packs, 3 Brave Search" {
		t.Fatalf("after Revert: %s", got)
	}
	got := eval[string](t, e.browserEnv, `document.querySelector('[data-savebar]').hidden + ' ' + document.querySelector('[aria-label="Move Memory up"]').disabled + ' ' + document.querySelector('[aria-label="Move Context Packs up"]').disabled`)
	if got != "true true false" {
		t.Fatalf("after Revert: bar hidden, first up off, second up on = %q", got)
	}
}

// "Needs an API key in Plugins" goes to where the key is set.
func TestBrowser_SetbNeedsKeyOpensPlugin(t *testing.T) {
	e := newSetbBrowser(t)
	demo := e.setbProfile(t, "Demo", "")
	e.setbAttach(t, demo, "brave_search")
	e.open(t, "/settings/profiles/"+demo+"/plugins")
	e.setbClick(t, `a.sb-taglink`)
	e.setbWaitPath(t, "/settings/plugins/brave_search")
	if !strings.Contains(e.setbText(t), "Shared settings") {
		t.Fatal("the link didn't land on Brave Search's shared settings")
	}
}

// Send traces can't be turned on with no keys. Typing both unlocks it,
// as on the apps, and the save turns tracing on.
func TestBrowser_SetbLangfuseSwitchWaitsForKeys(t *testing.T) {
	e := newSetbBrowser(t)
	e.open(t, "/settings/langfuse")
	sw := `[data-switch="enabled"]`
	state := func() string {
		return eval[string](t, e.browserEnv, `(() => { const s = document.querySelector('[data-switch="enabled"]'); return s.disabled + ' ' + s.getAttribute('aria-checked') + ' ' + document.querySelector('[data-lf-switch] .sb-sub.warn').hidden })()`)
	}
	if got := state(); got != "true false false" {
		t.Fatalf("with no keys: disabled, checked, note hidden = %q", got)
	}
	_ = chromedp.Run(e.ctx, chromedp.Click(sw, chromedp.ByQuery))
	if got := state(); got != "true false false" {
		t.Fatalf("a locked switch turned on: %q", got)
	}
	e.setbTypeInto(t, "#lfpk", "pk-lf-1")
	if got := state(); got != "true false false" {
		t.Fatalf("a public key alone unlocked it: %q", got)
	}
	e.setbTypeInto(t, "#lfsk", "sk-lf-1")
	if got := state(); got != "false false true" {
		t.Fatalf("both keys typed: %q, want unlocked with the note gone", got)
	}
	e.setbClick(t, sw)
	e.setbShot(t, "unlocked")
	e.setbClick(t, `[data-savebar] button[type=submit]`)
	waitUntil(t, e.browserEnv, "saved", `location.pathname === "/settings/langfuse" && document.readyState === "complete" && !!document.querySelector('[data-lf-switch]') && document.querySelector('[data-savebar]').hidden`, 10*time.Second)
	resp, err := e.lf.GetLangfuseConfig(e.uctx, connect.NewRequest(&psmithv1.GetLangfuseConfigRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	if c := resp.Msg.GetConfig(); !c.GetEnabled() || !c.GetSecretKeySet() || c.GetPublicKey() != "pk-lf-1" {
		t.Fatalf("saved %+v", c)
	}
}

// A refused save lands on a GET of the page, so a refresh doesn't post
// again, and the refresh still shows the error and what was typed.
func TestBrowser_SetbRefusedSaveSurvivesRefresh(t *testing.T) {
	e := newSetbBrowser(t)
	demo := e.setbProfile(t, "Demo", "")
	e.open(t, "/settings/profiles/"+demo)
	e.setbClearAndType(t, "#prname", " ")
	e.setbTypeInto(t, "#prdesc", "kept through a refresh")
	e.setbClick(t, `[data-savebar] button[type=submit]`)
	waitUntil(t, e.browserEnv, "refusal", `location.search.includes("shown=") && !!document.querySelector('[role=alert].result')`, 10*time.Second)
	check := func(when string) {
		got := eval[string](t, e.browserEnv, `document.querySelector('[role=alert].result').innerText + '|' + document.querySelector('#prdesc').value + '|' + document.querySelector('[data-savebar]').hidden`)
		if got != "A profile needs a name.|kept through a refresh|false" {
			t.Fatalf("%s: alert|description|bar hidden = %q", when, got)
		}
	}
	check("after the refusal")
	e.setbReload(t)
	check("after a refresh")
}

// A Test's result is a page of its own too, and a failure reads in plain
// words with the service's error beneath it.
func TestBrowser_SetbTestResultSurvivesRefresh(t *testing.T) {
	e := newSetbBrowser(t)
	e.setbLangfuse(t, "http://127.0.0.1:1")
	e.open(t, "/settings/langfuse")
	e.setbClick(t, `button[formaction="/settings/langfuse/test"]`)
	waitUntil(t, e.browserEnv, "result", `location.search.includes("shown=") && !!document.querySelector('[role=status].result')`, 15*time.Second)
	read := func() string {
		return eval[string](t, e.browserEnv, `(() => { const r = document.querySelector('[role=status].result'); return r.querySelector('.sb-rline').innerText + '|' + r.querySelector('.sb-rdetail').innerText })()`)
	}
	got := read()
	line, detail, _ := strings.Cut(got, "|")
	if !strings.HasPrefix(line, "Test failed") || !strings.HasSuffix(line, "Nothing is listening at 127.0.0.1:1.") || !strings.Contains(detail, "connection refused") {
		t.Fatalf("failure line %q", got)
	}
	e.setbShot(t, "failed")
	e.setbReload(t)
	if again := read(); again != got {
		t.Fatalf("after a refresh the result reads %q, was %q", again, got)
	}
}

// Clear on stored headers works from the keyboard, says what will happen,
// and the save removes them.
func TestBrowser_SetbClearMCPHeaders(t *testing.T) {
	e := newSetbBrowser(t)
	head := "Authorization: Bearer x"
	resp, err := e.prof.UpsertMCPServer(e.uctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{Name: "Linear", Transport: "http", Url: "http://127.0.0.1:1/mcp", Headers: &head}))
	if err != nil {
		t.Fatal(err)
	}
	id := resp.Msg.GetServer().GetId()
	e.open(t, "/settings/mcp-servers/"+id+"/edit")
	visible := func(sel string) bool {
		return eval[bool](t, e.browserEnv, `(() => { const el = document.querySelector(`+setbJS(sel)+`); return !!el && getComputedStyle(el).display !== 'none' })()`)
	}
	if visible(".sb-clearnote") || !visible(".sb-clearbtn .off") {
		t.Fatal("the note shows before Clear is pressed")
	}
	e.setbFocus(t, `input[name=clear_headers]`)
	e.keys(t, chromedp.KeyEvent(" "))
	if !visible(".sb-clearnote") || !visible(".sb-clearbtn .on") || visible(".sb-lock") {
		t.Fatal("Clear didn't say the headers go on save")
	}
	e.setbShot(t, "cleared")
	e.setbClick(t, `[data-setb-submitbar] button[type=submit]`)
	waitUntil(t, e.browserEnv, "saved", `location.pathname === "/settings/mcp-servers/`+id+`" && document.readyState === "complete"`, 15*time.Second)
	servers, err := e.prof.ListMCPServers(e.uctx, connect.NewRequest(&psmithv1.ListMCPServersRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range servers.Msg.GetServers() {
		if s.GetId() == id && s.GetHasHeaders() {
			t.Fatal("the headers are still stored after Clear and save")
		}
	}
}
