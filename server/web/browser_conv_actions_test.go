package web

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	"github.com/jdpedrie/psmith/server/store"
)

// convSendTurn sends text from the composer and waits for the reply to
// finish and the transcript to settle on the stored rows.
func (e *browserEnv) convSendTurn(t *testing.T, text, reply string) {
	t.Helper()
	var evs []fakellm.Event
	for _, w := range strings.Fields(reply) {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: w + " ", Delay: 20 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs, Usage: &fakellm.Usage{InputTokens: 10, OutputTokens: 10}})
	eval[bool](t, e, convTimeline)
	if err := chromedp.Run(e.ctx,
		chromedp.WaitVisible(`#composer-text`, chromedp.ByID),
		chromedp.SendKeys(`#composer-text`, text, chromedp.ByID),
		chromedp.KeyEvent("\r"),
	); err != nil {
		t.Fatalf("send: %v", err)
	}
	last := strings.Fields(reply)
	cond := `!document.querySelector('article.reply.live') && document.querySelector('#messages').innerText.includes(` + jsStr(last[len(last)-1]) + `)`
	end := time.Now().Add(30 * time.Second)
	for !eval[bool](t, e, cond) {
		if time.Now().After(end) {
			t.Logf("timeline:\n%s", eval[string](t, e, `(window.__ctl || []).join('\n')`))
			t.Fatalf("the turn %q never settled (fake model got %d requests; stored: %s); %s", text, len(e.fake.Requests()), e.convDump(t), eval[string](t, e, `location.href + ' messages=' + (document.querySelector('#messages') ? document.querySelectorAll('#messages').length + ' ' + document.querySelector('#messages').innerText.slice(-400) : 'none') + ' | body: ' + document.body.innerText.slice(0, 600)`))
		}
		time.Sleep(100 * time.Millisecond)
	}
	time.Sleep(400 * time.Millisecond)
}

func jsStr(s string) string {
	return "'" + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), "'", `\'`) + "'"
}

// convRowID is the id of the first transcript row whose text contains needle.
func (e *browserEnv) convRowID(t *testing.T, needle string) string {
	t.Helper()
	id := eval[string](t, e, `(() => { const r = [...document.querySelectorAll('#messages [id^="m-"]')].find(x => x.innerText.includes(`+jsStr(needle)+`)); return r ? r.id.slice(2) : ''; })()`)
	if id == "" {
		t.Fatalf("no row containing %q", needle)
	}
	return id
}

// convAct clicks a control inside a row, as the page's script would.
func (e *browserEnv) convAct(t *testing.T, rowID, selector string) {
	t.Helper()
	ok := eval[bool](t, e, `(() => { const el = document.querySelector('#m-`+rowID+` `+selector+`'); if (!el) return false; el.click(); return true; })()`)
	if !ok {
		t.Fatalf("no %s in row %s", selector, rowID)
	}
}

func (e *browserEnv) convStored(t *testing.T, id string) (string, bool) {
	t.Helper()
	m, err := e.q.GetMessageByID(context.Background(), uuid.MustParse(id))
	if err != nil {
		return "", false
	}
	return m.Content, true
}

// The message actions swap a row for its editor or its delete strip and
// back. #messages declares hx-select and hx-swap for its own refresh, and
// they were inherited: Edit, Delete and each strip's Cancel picked
// #messages out of a response that doesn't contain it and swapped the
// message out for nothing, so it vanished until a reload.
func TestBrowser_EditAUserMessageInPlace(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	e.convSendTurn(t, "Where do sea stars keep their eyes", "At the tip of every arm.")
	id := e.convRowID(t, "sea stars")
	defer func() {
		if t.Failed() {
			t.Logf("timeline:\n%s", eval[string](t, e, `(window.__ctl || []).join('\n')`))
		}
	}()

	// Open and cancel: the message comes back as it was.
	e.convAct(t, id, `a[aria-label="Edit message"]`)
	waitUntil(t, e, "the editor opened", `!!document.querySelector('form.edit-form#m-`+id+` textarea')`, 5*time.Second)
	e.convAct(t, id, `.edit-bar a.btn-flat`)
	waitUntil(t, e, "Cancel put the message back", `(() => { const r = document.getElementById('m-`+id+`'); return !!r && !r.matches('form') && r.innerText.includes('sea stars'); })()`, 5*time.Second)

	// Open, change, save.
	e.convAct(t, id, `a[aria-label="Edit message"]`)
	waitUntil(t, e, "the editor opened again", `!!document.querySelector('form.edit-form#m-`+id+` textarea')`, 5*time.Second)
	eval[bool](t, e, `(() => { const ta = document.querySelector('#m-`+id+` textarea'); ta.value = 'Where do sea stars keep their tube feet'; return true; })()`)
	e.convAct(t, id, `button.btn-fill`)
	waitUntil(t, e, "the edit shows", `document.querySelector('#messages').innerText.includes('tube feet')`, 5*time.Second)
	if got, _ := e.convStored(t, id); got != "Where do sea stars keep their tube feet" {
		t.Errorf("stored content = %q", got)
	}
}

