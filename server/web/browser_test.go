package web

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
	"golang.org/x/crypto/bcrypt"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/conversations"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/events"
	"github.com/jdpedrie/psmith/server/files"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/modelproviders"
	"github.com/jdpedrie/psmith/server/preferencessvc"
	"github.com/jdpedrie/psmith/server/profiles"
	_ "github.com/jdpedrie/psmith/server/providers/anthropic"
	"github.com/jdpedrie/psmith/server/storage"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
	"github.com/jdpedrie/psmith/server/streamsvc"
	"github.com/jdpedrie/psmith/server/testutil"
)

// Browser tests drive the real web client in headless Chrome against the real
// handler, a fresh database and a fake model that streams slowly. They record
// what was on the page every 150ms, not just where it ended, because
// streaming bugs live between frames: a message that renders, vanishes, and
// only comes back on reload passes any test that looks at the end state.
//
// They skip when Chrome isn't installed or with -short. Frames and the
// timeline land in $PSMITH_WEB_E2E_OUT/<test>/ (a temp dir otherwise).

type browserEnv struct {
	srv        *httptest.Server
	ctx        context.Context
	convID     string
	providerID string
	fake       *fakellm.Server
	q          *store.Queries
	out        string
}

func chromePath() string {
	for _, p := range []string{
		"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
		"/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
	} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	if p, err := exec.LookPath("google-chrome"); err == nil {
		return p
	}
	return ""
}

// newBrowserEnv starts the web client on a real mux with the services main()
// builds, seeds a conversation whose provider is the fake, signs in, and
// opens a headless browser with the session cookie set.
func newBrowserEnv(t *testing.T) *browserEnv {
	t.Helper()
	if testing.Short() {
		t.Skip("browser test")
	}
	chrome := chromePath()
	if chrome == "" {
		t.Skip("Chrome not installed")
	}

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	bus := events.New(slog.Default())
	sup := stream.New(q, slog.Default())
	authSvc := auth.NewService(q)
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default()).WithBus(bus)
	models := modelproviders.NewService(q, cat, crypto.Nop{}, slog.Default()).WithBus(bus)
	profs := profiles.NewService(q, pool, crypto.Nop{}).WithBus(bus)
	// As main() wires them: the terminal hooks are what publish the
	// "conversation changed" event the page refreshes on.
	sup.SetOnAssistantMaterialized(convos.OnAssistantPersisted)
	sup.SetOnRunMaterialized(convos.OnRunMaterialized)
	st, err := storage.NewFS(t.TempDir())
	if err != nil {
		t.Fatalf("storage: %v", err)
	}
	filesSvc := files.NewService(q, st, []byte("test-signing-key-0123456789abcdef"), "")
	h := New(Deps{Queries: q, Auth: authSvc, Conversations: convos, Models: models, Profiles: profs,
		Supervisor: sup, Bus: bus, Preferences: preferencessvc.NewService(q), Streams: streamsvc.NewService(q, sup),
		Files: filesSvc, Logger: slog.Default()})
	mux := http.NewServeMux()
	h.Mount(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	fx := seedSendable(t, q, fake.URL())
	hash, _ := bcrypt.GenerateFromPassword([]byte("pw"), bcrypt.MinCost)
	if err := q.UpdateUserPassword(context.Background(), store.UpdateUserPasswordParams{ID: fx.userID, PasswordHash: string(hash)}); err != nil {
		t.Fatalf("UpdateUserPassword: %v", err)
	}
	user, err := q.GetUserByID(context.Background(), fx.userID)
	if err != nil {
		t.Fatal(err)
	}
	login, err := authSvc.Login(context.Background(), connect.NewRequest(&psmithv1.LoginRequest{Username: user.Username, Password: "pw"}))
	if err != nil {
		t.Fatalf("Login: %v", err)
	}

	opts := append(chromedp.DefaultExecAllocatorOptions[:], chromedp.ExecPath(chrome), chromedp.WindowSize(1440, 900))
	alloc, cancelAlloc := chromedp.NewExecAllocator(context.Background(), opts...)
	t.Cleanup(cancelAlloc)
	bctx, cancelCtx := chromedp.NewContext(alloc)
	t.Cleanup(cancelCtx)
	host := strings.TrimPrefix(srv.URL, "http://")
	if err := chromedp.Run(bctx, chromedp.ActionFunc(func(ctx context.Context) error {
		return network.SetCookie(sessionCookie, login.Msg.GetSessionToken()).WithDomain(strings.Split(host, ":")[0]).WithPath("/").Do(ctx)
	})); err != nil {
		t.Fatalf("set cookie: %v", err)
	}

	out := os.Getenv("PSMITH_WEB_E2E_OUT")
	if out == "" {
		out = t.TempDir()
	}
	out = filepath.Join(out, t.Name())
	_ = os.RemoveAll(out)
	_ = os.MkdirAll(out, 0o755)
	return &browserEnv{srv: srv, ctx: bctx, convID: fx.convID.String(), providerID: fx.providerID.String(), fake: fake, q: q, out: out}
}

// frame is one sample of the page.
type frame struct {
	t     time.Duration
	seen  map[string]bool
	state string
}

