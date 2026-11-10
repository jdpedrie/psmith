package web

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
)

// Settings-a pages driven with real clicks and keys in headless Chrome.

// The Usage range control sits on one line beside the title. The list's
// top-level .seg rule fixed every segmented control at 138px, so "Last 30
// days" wrapped to three lines and Custom hung off the control's edge.
func TestBrowserSeta_UsageRangeFitsOneLine(t *testing.T) {
	e, _ := newSetaBrowser(t)
	e.open(t, "/settings/usage")
	got := eval[string](t, e, `(() => {
		const seg = document.querySelector('.page-title .seg'), r = seg.getBoundingClientRect(), bad = [];
		for (const a of seg.children) {
			const b = a.getBoundingClientRect();
			if (b.height > r.height) bad.push(a.textContent + ' is ' + b.height + 'px tall');
			if (b.right > r.right + 0.5) bad.push(a.textContent + ' overflows the control');
		}
		const main = document.querySelector('.spage-inner').getBoundingClientRect();
		if (r.right > main.right + 0.5) bad.push('the control overflows the page');
		return bad.join('; ');
	})()`)
	if got != "" {
		e.setaShot(t, "usage")
		t.Errorf("range control: %s", got)
	}
}

// Test connection reports on the saved connection without throwing away what
// the user has typed and not saved yet. It used to submit the whole page and
// redirect, so a rename snapped back to the stored name.
func TestBrowserSeta_TestConnectionKeepsEdits(t *testing.T) {
	e, _ := newSetaBrowser(t)
	e.open(t, "/settings/providers/"+e.providerID)
	e.setaType(t, "#pname", "Renamed provider")
	waitUntil(t, e, "save bar", `!document.querySelector('[data-savebar]').hidden`, 3*time.Second)
	e.setaClick(t, `.ptacts button[formaction$="/test"]`)

	frames := e.setaWatch(t, `document.querySelector('#pname').value + '|' + document.querySelector('[data-savebar]').hidden + '|' + ((document.querySelector('.phead .result')||{}).textContent||'')`, 2500*time.Millisecond)
	sawResult := false
	for i, f := range frames {
		parts := strings.SplitN(f, "|", 3)
		if parts[0] != "Renamed provider" || parts[1] != "false" {
			t.Fatalf("frame %d: name %q, save bar hidden %s; the unsaved rename was lost", i, parts[0], parts[1])
		}
		if strings.Contains(parts[2], "Connection failed") {
			sawResult = true
		}
	}
	if !sawResult {
		t.Fatalf("the test's outcome never showed: last frame %q", frames[len(frames)-1])
	}
	p, err := e.q.GetUserModelProvider(context.Background(), uuid.MustParse(e.providerID))
	if err != nil {
		t.Fatal(err)
	}
	if p.Label != "test" {
		t.Errorf("testing saved the rename: label %q", p.Label)
	}

	e.keys(t, chromedp.KeyEvent("s", chromedp.KeyModifiers(setaCmd())))
	e.setaWaitPath(t, "/settings/providers/"+e.providerID)
	waitUntil(t, e, "saved", `document.querySelector('h2').textContent === 'Renamed provider' && document.querySelector('[data-savebar]').hidden`, 5*time.Second)
}

// Favorite and Test model on the model page keep unsaved edits too.
func TestBrowserSeta_ModelActionsKeepEdits(t *testing.T) {
	e, _ := newSetaBrowser(t)
	e.open(t, "/settings/providers/"+e.providerID+"/models/claude-fake")
	e.setaType(t, "#mctx", "123456")

	e.setaClick(t, "button.fav")
	waitUntil(t, e, "favorite on", `document.querySelector('button.fav').getAttribute('aria-pressed') === 'true'`, 5*time.Second)
	if v := eval[string](t, e, `document.querySelector('#mctx').value`); v != "123456" {
		t.Errorf("favorite threw away the context window edit: %q", v)
	}
	m, err := e.q.GetUserModel(context.Background(), store.GetUserModelParams{UserModelProviderID: uuid.MustParse(e.providerID), ModelID: "claude-fake"})
	if err != nil {
		t.Fatal(err)
	}
	if !m.Favorite {
		t.Error("favorite not stored")
	}
	if m.ContextWindow != nil {
		t.Error("favorite saved the unsaved context window")
	}

	e.setaClick(t, `.ptacts button[formaction*="/model-op/test/"]`)
	waitUntil(t, e, "test outcome", `/Test failed|Replied/.test((document.querySelector('.phead .result')||{}).textContent||'')`, 10*time.Second)
	if v := eval[string](t, e, `document.querySelector('#mctx').value`); v != "123456" {
		t.Errorf("Test model threw away the context window edit: %q", v)
	}
	if eval[bool](t, e, `document.querySelector('[data-savebar]').hidden`) {
		t.Error("the save bar closed with an edit still unsaved")
	}
}

