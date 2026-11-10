package web

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"

	"github.com/jdpedrie/psmith/fakellm"
)

// Compression and contexts, driven through the inspector and the composer's
// slot with real clicks: compress, watch the summary stream, review it,
// start the new context, then go back and make the old one active.
func TestBrowser_InspCompressThenReturnToOldContext(t *testing.T) {
	e := newBrowserEnv(t)
	first := e.inspActiveContext(t)
	e.inspSeedTurns(t, first,
		"How do tidepools form?", "Waves carve basins in the rock and the tide leaves water behind.",
		"Which animals live there?", "Anemones, barnacles and hermit crabs.")

	var evs []fakellm.Event
	for _, w := range strings.Fields("The reader asked about tidepools and the animals living in them, anemones barnacles and crabs.") {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: w + " ", Delay: 60 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs, Usage: &fakellm.Usage{InputTokens: 40, OutputTokens: 20}})

	e.open(t, "/c/"+e.convID)
	if !strings.Contains(inspText(t, e, "#messages"), "hermit crabs") {
		t.Fatal("the seeded transcript isn't on the page")
	}
	e.inspClick(t, "#inspector a.cmp-btn")
	inspWaitPath(t, e, "/c/"+e.convID+"/compact")
	waitUntil(t, e, "compress card", `!!document.querySelector('#composer-slot form.cmp')`, 3*time.Second)
	e.inspShot(t, "compress-card")
	e.inspClick(t, "#composer-slot form.cmp button[type=submit].primary")

	frames := e.record(t, []string{"Compressing", "Summary ready for review", "anemones barnacles"}, 15*time.Second, func(string) bool {
		return eval[bool](t, e, `!!document.querySelector('#composer-slot') && document.querySelector('#composer-slot').innerText.includes('Summary ready for review')`)
	})
	// The last frame's text can predate the reload done saw, so ask the page.
	if !frames[len(frames)-1].seen["Summary ready for review"] && !eval[bool](t, e, `!!document.querySelector('#composer-slot') && document.querySelector('#composer-slot').innerText.includes('Summary ready for review')`) {
		t.Fatalf("the review card never showed; timeline in %s", e.out)
	}
	e.inspShot(t, "review")
	e.inspClick(t, "#composer-slot form[action$='/promote'] button")
	waitUntil(t, e, "composer back", `!!document.getElementById('composer-text')`, 5*time.Second)
	second := e.inspActiveContext(t)
	if second == first {
		t.Fatal("promote didn't start a new context")
	}
	if strings.Contains(inspText(t, e, "#messages"), "hermit crabs") {
		t.Error("the new context's transcript shows the old context's turns")
	}
	e.inspShot(t, "context-2")

	// Context 1 from the inspector's list opens read-only.
	e.inspClick(t, "#inspector a.ctx[href*='/context/"+first.String()+"']")
	inspWaitPath(t, e, "/c/"+e.convID+"/context/"+first.String())
	if !strings.Contains(inspText(t, e, "#transcript"), "hermit crabs") {
		t.Errorf("the read-only page doesn't show Context 1's turns: %q", inspText(t, e, "#transcript"))
	}
	e.inspShot(t, "readonly")

	e.inspClick(t, "#composer-slot form[action$='/activate'] button")
	inspWaitPath(t, e, "/c/"+e.convID)
	if got := e.inspActiveContext(t); got != first {
		t.Fatalf("active context = %s, want Context 1 (%s)", got, first)
	}
	// The iOS report: activated, but the transcript stays empty. Watch it
	// for a few seconds, through whatever refresh the activation triggers.
	frames = e.record(t, []string{"hermit crabs"}, 3*time.Second, func(string) bool { return false })
	if g := gaps(frames, "hermit crabs", 0); len(g) > 0 {
		t.Errorf("Context 1's turns were missing after Make active in %v; timeline in %s", g, e.out)
	}
	if !strings.Contains(inspText(t, e, "#inspector"), "Context 1 · active") {
		t.Errorf("the inspector doesn't mark Context 1 active: %q", inspText(t, e, "#inspector .ctx-list"))
	}
	e.inspShot(t, "context-1-active")

	// Its summary already started Context 2, so it isn't up for review
	// again: the composer is back and Context 1 takes a send.
	if eval[bool](t, e, `!!document.querySelector('#composer-slot') && document.querySelector('#composer-slot').innerText.includes('Summary ready for review')`) {
		t.Fatal("Context 1 shows its used summary for review again")
	}
	e.convSendTurn(t, "Back in the first context", "Welcome back to the tide pools.")
	if got := e.inspActiveContext(t); got != first {
		t.Errorf("the send moved the active context to %s", got)
	}
}