func TestBrowser_DeleteMessagesInPlace(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	e.convSendTurn(t, "Name a fish that walks", "The frogfish walks on its fins.")
	e.convSendTurn(t, "And one that climbs", "The mudskipper climbs mangrove roots.")
	user := e.convRowID(t, "that climbs")
	defer func() {
		if t.Failed() {
			t.Logf("timeline:\n%s", eval[string](t, e, `(window.__ctl || []).join('\n')`))
		}
	}()
	reply := e.convRowID(t, "frogfish")

	// The user's message: open, cancel, then delete.
	e.convAct(t, user, `a[aria-label="Delete message"]`)
	waitUntil(t, e, "the delete strip opened", `!!document.querySelector('form.del-confirm#m-`+user+`')`, 5*time.Second)
	e.convAct(t, user, `.dc-btns a.btn-flat`)
	waitUntil(t, e, "Cancel put the message back", `(() => { const r = document.getElementById('m-`+user+`'); return !!r && !r.matches('form') && r.innerText.includes('that climbs'); })()`, 5*time.Second)
	e.convAct(t, user, `a[aria-label="Delete message"]`)
	waitUntil(t, e, "the delete strip opened again", `!!document.querySelector('form.del-confirm#m-`+user+`')`, 5*time.Second)
	e.convAct(t, user, `button.btn-destructive`)
	waitUntil(t, e, "the message left the transcript", `!document.querySelector('#messages').innerText.includes('that climbs')`, 5*time.Second)
	if _, ok := e.convStored(t, user); ok {
		t.Error("the user's message is still stored")
	}

	// A reply, from its own actions.
	e.convAct(t, reply, `a[aria-label="Delete"]`)
	waitUntil(t, e, "the reply's delete strip opened", `!!document.querySelector('form.del-confirm#m-`+reply+`')`, 5*time.Second)
	e.convAct(t, reply, `button.btn-destructive`)
	waitUntil(t, e, "the reply left the transcript", `!document.querySelector('#messages').innerText.includes('frogfish')`, 5*time.Second)
	if _, ok := e.convStored(t, reply); ok {
		t.Error("the reply is still stored")
	}
	if !eval[bool](t, e, `document.querySelector('#messages').innerText.includes('mudskipper')`) {
		t.Error("deleting earlier messages took the later reply with them")
	}
}