// New user puts the cursor in Username.
func TestBrowserSeta_NewUserFocusesUsername(t *testing.T) {
	e, _ := newSetaBrowser(t)
	e.open(t, "/settings/users")
	e.setaClick(t, ".ptacts a")
	waitUntil(t, e, "form open", `!!document.querySelector('#newuser')`, 5*time.Second)
	waitUntil(t, e, "username focused", `document.activeElement && document.activeElement.name === 'username'`, 2*time.Second)
}

// A hand-added model turned off from the provider page stays as an off row,
// and adding it by hand again turns it back on with what was typed.
func TestBrowserSeta_ReaddOffManualModel(t *testing.T) {
	e, _ := newSetaBrowser(t)
	prov := "/settings/providers/" + e.providerID
	e.open(t, prov)
	e.setaClick(t, `#model-rows button.switch`)
	waitUntil(t, e, "row off", `document.querySelector('#model-rows button.switch').getAttribute('aria-checked') === 'false'`, 5*time.Second)

	e.open(t, prov+"/add-model")
	e.setaType(t, "#aid", "claude-fake")
	e.setaType(t, "#aname", "Fake again")
	e.keys(t, setaCmdEnter())
	e.setaWaitPath(t, prov+"/models/claude-fake")
	if v := eval[string](t, e, `document.querySelector('#mname').value`); v != "Fake again" {
		t.Errorf("display name %q", v)
	}
	e.open(t, prov)
	if got := eval[string](t, e, `document.querySelector('#model-rows').textContent`); !strings.Contains(got, "Fake again") {
		t.Errorf("the model isn't back on the provider page: %q", got)
	}
}

// At phone width nothing on General or Appearance runs past its group or
// card: the signed-in row's login, the Admin tag, the theme swatches.
func TestBrowserSeta_PhonePagesStayInside(t *testing.T) {
	e, _ := newSetaBrowser(t)
	if err := chromedp.Run(e.ctx, chromedp.EmulateViewport(390, 844)); err != nil {
		t.Fatal(err)
	}
	check := `(sel, box) => [...document.querySelectorAll(sel)].filter(el => {
		const b = el.getBoundingClientRect(), r = el.closest(box).getBoundingClientRect();
		return b.right > r.right + 0.5;
	}).map(el => el.className || el.tagName + ':' + el.textContent.trim())`
	e.open(t, "/settings/general")
	if got := eval[[]string](t, e, `(`+check+`)('.spage .who, .spage .who *, .spage .grow > .tag', '.group')`); len(got) > 0 {
		e.setaShot(t, "general")
		t.Errorf("General: past the group's edge: %v", got)
	}
	if w := eval[float64](t, e, `document.querySelector('.grow > .tag').getBoundingClientRect().width`); w > 100 {
		t.Errorf("General: the Admin tag stretches to %vpx", w)
	}
	e.open(t, "/settings/appearance")
	if got := eval[[]string](t, e, `(`+check+`)('.tcard .sw > span', '.tcard')`); len(got) > 0 {
		e.setaShot(t, "appearance")
		t.Errorf("Appearance: swatches past the card's edge: %v", got)
	}
}