// record samples the page every interval until done reports true or timeout
// passes, saving a screenshot per frame and the timeline at the end.
func (e *browserEnv) record(t *testing.T, needles []string, timeout time.Duration, done func(state string) bool) []frame {
	t.Helper()
	start := time.Now()
	var frames []frame
	var lines []string
	for time.Since(start) < timeout {
		var text, state string
		var shot []byte
		if err := chromedp.Run(e.ctx,
			chromedp.Evaluate(`document.body ? document.body.innerText : ""`, &text),
			chromedp.Evaluate(`(() => {
				const m = document.getElementById('messages');
				const bubbles = m ? m.querySelectorAll('.bubble').length : -1;
				const replies = m ? m.querySelectorAll('.reply').length : -1;
				const live = m ? m.querySelectorAll('.reply.live').length : -1;
				const form = document.getElementById('composer');
				const lr = m ? m.querySelector('.reply.live') : null;
				const md = lr ? lr.querySelector('.md') : null;
				return 'bubbles=' + bubbles + ' replies=' + replies + ' live=' + live +
					' composerLive=' + (form ? form.hasAttribute('data-live') : 'none') +
					' htmx=' + (typeof htmx) + ' sseExt=' + (typeof htmx !== 'undefined' && !!htmx.ext && !!htmx.ext.sse) +
					' sse=' + (lr ? lr.getAttribute('sse-connect') : '-') + ' md=' + (md ? md.innerHTML.length : -1);
			})()`, &state),
			chromedp.CaptureScreenshot(&shot),
		); err != nil {
			t.Fatalf("sample: %v", err)
		}
		if len(frames) == 10 {
			var dom string
			_ = chromedp.Run(e.ctx, chromedp.OuterHTML("html", &dom))
			_ = os.WriteFile(filepath.Join(e.out, "dom-f010.html"), []byte(dom), 0o644)
		}
		f := frame{t: time.Since(start), seen: map[string]bool{}, state: state}
		low := strings.ToLower(text)
		marks := []string{}
		for _, n := range needles {
			f.seen[n] = strings.Contains(low, strings.ToLower(n))
			mark := "NO"
			if f.seen[n] {
				mark = "yes"
			}
			marks = append(marks, n+"="+mark)
		}
		frames = append(frames, f)
		_ = os.WriteFile(filepath.Join(e.out, fmt.Sprintf("f%03d.png", len(frames)-1)), shot, 0o644)
		lines = append(lines, fmt.Sprintf("f%03d t=%5.2fs %s | %s", len(frames)-1, f.t.Seconds(), strings.Join(marks, " "), state))
		if done(state) {
			break
		}
		time.Sleep(150 * time.Millisecond)
	}
	_ = os.WriteFile(filepath.Join(e.out, "timeline.txt"), []byte(strings.Join(lines, "\n")), 0o644)
	return frames
}

// gaps lists the frames from `from` on where needle wasn't visible.
func gaps(frames []frame, needle string, from time.Duration) []string {
	var out []string
	for i, f := range frames {
		if f.t >= from && !f.seen[needle] {
			out = append(out, fmt.Sprintf("f%03d@%.2fs", i, f.t.Seconds()))
		}
	}
	return out
}

// The user's message and the streamed reply stay on the page from the moment
// they appear, through the stream, its end and the refresh that follows.
func TestBrowser_SendShowsBothMessagesThroughout(t *testing.T) {
	e := newBrowserEnv(t)
	words := strings.Fields("Here's a quick rundown of the tidal pools you asked about, covering the anemones, the barnacles and the hermit crabs that live between the rocks.")
	var evs []fakellm.Event
	for _, w := range words {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: w + " ", Delay: 80 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs, Usage: &fakellm.Usage{InputTokens: 20, OutputTokens: 40}})

	if err := chromedp.Run(e.ctx,
		chromedp.Navigate(e.srv.URL+"/c/"+e.convID),
		chromedp.WaitVisible(`#composer-text`, chromedp.ByID),
		chromedp.SendKeys(`#composer-text`, "Tidepool question number seven", chromedp.ByID),
		chromedp.KeyEvent("\r"),
	); err != nil {
		t.Fatalf("send: %v", err)
	}

	user, reply := "tidepool question", "quick rundown"
	var settledAt time.Time
	sawLive := false
	frames := e.record(t, []string{user, reply}, 20*time.Second, func(state string) bool {
		if strings.Contains(state, "live=1") {
			sawLive = true
		}
		finished := sawLive && strings.Contains(state, "live=0") && !strings.Contains(state, "composerLive=true")
		if finished && settledAt.IsZero() {
			settledAt = time.Now()
		}
		return !settledAt.IsZero() && time.Since(settledAt) > 3*time.Second
	})

	if settledAt.IsZero() {
		t.Fatalf("the reply never finished (fake model got %d requests); timeline in %s", len(e.fake.Requests()), e.out)
	}
	if g := gaps(frames, user, time.Second); len(g) > 0 {
		t.Errorf("the user's message was missing in %v; timeline in %s", g, e.out)
	}
	first := time.Duration(-1)
	for _, f := range frames {
		if f.seen[reply] {
			first = f.t
			break
		}
	}
	if first < 0 {
		t.Fatalf("the reply never showed; timeline in %s", e.out)
	}
	if g := gaps(frames, reply, first); len(g) > 0 {
		t.Errorf("the reply disappeared in %v; timeline in %s", g, e.out)
	}
}
