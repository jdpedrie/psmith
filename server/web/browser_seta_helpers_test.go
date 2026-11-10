package web

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/chromedp/cdproto/input"
	"github.com/chromedp/chromedp"

	"github.com/jdpedrie/psmith/server/store"
)

// Helpers for the settings-a browser tests: General, Appearance, Usage,
// providers and models, users.

// newSetaBrowser is newBrowserEnv with the signed-in user made an admin, so
// Users and the catalog refresh are reachable.
func newSetaBrowser(t *testing.T) (*browserEnv, string) {
	t.Helper()
	e := newBrowserEnv(t)
	u, err := e.q.GetUserByUsername(context.Background(), t.Name())
	if err != nil {
		t.Fatalf("GetUserByUsername: %v", err)
	}
	if err := e.q.UpdateUserIsAdmin(context.Background(), store.UpdateUserIsAdminParams{ID: u.ID, IsAdmin: true}); err != nil {
		t.Fatalf("UpdateUserIsAdmin: %v", err)
	}
	return e, u.ID.String()
}

// setaShot saves the page as <out>/<name>.png.
func (e *browserEnv) setaShot(t *testing.T, name string) {
	t.Helper()
	var b []byte
	if err := chromedp.Run(e.ctx, chromedp.FullScreenshot(&b, 90)); err != nil {
		t.Fatalf("screenshot: %v", err)
	}
	_ = os.WriteFile(filepath.Join(e.out, name+".png"), b, 0o644)
}

// setaClick presses the element as a mouse does, at its center.
func (e *browserEnv) setaClick(t *testing.T, sel string) {
	t.Helper()
	if err := chromedp.Run(e.ctx, chromedp.WaitVisible(sel, chromedp.ByQuery), chromedp.Click(sel, chromedp.ByQuery)); err != nil {
		t.Fatalf("click %s: %v", sel, err)
	}
}

// setaType focuses a field by clicking it, clears it and types text key by key.
func (e *browserEnv) setaType(t *testing.T, sel, text string) {
	t.Helper()
	if err := chromedp.Run(e.ctx,
		chromedp.WaitVisible(sel, chromedp.ByQuery),
		chromedp.Click(sel, chromedp.ByQuery),
		chromedp.Evaluate(`(() => { const el = document.querySelector(`+setaJS(sel)+`); el.select && el.select(); })()`, nil),
		chromedp.SendKeys(sel, text, chromedp.ByQuery),
	); err != nil {
		t.Fatalf("type into %s: %v", sel, err)
	}
}

// setaWaitPath waits for the page to land on path (no query).
func (e *browserEnv) setaWaitPath(t *testing.T, path string) {
	t.Helper()
	waitUntil(t, e, "navigate to "+path, `location.pathname === `+setaJS(path)+` && document.readyState === "complete"`, 10*time.Second)
}

// setaWatch samples a page expression every 150ms for d and returns each value.
func (e *browserEnv) setaWatch(t *testing.T, js string, d time.Duration) []string {
	t.Helper()
	var out []string
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		var v string
		if err := chromedp.Run(e.ctx, chromedp.Evaluate(js, &v)); err == nil {
			out = append(out, v)
		}
		time.Sleep(150 * time.Millisecond)
	}
	return out
}

func setaJS(s string) string {
	b := []byte{'"'}
	for _, r := range s {
		switch r {
		case '"', '\\':
			b = append(b, '\\', byte(r))
		default:
			b = append(b, string(r)...)
		}
	}
	return string(append(b, '"'))
}

// setaCmd is the modifier app.js reads as Command.
func setaCmd() input.Modifier { return input.ModifierMeta }

// setaCmdEnter presses ⌘↵ as a browser delivers it: one key-down the page can
// cancel. chromedp's KeyEvent also sends the character, which a text field
// turns into a second, implicit submit.
func setaCmdEnter() chromedp.Action {
	return chromedp.ActionFunc(func(ctx context.Context) error {
		if err := input.DispatchKeyEvent(input.KeyRawDown).WithKey("Enter").WithCode("Enter").WithWindowsVirtualKeyCode(13).WithModifiers(setaCmd()).Do(ctx); err != nil {
			return err
		}
		return input.DispatchKeyEvent(input.KeyUp).WithKey("Enter").WithCode("Enter").WithWindowsVirtualKeyCode(13).WithModifiers(setaCmd()).Do(ctx)
	})
}

// setaCmdS presses ⌘S as a single key-down, as setaCmdEnter does.
func setaCmdS() chromedp.Action {
	return chromedp.ActionFunc(func(ctx context.Context) error {
		if err := input.DispatchKeyEvent(input.KeyRawDown).WithKey("s").WithCode("KeyS").WithWindowsVirtualKeyCode(83).WithModifiers(setaCmd()).Do(ctx); err != nil {
			return err
		}
		return input.DispatchKeyEvent(input.KeyUp).WithKey("s").WithCode("KeyS").WithWindowsVirtualKeyCode(83).WithModifiers(setaCmd()).Do(ctx)
	})
}

// setaEnter presses Return as one key-down, so a field's own handler sees it
// without chromedp's extra character event submitting the form.
func setaEnter() chromedp.Action {
	return chromedp.ActionFunc(func(ctx context.Context) error {
		if err := input.DispatchKeyEvent(input.KeyRawDown).WithKey("Enter").WithCode("Enter").WithWindowsVirtualKeyCode(13).Do(ctx); err != nil {
			return err
		}
		return input.DispatchKeyEvent(input.KeyUp).WithKey("Enter").WithCode("Enter").WithWindowsVirtualKeyCode(13).Do(ctx)
	})
}