// Turning a model off from the provider page keeps unsaved edits elsewhere on
// the page; the row turns off and the count updates in place. The model was
// added by hand, so its row stays, off.
func TestBrowserSeta_ModelSwitchKeepsEdits(t *testing.T) {
	e, _ := newSetaBrowser(t)
	e.open(t, "/settings/providers/"+e.providerID)
	e.setaType(t, "#pname", "Renamed provider")
	e.setaClick(t, `#model-rows button.switch`)
	frames := e.setaWatch(t, `document.querySelector('#pname').value + '|' + document.querySelectorAll('#model-rows tr').length + '|' + document.querySelector('#models').textContent + '|' + document.querySelector('#models-empty').hidden`, 2*time.Second)
	for i, f := range frames {
		if !strings.HasPrefix(f, "Renamed provider|") {
			t.Fatalf("frame %d: %q; the unsaved rename was lost", i, f)
		}
	}
	if last := frames[len(frames)-1]; last != "Renamed provider|1|Models · 0 on|true" {
		t.Errorf("after the switch: %q", last)
	}
	m, err := e.q.GetUserModel(context.Background(), store.GetUserModelParams{UserModelProviderID: uuid.MustParse(e.providerID), ModelID: "claude-fake"})
	if err != nil {
		t.Fatal(err)
	}
	if m.Enabled {
		t.Error("the model is still on")
	}
	if eval[bool](t, e, `document.querySelector('[data-savebar]').hidden`) {
		t.Error("the save bar closed with the rename unsaved")
	}
}

// Stop sequences: Return adds a chip and opens the save bar, ⌘S keeps it,
// removing it opens the bar again, and Revert puts the chip back and closes
// the bar. Revert used to leave the chip gone and the bar open, since a form
// reset can't bring back a removed element.
func TestBrowserSeta_StopSequencesRevert(t *testing.T) {
	e, _ := newSetaBrowser(t)
	d := "/settings/providers/" + e.providerID + "/defaults"
	state := `document.querySelectorAll('.stopchip').length + '|' + document.querySelector('[data-savebar]').hidden`
	e.open(t, d)
	e.setaType(t, "#stop", "END")
	e.keys(t, setaEnter())
	waitUntil(t, e, "chip added", state+` === '1|false'`, 3*time.Second)
	e.keys(t, setaCmdS())
	waitUntil(t, e, "saved", `document.readyState === 'complete' && `+state+` === '1|true'`, 5*time.Second)

	e.setaClick(t, `[data-stop-remove]`)
	waitUntil(t, e, "chip removed", state+` === '0|false'`, 3*time.Second)
	e.setaClick(t, `[data-savebar] button[type=reset]`)
	time.Sleep(300 * time.Millisecond)
	if got := eval[string](t, e, state); got != "1|true" {
		t.Fatalf("after Revert: chips|bar hidden = %s, want 1|true", got)
	}
	// The restored chip still works.
	e.setaClick(t, `[data-stop-remove]`)
	waitUntil(t, e, "restored chip removes", state+` === '0|false'`, 3*time.Second)
}

// Adding a provider whose host is down keeps it, opens its page, and says the
// connection failed there and on the list; nothing reports success.
func TestBrowserSeta_AddProviderDeadHost(t *testing.T) {
	e, _ := newSetaBrowser(t)
	e.open(t, "/settings/providers/new?t=custom")
	e.setaType(t, "#pname", "Dead box")
	e.setaType(t, "#purl", "http://127.0.0.1:1/v1")
	e.keys(t, setaCmdEnter())
	waitUntil(t, e, "provider page", `/^\/settings\/providers\/[0-9a-f-]{36}$/.test(location.pathname) && document.readyState === 'complete'`, 15*time.Second)
	if got := eval[string](t, e, `(document.querySelector('.phead .result')||{}).textContent||''`); !strings.Contains(got, "Connection failed") {
		t.Errorf("provider page result: %q", got)
	}
	e.open(t, "/settings/providers")
	if got := eval[string](t, e, `[...document.querySelectorAll('.prow')].map(r => r.textContent).join('|')`); !strings.Contains(got, "Dead box") || !strings.Contains(got, "Last test failed") {
		t.Errorf("providers list: %q", got)
	}
}