// A compression the model fails shows the failed card in the composer's
// place, with the reason; Retry runs again and reaches the review.
func TestBrowser_InspCompressFailsThenRetries(t *testing.T) {
	e := newBrowserEnv(t)
	e.inspSeedTurns(t, e.inspActiveContext(t), "Question", "Answer")
	e.fake.Enqueue(fakellm.Script{Error: &fakellm.ErrorSpec{HTTPStatus: 529, Code: "overloaded_error", Message: "Overloaded"}})
	e.fake.Enqueue(fakellm.Script{Error: &fakellm.ErrorSpec{HTTPStatus: 529, Code: "overloaded_error", Message: "Overloaded"}})
	e.fake.Enqueue(fakellm.Script{Error: &fakellm.ErrorSpec{HTTPStatus: 529, Code: "overloaded_error", Message: "Overloaded"}})
	e.open(t, "/c/"+e.convID+"/compact")
	e.inspClick(t, "#composer-slot form.cmp button[type=submit].primary")
	waitUntil(t, e, "failed card", `!!document.querySelector('#composer-slot form.cmp.failed')`, 20*time.Second)
	e.inspShot(t, "failed")
	if got := inspText(t, e, "#composer-slot .card-err"); strings.TrimSpace(got) == "" {
		t.Error("the failed card doesn't say why")
	}
	if !eval[bool](t, e, `!!document.querySelector('#composer-slot form.cmp.failed select#cmp-model')`) {
		t.Error("the failed card offers no other model")
	}

	e.fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "A fine summary.", Delay: 50 * time.Millisecond}}})
	e.inspClick(t, "#composer-slot form.cmp.failed button[type=submit].primary")
	waitUntil(t, e, "review", `!!document.querySelector('#composer-slot') && document.querySelector('#composer-slot').innerText.includes('Summary ready for review')`, 20*time.Second)
	// One record of the attempt that counts: the failed summary is gone.
	if strings.Contains(inspText(t, e, "#messages"), "Overloaded") {
		t.Error("the failed attempt is still in the transcript after a successful retry")
	}
}

// Esc stops a compression mid-stream: the run ends early and what was
// written so far waits for review, as on the Mac.
func TestBrowser_InspCompressEscStops(t *testing.T) {
	e := newBrowserEnv(t)
	e.inspSeedTurns(t, e.inspActiveContext(t), "Question", "Answer")
	var evs []fakellm.Event
	for i := 0; i < 80; i++ {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: "summary ", Delay: 100 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs})
	e.open(t, "/c/"+e.convID+"/compact")
	e.inspClick(t, "#composer-slot form.cmp button[type=submit].primary")
	waitUntil(t, e, "streaming", `!!document.querySelector('#composer-slot [data-compact-stream]') && document.querySelector('#composer-slot .sum-box').innerText.includes('summary')`, 8*time.Second)
	e.keys(t, shortcut("Escape", "Escape"))
	waitUntil(t, e, "review", `!!document.querySelector('#composer-slot') && document.querySelector('#composer-slot').innerText.includes('Discard')`, 5*time.Second)
	if n := strings.Count(inspText(t, e, "#composer-slot .sum-box"), "summary"); n >= 80 {
		t.Errorf("the summary ran to the end (%d words) after Esc", n)
	}
	e.inspShot(t, "after-stop")

	// Discard gives the composer back.
	e.inspClick(t, "#composer-slot button.discard")
	waitUntil(t, e, "composer", `!!document.getElementById('composer-text')`, 5*time.Second)
	if got := inspText(t, e, "#inspector a.cmp-btn"); got != "Compress into a new context" {
		t.Errorf("the inspector's compress button reads %q after discarding", got)
	}
}

