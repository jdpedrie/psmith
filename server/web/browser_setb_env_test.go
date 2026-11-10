package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/cdproto/browser"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"
	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/conversations"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/embeddersvc"
	"github.com/jdpedrie/psmith/server/events"
	"github.com/jdpedrie/psmith/server/langfuse"
	"github.com/jdpedrie/psmith/server/langfusesvc"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/modelproviders"
	"github.com/jdpedrie/psmith/server/preferencessvc"
	"github.com/jdpedrie/psmith/server/profiles"
	"github.com/jdpedrie/psmith/server/speechsvc"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
	"github.com/jdpedrie/psmith/server/streamsvc"
	"github.com/jdpedrie/psmith/server/testutil"
)

// setbBrowser is newBrowserEnv with the integrations Settings B covers
// (embedder, Langfuse, speech) wired in, plus the services a test reads the
// database back through as the signed-in user.
type setbBrowser struct {
	*browserEnv
	prof   *profiles.Service
	lf     *langfusesvc.Service
	emb    *embeddersvc.Service
	sp     *speechsvc.Service
	models *modelproviders.Service
	uctx   context.Context
	uid    uuid.UUID
}

func newSetbBrowser(t *testing.T) *setbBrowser {
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
	emitter := langfuse.NewEmitter(slog.Default(), langfuse.EmitterConfig{})
	t.Cleanup(func() { emitter.Stop(context.Background()) })
	lf := langfusesvc.NewService(q, crypto.Nop{}, emitter, slog.Default())
	emb := embeddersvc.NewService(q, crypto.Nop{}, func(uuid.UUID) {}, slog.Default())
	sp := speechsvc.NewService(q, crypto.Nop{}, slog.Default())
	h := New(Deps{Queries: q, Auth: authSvc, Conversations: convos, Models: models, Profiles: profs,
		Supervisor: sup, Bus: bus, Preferences: preferencessvc.NewService(q), Streams: streamsvc.NewService(q, sup),
		Embedder: emb, Langfuse: lf, Speech: sp, Logger: slog.Default()})
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
	return &setbBrowser{
		browserEnv: &browserEnv{srv: srv, ctx: bctx, convID: fx.convID.String(), providerID: fx.providerID.String(), fake: fake, q: q, out: out},
		prof:       profs, lf: lf, emb: emb, sp: sp, models: models,
		uctx: auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: user.Username}),
		uid:  fx.userID,
	}
}

// click clicks the first element matching sel with a real mouse event at
// its center, the way a person would, after scrolling it into view.
func (e *setbBrowser) setbClick(t *testing.T, sel string) {
	t.Helper()
	if err := chromedp.Run(e.ctx, chromedp.Click(sel, chromedp.ByQuery, chromedp.NodeVisible)); err != nil {
		t.Fatalf("click %s: %v", sel, err)
	}
}

// typeInto focuses sel and types text with real key events.
func (e *setbBrowser) setbTypeInto(t *testing.T, sel, text string) {
	t.Helper()
	if err := chromedp.Run(e.ctx, chromedp.Click(sel, chromedp.ByQuery, chromedp.NodeVisible), chromedp.SendKeys(sel, text, chromedp.ByQuery)); err != nil {
		t.Fatalf("type into %s: %v", sel, err)
	}
}

// clearAndType replaces a field's text by selecting it all and typing.
func (e *setbBrowser) setbClearAndType(t *testing.T, sel, text string) {
	t.Helper()
	e.setbClick(t, sel)
	eval[bool](t, e.browserEnv, `(() => { document.querySelector(`+setbJS(sel)+`).select(); return true })()`)
	e.keys(t, chromedp.KeyEvent(kb.Backspace))
	if text != "" {
		e.keys(t, chromedp.SendKeys(sel, text, chromedp.ByQuery))
	}
}

// waitLoad waits for a navigation the last action started to land on a
// path that has prefix.
func (e *setbBrowser) setbWaitPath(t *testing.T, prefix string) {
	t.Helper()
	waitUntil(t, e.browserEnv, "path "+prefix, `location.pathname.startsWith(`+setbJS(prefix)+`) && document.readyState === "complete"`, 10*time.Second)
}

func (e *setbBrowser) setbText(t *testing.T) string {
	t.Helper()
	return eval[string](t, e.browserEnv, `document.body.innerText`)
}

func (e *setbBrowser) setbShot(t *testing.T, name string) {
	t.Helper()
	var buf []byte
	if err := chromedp.Run(e.ctx, chromedp.FullScreenshot(&buf, 90)); err == nil {
		_ = os.WriteFile(filepath.Join(e.out, name+".jpg"), buf, 0o644)
	}
}

// reload reloads the page and waits for it.
func (e *setbBrowser) setbReload(t *testing.T) {
	t.Helper()
	if err := chromedp.Run(e.ctx, chromedp.Reload(), chromedp.WaitReady("body")); err != nil {
		t.Fatalf("reload: %v", err)
	}
}

// blockDownloads stops Chrome saving anything a test triggers.
func (e *setbBrowser) setbBlockDownloads(t *testing.T) {
	t.Helper()
	_ = chromedp.Run(e.ctx, browser.SetDownloadBehavior(browser.SetDownloadBehaviorBehaviorDeny))
}

func (e *setbBrowser) setbProfile(t *testing.T, name, parent string) string {
	t.Helper()
	req := &psmithv1.CreateProfileRequest{Name: name}
	if parent != "" {
		req.ParentProfileId = &parent
	}
	resp, err := e.prof.CreateProfile(e.uctx, connect.NewRequest(req))
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return resp.Msg.GetProfile().GetId()
}

func (e *setbBrowser) setbLoad(t *testing.T, id string) *psmithv1.Profile {
	t.Helper()
	resp, err := e.prof.GetProfile(e.uctx, connect.NewRequest(&psmithv1.GetProfileRequest{Id: id}))
	if err != nil {
		t.Fatalf("GetProfile: %v", err)
	}
	return resp.Msg.GetProfile()
}

func setbJS(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)
	return `"` + r.Replace(s) + `"`
}
