package web

import (
	"testing"
	"time"
)

// Revert puts a switch back: the bar hides and the switch reads as loaded.
func TestBrowser_SetbRevertRestoresSwitches(t *testing.T) {
	e := newSetbBrowser(t)
	id := e.setbProfile(t, "Pirate", "")
	e.open(t, "/settings/profiles/"+id)
	e.setbClick(t, `[data-switch="favorite"]`)
	waitUntil(t, e.browserEnv, "bar shows", `!document.querySelector('[data-savebar]').hidden`, 3*time.Second)
	e.setbClick(t, `[data-savebar] button[type=reset]`)
	time.Sleep(300 * time.Millisecond)
	got := eval[string](t, e.browserEnv, `document.querySelector('[data-switch="favorite"]').getAttribute('aria-checked') + ' ' + document.querySelector('input[name=favorite]').value + ' bar=' + document.querySelector('[data-savebar]').hidden`)
	if got != "false false bar=true" {
		t.Fatalf("after Revert: switch, field, bar hidden = %q, want \"false false bar=true\"", got)
	}
}

// A create the server refuses shows the form again, in the shell, with the
// reason and everything typed still there.
func TestBrowser_SetbCreateProfileErrorKeepsTheForm(t *testing.T) {
	e := newSetbBrowser(t)
	e.open(t, "/settings/profiles/new")
	e.setbTypeInto(t, "#prname", "Template")
	e.setbTypeInto(t, "#prsystem", "Be brief.")
	e.setbClick(t, `[data-switch="default"]`)
	e.setbClick(t, `[data-switch="parent_only"]`)
	e.setbClick(t, `[data-setb-submitbar] button[type=submit]`)
	waitUntil(t, e.browserEnv, "page back", `document.readyState === "complete" && !!document.body`, 5*time.Second)
	time.Sleep(300 * time.Millisecond)
	got := eval[string](t, e.browserEnv, `(() => {
		const a = document.querySelector('[role=alert].result');
		const n = document.querySelector('#prname'), s = document.querySelector('#prsystem');
		return (a ? a.innerText : 'no alert') + '|' + (n ? n.value : 'no name') + '|' + (s ? s.value : 'no prompt') + '|' + !!document.querySelector('.settings nav, .snav');
	})()`)
	if got != "A parent-only profile can't be the default.|Template|Be brief.|true" {
		t.Fatalf("after a refused create: %q", got)
	}
}

// Default and Parent only together are refused, and the page afterwards
// shows what is really stored and what was typed: no half-saved profile
// behind switches that read otherwise.
func TestBrowser_SetbRefusedEditShowsTheTruth(t *testing.T) {
	e := newSetbBrowser(t)
	id := e.setbProfile(t, "Pirate", "")
	e.open(t, "/settings/profiles/"+id)
	e.setbClick(t, `[data-switch="favorite"]`)
	e.setbClick(t, `[data-switch="default"]`)
	e.setbClick(t, `[data-switch="parent_only"]`)
	e.setbClick(t, `[data-savebar] button[type=submit]`)
	waitUntil(t, e.browserEnv, "error", `!!document.querySelector('[role=alert].result')`, 5*time.Second)
	p := e.setbLoad(t, id)
	if p.GetParentOnly() || p.GetIsDefault() || p.GetFavorite() {
		t.Errorf("a refused save wrote part of itself: parent_only=%v default=%v favorite=%v", p.GetParentOnly(), p.GetIsDefault(), p.GetFavorite())
	}
	got := eval[string](t, e.browserEnv, `['favorite','default','parent_only'].map(n => document.querySelector('[data-switch="'+n+'"]').getAttribute('aria-checked')).join(' ') + ' bar=' + !document.querySelector('[data-savebar]').hidden`)
	if got != "true true true bar=true" {
		t.Errorf("after the refusal, favorite default parent_only switches = %q, want what was typed with the save bar up", got)
	}
}
