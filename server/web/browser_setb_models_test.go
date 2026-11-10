package web

import (
	"testing"
	"time"
)

// A temperature out of range is refused, and the page comes back with
// everything typed, the bad value included, so it can be fixed in place.
func TestBrowser_SetbModelsRefusedSaveKeepsWhatWasTyped(t *testing.T) {
	e := newSetbBrowser(t)
	id := e.setbProfile(t, "Pirate", "")
	e.open(t, "/settings/profiles/"+id+"/models")
	e.setbTypeInto(t, "#pmtemp", "3")
	e.setbTypeInto(t, "#pmmax", "2048")
	e.setbTypeInto(t, "#pmcguide", "Keep names.")
	e.setbClick(t, `label:has(input[name=compression_mode][value=APPEND])`)
	eval[bool](t, e.browserEnv, `(() => { const s = document.querySelector('#pmeffort'); s.value = 'high'; s.dispatchEvent(new Event('change', {bubbles:true})); return true })()`)
	e.setbClick(t, `[data-savebar] button[type=submit]`)
	waitUntil(t, e.browserEnv, "error", `!!document.querySelector('[role=alert].result')`, 5*time.Second)
	got := eval[string](t, e.browserEnv, `[document.querySelector('#pmtemp').value, document.querySelector('#pmmax').value, document.querySelector('#pmcguide').value, document.querySelector('[name=compression_mode]:checked').value, document.querySelector('#pmeffort').value, !document.querySelector('[data-savebar]').hidden].join('|')`)
	if got != "3|2048|Keep names.|APPEND|high|true" {
		t.Fatalf("after a refused save: temp|max|guide|mode|effort|bar = %q", got)
	}
}
