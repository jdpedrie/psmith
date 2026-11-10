package web

import (
	"context"
	"strings"
	"testing"
	"time"

	cdppage "github.com/chromedp/cdproto/page"
	"github.com/chromedp/chromedp"

	"github.com/jdpedrie/psmith/fakellm"
)

// streamCounter wraps EventSource so the page counts each run stream it
// opens and the most text any live reply has shown.
const streamCounter = `(() => {
	window.__streams = 0; window.__closedEarly = 0;
	const ES = window.EventSource;
	window.EventSource = function (url, opts) {
		const s = new ES(url, opts);
		if (url.includes('/stream?run=')) {
			window.__streams++;
			let done = false;
			s.addEventListener('done', () => { done = true; });
			const close = s.close.bind(s);
			s.close = () => { if (!done) window.__closedEarly++; close(); };
		}
		return s;
	};
	Object.assign(window.EventSource, {CONNECTING: 0, OPEN: 1, CLOSED: 2});
	return true;
})()`

// One send opens one stream and keeps it to the end. The account event
// that the user's message was stored used to refresh the transcript
// mid-reply, replacing the live row: its stream closed and a second one
// opened, and any chunk between the two was the new row's to replay.
func TestBrowser_OneStreamPerSend(t *testing.T) {
	e := newBrowserEnv(t)
	var evs []fakellm.Event
	for _, w := range strings.Fields("Barnacles glue themselves head first to the rock and kick food into their mouths with their legs.") {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: w + " ", Delay: 120 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs, Usage: &fakellm.Usage{InputTokens: 20, OutputTokens: 30}})

	e.open(t, "/c/"+e.convID)
	if !eval[bool](t, e, streamCounter) {
		t.Fatal("couldn't install the stream counter")
	}
	if err := chromedp.Run(e.ctx,
		chromedp.WaitVisible(`#composer-text`, chromedp.ByID),
		chromedp.SendKeys(`#composer-text`, "Tell me about barnacles", chromedp.ByID),
		chromedp.KeyEvent("\r"),
	); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitUntil(t, e, "the reply started streaming",
		`(() => { const a = document.querySelector('article.reply.live .md:not(.think-panel)'); return !!a && a.innerText.includes('Barnacles'); })()`, 10*time.Second)
	waitUntil(t, e, "the reply finished",
		`!document.querySelector('article.reply.live') && document.querySelector('#messages').innerText.includes('kick food')`, 15*time.Second)

	if n := eval[int](t, e, `window.__streams`); n != 1 {
		t.Errorf("the send opened %d run streams, want 1", n)
	}
	if n := eval[int](t, e, `window.__closedEarly`); n != 0 {
		t.Errorf("%d run streams were closed before their reply finished", n)
	}
}

// Seven tabs open at once still send and stream. Over HTTP/1.1 a browser
// keeps six connections per host; each tab held its own account event
// stream, so with six tabs a send queued until one closed, and the reply
// "showed up after leaving and coming back". Tabs share one stream now.
func TestBrowser_ManyTabsStillSendAndStream(t *testing.T) {
	e := newBrowserEnv(t)
	var evs []fakellm.Event
	for _, w := range strings.Fields("Hermit crabs trade up to bigger shells as they grow, and sometimes queue by size to swap.") {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: w + " ", Delay: 100 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs, Usage: &fakellm.Usage{InputTokens: 20, OutputTokens: 30}})

	e.open(t, "/c/"+e.convID)
	for i := 0; i < 6; i++ {
		tab, cancel := chromedp.NewContext(e.ctx)
		t.Cleanup(cancel)
		if err := chromedp.Run(tab, chromedp.Navigate(e.srv.URL+"/chats"), chromedp.WaitReady("body")); err != nil {
			t.Fatalf("open tab %d: %v", i, err)
		}
	}
	// Each tab's account stream is up (or shared) before the send.
	time.Sleep(time.Second)
	if err := chromedp.Run(e.ctx,
		chromedp.WaitVisible(`#composer-text`, chromedp.ByID),
		chromedp.SendKeys(`#composer-text`, "Tell me about hermit crabs", chromedp.ByID),
		chromedp.KeyEvent("\r"),
	); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitUntil(t, e, "the reply started streaming with six other tabs open",
		`(() => { const a = document.querySelector('article.reply.live .md:not(.think-panel)'); return !!a && a.innerText.includes('Hermit'); })()`, 10*time.Second)
	waitUntil(t, e, "the reply finished",
		`!document.querySelector('article.reply.live') && document.querySelector('#messages').innerText.includes('swap.')`, 15*time.Second)
}

// brokenSharedWorker stands in for a browser whose shared workers can't reach
// the server (some embedded browsers refuse a worker's requests outright):
// the worker's stream reports an error and never opens.
const brokenSharedWorker = `window.SharedWorker = function () {
	const ch = new MessageChannel();
	setTimeout(() => ch.port1.postMessage({type: 'error', readyState: 0}), 50);
	return {port: ch.port2};
};`

// A shared account stream that never opens hands over to a direct one: the
// page comes online, replies stream, and the tab's later pages skip the worker.
func TestBrowser_SharedStreamFallsBackToDirect(t *testing.T) {
	e := newBrowserEnv(t)
	var evs []fakellm.Event
	for _, w := range strings.Fields("Anemones sting their prey and then fold it inward.") {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: w + " ", Delay: 100 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs, Usage: &fakellm.Usage{InputTokens: 20, OutputTokens: 20}})

	if err := chromedp.Run(e.ctx, chromedp.ActionFunc(func(ctx context.Context) error {
		_, err := cdppage.AddScriptToEvaluateOnNewDocument(brokenSharedWorker).Do(ctx)
		return err
	})); err != nil {
		t.Fatalf("install broken worker: %v", err)
	}
	e.open(t, "/c/"+e.convID)
	waitUntil(t, e, "the tab remembered to connect directly", `sessionStorage.getItem('psmith-events-direct') === '1'`, 5*time.Second)
	time.Sleep(time.Second)
	if eval[bool](t, e, `document.documentElement.hasAttribute('data-offline')`) {
		t.Fatal("the page is offline after the direct handover")
	}
	if err := chromedp.Run(e.ctx,
		chromedp.WaitVisible(`#composer-text`, chromedp.ByID),
		chromedp.SendKeys(`#composer-text`, "Tell me about anemones", chromedp.ByID),
		chromedp.KeyEvent("\r"),
	); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitUntil(t, e, "the reply finished and the transcript refreshed",
		`!document.querySelector('article.reply.live') && document.querySelector('#messages').innerText.includes('fold it inward')`, 15*time.Second)
}