// Delete from here (board MessageMenu): the menu offers it when messages
// follow, the strip says what goes, and the message and everything after
// it leave the server. The question before it stays.
func TestBrowser_DeleteFromHere(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	e.convSendTurn(t, "Name a fish that walks", "The frogfish walks on its fins.")
	e.convSendTurn(t, "And one that climbs", "The mudskipper climbs mangrove roots.")
	firstUser := e.convRowID(t, "fish that walks")
	reply := e.convRowID(t, "frogfish")
	laterUser := e.convRowID(t, "that climbs")
	lastReply := e.convRowID(t, "mudskipper")

	// The last reply has nothing after it, so its menu doesn't offer it.
	e.convAct(t, lastReply, `a[aria-label="More actions"]`)
	waitUntil(t, e, "the last reply's menu opened", `!!document.querySelector('#m-`+lastReply+` .msg-menu')`, 5*time.Second)
	if eval[bool](t, e, `document.querySelector('#m-`+lastReply+` .msg-menu').innerText.includes('Delete from here')`) {
		t.Error("the last reply offers Delete from here")
	}

	e.convAct(t, reply, `a[aria-label="More actions"]`)
	waitUntil(t, e, "the menu opened", `!!document.querySelector('#m-`+reply+` .msg-menu')`, 5*time.Second)
	ok := eval[bool](t, e, `(() => { const a = [...document.querySelectorAll('#m-`+reply+` .msg-menu a')].find(x => x.innerText.includes('Delete from here')); if (!a) return false; a.click(); return true; })()`)
	if !ok {
		t.Fatal("the menu has no Delete from here")
	}
	waitUntil(t, e, "the strip opened", `(() => { const f = document.querySelector('form.del-confirm#m-`+reply+`'); return !!f && f.innerText.includes('Delete from here?'); })()`, 5*time.Second)
	e.convAct(t, reply, `button.btn-destructive`)
	waitUntil(t, e, "the transcript dropped everything from the reply on", `(() => { const t = document.querySelector('#messages').innerText; return !t.includes('frogfish') && !t.includes('mudskipper') && t.includes('fish that walks'); })()`, 5*time.Second)
	for _, id := range []string{reply, laterUser, lastReply} {
		if _, ok := e.convStored(t, id); ok {
			t.Errorf("message %s is still stored", id)
		}
	}
	if _, ok := e.convStored(t, firstUser); !ok {
		t.Error("the question before it was deleted too")
	}
}

// Regenerate streams its reply like a send. The account event that the
// run started refreshes #messages, and the regenerate form's response was
// aimed at the #messages it started with: when the refresh landed first,
// the response (and its live row) went into a detached element, and the
// reply only appeared, whole, when the run's last event refreshed again.
func TestBrowser_RegenerateStreams(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	e.convSendTurn(t, "Why do octopuses change colour", "To hide, to warn and to talk.")
	for i := 0; i < 3; i++ {
		var evs []fakellm.Event
		for _, w := range strings.Fields("Chromatophores under the skin stretch and shrink as muscles pull on them, version " + string(rune('A'+i))) {
			evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: w + " ", Delay: 150 * time.Millisecond})
		}
		e.fake.Enqueue(fakellm.Script{Events: evs, Usage: &fakellm.Usage{InputTokens: 10, OutputTokens: 20}})
		eval[bool](t, e, `(() => { window.__tl = []; const t0 = performance.now(); const L = m => window.__tl.push(Math.round(performance.now()-t0) + ' ' + m);
			['htmx:beforeRequest','htmx:afterRequest','htmx:beforeSwap','htmx:afterSwap','htmx:sseOpen','htmx:sseClose','htmx:responseError','htmx:swapError','htmx:targetError'].forEach(n => document.body.addEventListener(n, ev => L(n + ' ' + ((ev.detail && ev.detail.requestConfig) ? ev.detail.requestConfig.path : '') + ' live=' + !!document.querySelector('article.reply.live') + ' status=' + ((ev.detail && ev.detail.xhr) ? ev.detail.xhr.status + ' ' + (ev.detail.xhr.status >= 400 ? ev.detail.xhr.responseText.slice(0, 200) : '') : ''))));
			return true; })()`)
		if !eval[bool](t, e, `(() => { const b = [...document.querySelectorAll('#messages button[aria-label="Regenerate"]')].pop(); if (!b) return false; b.click(); return true; })()`) {
			t.Fatal("no Regenerate button")
		}
		streamed := `(() => { const a = document.querySelector('article.reply.live .md:not(.think-panel)'); return !!a && a.innerText.includes('Chromatophores') && !a.innerText.includes('version'); })()`
		end := time.Now().Add(8 * time.Second)
		for !eval[bool](t, e, streamed) {
			if time.Now().After(end) {
				t.Fatalf("regenerate %c never streamed into a live row; timeline:\n%s", 'A'+i, eval[string](t, e, `window.__tl.join('\n')`))
			}
			time.Sleep(50 * time.Millisecond)
		}
		waitUntil(t, e, "regenerate "+string(rune('A'+i))+" settled",
			`!document.querySelector('article.reply.live') && document.querySelector('#messages').innerText.includes('version `+string(rune('A'+i))+`')`, 15*time.Second)
	}
}

