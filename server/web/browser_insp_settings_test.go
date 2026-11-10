package web

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/cdproto/input"
	"github.com/chromedp/chromedp"
	"github.com/google/uuid"
	"google.golang.org/protobuf/encoding/protojson"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// inspConvSettings reads the conversation's own settings from the database.
func (e *browserEnv) inspConvSettings(t *testing.T) *psmithv1.ConversationSettings {
	t.Helper()
	conv, err := e.q.GetConversationByID(context.Background(), uuid.MustParse(e.convID))
	if err != nil {
		t.Fatal(err)
	}
	out := &psmithv1.ConversationSettings{}
	if len(conv.Settings) > 0 {
		if err := (protojson.UnmarshalOptions{DiscardUnknown: true}).Unmarshal(conv.Settings, out); err != nil {
			t.Fatalf("settings %s: %v", conv.Settings, err)
		}
	}
	return out
}

// The Settings tab: typing a value marks the row set and unsaved and shows
// the save bar; Save writes it; the reset button clears it back to
// inherited; Revert puts back what loaded.
func TestBrowser_InspSettingsEditSaveResetRevert(t *testing.T) {
	e := newBrowserEnv(t)
	page := "/c/" + e.convID + "?tab=settings"
	e.open(t, page)
	waitUntil(t, e, "settings tab", `!!document.getElementById('cs-temperature')`, 3*time.Second)
	if !eval[bool](t, e, `document.querySelector('#insp-settings [data-savebar]').hidden`) {
		t.Fatal("the save bar shows before anything changed")
	}

	e.keys(t, chromedp.Click(`#cs-temperature`, chromedp.ByID), chromedp.SendKeys(`#cs-temperature`, "0.4", chromedp.ByID))
	waitUntil(t, e, "save bar", `!document.querySelector('#insp-settings [data-savebar]').hidden`, 2*time.Second)
	if got := inspText(t, e, "#insp-settings [data-dirty-count]"); got != "1 unsaved change" {
		t.Errorf("save bar says %q", got)
	}
	row := `document.getElementById('cs-temperature').closest('[data-set-row]')`
	if sub := eval[string](t, e, row+`.querySelector('.set-lbl > span').innerText`); !strings.HasPrefix(sub, "Set here, unsaved") {
		t.Errorf("the row's line reads %q while unsaved", sub)
	}
	e.inspShot(t, "dirty")

	// Scrolled to the end, the last row clears the save bar floating over it.
	clear := eval[bool](t, e, `(() => {
		const f = document.getElementById('insp-settings');
		f.scrollTop = f.scrollHeight;
		const rows = f.querySelectorAll('[data-set-row]');
		const last = rows[rows.length - 1].getBoundingClientRect();
		const bar = f.querySelector('[data-savebar] > div').getBoundingClientRect();
		return last.bottom <= bar.top;
	})()`)
	e.inspShot(t, "dirty-scrolled")
	if !clear {
		t.Error("the save bar covers the last setting even scrolled to the end")
	}

	// Revert puts the loaded value back and hides the bar.
	e.inspClick(t, "#insp-settings [data-savebar] button[type=reset]")
	waitUntil(t, e, "reverted", `document.getElementById('cs-temperature').value === '' && document.querySelector('#insp-settings [data-savebar]').hidden`, 2*time.Second)
	if sub := eval[string](t, e, row+`.querySelector('.set-lbl > span').innerText`); strings.HasPrefix(sub, "Set here") {
		t.Errorf("after Revert the row still reads %q", sub)
	}

	// Type again and save with ⌘S.
	e.keys(t, chromedp.Click(`#cs-temperature`, chromedp.ByID), chromedp.SendKeys(`#cs-temperature`, "0.4", chromedp.ByID),
		chromedp.KeyEvent("s", chromedp.KeyModifiers(input.ModifierMeta)))
	waitUntil(t, e, "saved", `document.readyState === 'complete' && document.getElementById('cs-temperature') && document.getElementById('cs-temperature').value === '0.4' && document.querySelector('#insp-settings [data-savebar]').hidden`, 5*time.Second)
	if got := e.inspConvSettings(t).GetCallSettings().Temperature; got == nil || *got != 0.4 {
		t.Fatalf("temperature in the database = %v, want 0.4", got)
	}
	if sub := eval[string](t, e, row+`.querySelector('.set-lbl > span').innerText`); !strings.HasPrefix(sub, "Set here") || strings.Contains(sub, "unsaved") {
		t.Errorf("after saving the row reads %q", sub)
	}

	// Reset clears the field to inherited; saving clears it in the database.
	e.inspClick(t, `#cs-temperature ~ .set-reset`)
	waitUntil(t, e, "reset", `document.getElementById('cs-temperature').value === '' && !document.querySelector('#insp-settings [data-savebar]').hidden`, 2*time.Second)
	e.inspClick(t, "#insp-settings [data-savebar] button[type=submit]")
	waitUntil(t, e, "saved reset", `document.readyState === 'complete' && !!document.getElementById('cs-temperature') && document.querySelector('#insp-settings [data-savebar]').hidden`, 5*time.Second)
	if got := e.inspConvSettings(t).GetCallSettings().Temperature; got != nil {
		t.Errorf("temperature after reset and save = %v, want inherited (unset)", *got)
	}
}