// The contexts manager: rename with Enter, Esc cancels a rename, and delete
// confirms in place (Cancel keeps it).
func TestBrowser_InspContextsRenameAndDelete(t *testing.T) {
	e := newBrowserEnv(t)
	first := e.inspActiveContext(t)
	e.inspSeedTurns(t, first, "Old question", "Old answer")
	e.inspNewContext(t)

	e.open(t, "/c/"+e.convID)
	e.inspClick(t, `#inspector a.sec-link`)
	inspWaitPath(t, e, "/c/"+e.convID+"?tab=contexts")
	e.inspClick(t, `#inspector a.ibtn[aria-label="Rename Context 1"]`)
	waitUntil(t, e, "rename field", `!!document.activeElement && document.activeElement.id === 'ctx-rename'`, 3*time.Second)
	if eval[bool](t, e, `!!document.getElementById('conv-title')`) {
		t.Error("renaming a context put the conversation's title into rename too")
	}
	e.keys(t, chromedp.SendKeys(`#ctx-rename`, "Tidepools", chromedp.ByID), chromedp.KeyEvent(kb.Enter))
	waitUntil(t, e, "renamed", `!document.getElementById('ctx-rename') && !!document.getElementById('inspector') && document.getElementById('inspector').innerText.includes('Tidepools')`, 5*time.Second)
	if cx, err := e.q.GetContextByID(context.Background(), first); err != nil || inspDeref(cx.Title) != "Tidepools" {
		t.Errorf("Context 1's title = %q (%v)", inspDeref(cx.Title), err)
	}

	// Esc leaves a rename without saving.
	e.inspClick(t, `#inspector a.ibtn[aria-label="Rename Context 1"]`)
	waitUntil(t, e, "rename field", `!!document.activeElement && document.activeElement.id === 'ctx-rename'`, 3*time.Second)
	e.keys(t, chromedp.SendKeys(`#ctx-rename`, " and crabs", chromedp.ByID), shortcut("Escape", "Escape"))
	waitUntil(t, e, "cancelled", `!document.getElementById('ctx-rename') && document.readyState === 'complete'`, 5*time.Second)
	if cx, _ := e.q.GetContextByID(context.Background(), first); inspDeref(cx.Title) != "Tidepools" {
		t.Errorf("Esc saved the rename: %q", inspDeref(cx.Title))
	}

	// Delete: confirm in place, Cancel, then Delete.
	e.inspClick(t, `#inspector a.ibtn[aria-label="Delete Context 1"]`)
	waitUntil(t, e, "confirm", `!!document.querySelector('#inspector .confirm')`, 3*time.Second)
	e.inspShot(t, "confirm")
	e.inspClick(t, `#inspector .confirm a.cbtn`)
	waitUntil(t, e, "kept", `document.readyState === 'complete' && !document.querySelector('#inspector .confirm')`, 3*time.Second)
	e.inspClick(t, `#inspector a.ibtn[aria-label="Delete Context 1"]`)
	e.inspClick(t, `#inspector .confirm button.del`)
	waitUntil(t, e, "deleted", `document.readyState === 'complete' && !document.querySelector('#inspector .confirm') && !document.getElementById('inspector').innerText.includes('Tidepools')`, 5*time.Second)
	if _, err := e.q.GetContextByID(context.Background(), first); err == nil {
		t.Error("Context 1 survived Delete")
	}
}