// Save and resend forks the edited question and streams the new reply.
func TestBrowser_EditAndResendStreams(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	e.convSendTurn(t, "How far can a seal dive", "About three hundred metres.")
	id := e.convRowID(t, "seal dive")
	var evs []fakellm.Event
	for _, w := range strings.Fields("Elephant seals reach fifteen hundred metres and stay down for an hour or more.") {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: w + " ", Delay: 150 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs, Usage: &fakellm.Usage{InputTokens: 10, OutputTokens: 20}})

	e.convAct(t, id, `a[aria-label="Edit message"]`)
	waitUntil(t, e, "the editor opened", `!!document.querySelector('form.edit-form#m-`+id+` textarea')`, 5*time.Second)
	eval[bool](t, e, `(() => { document.querySelector('#m-`+id+` textarea').value = 'How far can an elephant seal dive'; return true; })()`)
	e.convAct(t, id, `button.resend`)
	waitUntil(t, e, "the resent question's reply streamed into a live row",
		`(() => { const a = document.querySelector('article.reply.live .md:not(.think-panel)'); return !!a && a.innerText.includes('Elephant seals') && !a.innerText.includes('or more'); })()`, 8*time.Second)
	waitUntil(t, e, "the reply settled beside the edited question",
		`(() => { const t = document.querySelector('#messages').innerText; return !document.querySelector('article.reply.live') && t.includes('elephant seal dive') && t.includes('or more.') && !t.includes('three hundred'); })()`, 15*time.Second)
}

// Up in the empty composer opens your last message's editor in place (the
// inspector's Keyboard list says so). The handler ignored keys while a field
// had focus, the composer included, so it never fired where you'd press it.
func TestBrowser_UpEditsTheLastMessage(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	e.convSendTurn(t, "First question about krill", "Krill swarm in their billions.")
	e.convSendTurn(t, "Second question about krill", "Whales eat tonnes a day.")
	last := e.convRowID(t, "Second question")
	if err := chromedp.Run(e.ctx, chromedp.Focus(`#composer-text`, chromedp.ByID), chromedp.KeyEvent(kb.ArrowUp)); err != nil {
		t.Fatalf("press Up: %v", err)
	}
	waitUntil(t, e, "Up opened the last message's editor", `!!document.querySelector('form.edit-form#m-`+last+` textarea')`, 5*time.Second)
	if p := eval[string](t, e, `location.pathname + location.search`); p != "/c/"+e.convID {
		t.Errorf("Up navigated to %s; the editor should open in place", p)
	}
}

// Files go with the message they were attached to and no further: after the
// send the composer's chips are gone, and the next message carries nothing.
func TestBrowser_AttachmentsLeaveWithTheirMessage(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	if !eval[bool](t, e, `(() => { (async () => {
		const c = document.createElement('canvas'); c.width = 60; c.height = 40;
		const g = c.getContext('2d'); g.fillStyle = '#2a7'; g.fillRect(0, 0, 60, 40);
		const blob = await new Promise(r => c.toBlob(r, 'image/png'));
		const dt = new DataTransfer();
		dt.items.add(new File([blob], 'reef.png', {type: 'image/png'}));
		dt.items.add(new File(['tide tables'], 'tides.txt', {type: 'text/plain'}));
		const input = document.querySelector('#composer input[type=file]');
		input.files = dt.files;
		input.dispatchEvent(new Event('change', {bubbles: true}));
	})(); return true; })()`) {
		t.Fatal("couldn't attach")
	}
	waitUntil(t, e, "both files stored", `document.querySelectorAll('#composer input[name=attachment]').length === 2 && !document.querySelector('#composer[data-uploading]')`, 10*time.Second)
	e.convSendTurn(t, "What do these show", "A reef and the tides.")
	if n := eval[int](t, e, `document.querySelectorAll('#composer input[name=attachment]').length`); n != 0 {
		t.Errorf("%d attachment ids stayed in the composer after the send", n)
	}
	if !eval[bool](t, e, `document.querySelector('#pending').hidden`) {
		t.Error("the attachment chips stayed after the send")
	}
	eval[bool](t, e, `(() => { window.__tl = []; const t0 = performance.now(); const L = m => window.__tl.push(Math.round(performance.now()-t0) + ' ' + m);
		['htmx:beforeRequest','htmx:afterRequest','htmx:beforeSwap','htmx:afterSwap','htmx:sseOpen','htmx:sseClose','htmx:sseError','htmx:responseError','htmx:swapError','htmx:targetError','htmx:oobErrorNoTarget','htmx:sendError','htmx:sseMessage'].forEach(n => document.body.addEventListener(n, ev => L(n + ' ' + ((ev.detail && ev.detail.requestConfig) ? ev.detail.requestConfig.path : (ev.target && (ev.target.id || ev.target.className))) + ' live=' + !!document.querySelector('article.reply.live') + ' st=' + ((ev.detail && ev.detail.xhr) ? ev.detail.xhr.status : ''))));
		return true; })()`)
	defer func() {
		if t.Failed() {
			t.Logf("timeline:\n%s", eval[string](t, e, `window.__tl.join('\n')`))
		}
	}()
	e.convSendTurn(t, "Thanks, that is all", "Any time.")
	if eval[bool](t, e, `(() => { const r = [...document.querySelectorAll('#messages .turn-user')].pop(); return !!r.querySelector('img, .file-chip'); })()`) {
		t.Error("the next message carried the files again")
	}
}

func (e *browserEnv) convDump(t *testing.T) string {
	ctx := context.Background()
	cx, err := e.q.GetActiveContextByConversation(ctx, uuid.MustParse(e.convID))
	if err != nil {
		return err.Error()
	}
	msgs, err := e.q.ListMessagesByContext(ctx, store.ListMessagesByContextParams{ContextID: cx.ID, RowLimit: 100})
	if err != nil {
		return err.Error()
	}
	var b strings.Builder
	for _, m := range msgs {
		fmt.Fprintf(&b, "[%s %.30q] ", m.Role, m.Content)
	}
	return b.String()
}

// convTimeline records htmx requests, swaps and stream events from now on.
const convTimeline = `(() => { window.__ctl = []; const t0 = performance.now();
	const L = m => window.__ctl.push(Math.round(performance.now() - t0) + ' ' + m);
	['htmx:beforeRequest','htmx:afterRequest','htmx:afterSwap','htmx:sseOpen','htmx:sseClose','htmx:sseMessage','htmx:sendAbort','htmx:responseError','htmx:sendError'].forEach(n =>
		document.body.addEventListener(n, ev => { const d = ev.detail || {}; const el = d.elt || ev.target;
			if (n === 'htmx:sseMessage' && el && el.classList && el.classList.contains('md')) return;
			L(n + ' ' + (d.requestConfig ? d.requestConfig.path : (el && (el.id || el.className))) + ' live=' + !!document.querySelector('article.reply.live') + (d.xhr ? ' st=' + d.xhr.status : '')); }));
	return true; })()`

// Your own message's delete strip offers Delete from here when messages
// follow it (board MessageStates); it removes the message and everything
// after it and keeps what came before.
func TestBrowser_DeleteFromHereOnYourMessage(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	e.convSendTurn(t, "Name a fish that walks", "The frogfish walks on its fins.")
	e.convSendTurn(t, "And one that climbs", "The mudskipper climbs mangrove roots.")
	user := e.convRowID(t, "that climbs")
	reply := e.convRowID(t, "mudskipper")
	e.convAct(t, user, `a[aria-label="Delete message"]`)
	waitUntil(t, e, "the strip offers Delete from here", `(() => { const f = document.querySelector('form.del-confirm#m-`+user+`'); return !!f && !!f.querySelector('button[name=cascade]'); })()`, 5*time.Second)
	e.convAct(t, user, `button[name=cascade]`)
	waitUntil(t, e, "the turn left the transcript", `(() => { const t = document.querySelector('#messages').innerText; return !t.includes('that climbs') && !t.includes('mudskipper') && t.includes('frogfish'); })()`, 5*time.Second)
	for _, id := range []string{user, reply} {
		if _, ok := e.convStored(t, id); ok {
			t.Errorf("message %s is still stored", id)
		}
	}
}

// The header (title, model, context gauge) follows a reply. It wasn't
// redrawn by anything, so the gauge kept its first value until a reload.
func TestBrowser_HeaderFollowsAReply(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	before := eval[string](t, e, `document.querySelector('#conv-head .gauge').getAttribute('aria-label')`)
	e.convSendTurn(t, "Tell me about kelp forests", "Kelp grows half a metre a day in good light.")
	waitUntil(t, e, "the header's gauge moved", `document.querySelector('#conv-head .gauge').getAttribute('aria-label') !== `+jsStr(before), 8*time.Second)
}
