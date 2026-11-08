package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/modelproviders"
	"github.com/jdpedrie/psmith/server/preferencessvc"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/testutil"
)

// saEnv is a handler wired to a fresh database, a signed-in user and the
// routes mounted, so tests go through the same mux the server uses.
type saEnv struct {
	t      *testing.T
	h      *Handler
	q      *store.Queries
	user   auth.User
	ctx    context.Context
	models *modelproviders.Service
}

func newSAEnv(t *testing.T, admin bool) *saEnv {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	models := modelproviders.NewService(q, modelmeta.NewLiveCatalog(nil), crypto.Nop{}, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Models: models, Preferences: preferencessvc.NewService(q), Logger: slog.Default()})
	ctx := context.Background()
	uid, _ := uuid.NewV7()
	hash, _ := bcrypt.GenerateFromPassword([]byte("old-pass"), bcrypt.MinCost)
	row, err := q.CreateUser(ctx, store.CreateUserParams{ID: uid, Username: "u" + uid.String()[:8], PasswordHash: string(hash), IsAdmin: admin})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	u := auth.User{ID: row.ID, Username: row.Username, IsAdmin: admin, CreatedAt: row.CreatedAt}
	return &saEnv{t: t, h: h, q: q, user: u, ctx: auth.ContextWithUser(ctx, u), models: models}
}

// do runs a request through the settings-a routes as the env's user. The
// routes are wrapped in requireUser, which reads a session; tests bypass it by
// serving the matched handler with the user already in the context.
func (e *saEnv) do(method, target string, form url.Values) *httptest.ResponseRecorder {
	e.t.Helper()
	var body *strings.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	} else {
		body = strings.NewReader("")
	}
	req := httptest.NewRequest(method, target, body).WithContext(e.ctx)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	mux := http.NewServeMux()
	e.h.mountSettingsAWith(mux, func(next http.HandlerFunc) http.HandlerFunc { return next })
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func (e *saEnv) mustOK(rec *httptest.ResponseRecorder, wants ...string) string {
	e.t.Helper()
	if rec.Code != http.StatusOK {
		e.t.Fatalf("status %d, body:\n%s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	for _, w := range wants {
		if !strings.Contains(body, w) {
			e.t.Errorf("body missing %q", w)
		}
	}
	return body
}

func (e *saEnv) mustRedirect(rec *httptest.ResponseRecorder, prefix string) string {
	e.t.Helper()
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(rec.Header().Get("Location"), prefix) {
		e.t.Fatalf("want 303 to %s…, got %d %q; body:\n%s", prefix, rec.Code, rec.Header().Get("Location"), rec.Body.String())
	}
	return rec.Header().Get("Location")
}

func (e *saEnv) provider(typ, label string, cfg string) string {
	e.t.Helper()
	resp, err := e.models.CreateUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{Type: typ, Label: label, Config: []byte(cfg)}))
	if err != nil {
		e.t.Fatalf("create provider: %v", err)
	}
	return resp.Msg.GetProvider().GetId()
}

func TestSettingsGeneral(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)

	// /settings is General, marked as the phone's navigation index.
	e.mustOK(e.do("GET", "/settings", nil), "sindex", `<option value="0" selected>Off</option>`, "Change password")
	if b := e.mustOK(e.do("GET", "/settings/general", nil)); strings.Contains(b, "sindex") {
		t.Error("/settings/general carries the index marker")
	}

	e.mustRedirect(e.do("POST", "/settings/general/warning", url.Values{"warn": {"75000"}}), "/settings/general")
	e.mustOK(e.do("GET", "/settings/general", nil), `<option value="75000" selected>`)

	// A custom number shows as Custom with its value.
	e.mustRedirect(e.do("POST", "/settings/general/warning", url.Values{"warn": {"custom"}, "custom": {"123,000"}}), "/settings/general")
	e.mustOK(e.do("GET", "/settings/general", nil), `<option value="custom" selected>`, `value="123,000"`)
	// Custom with no number waits rather than saving.
	e.mustRedirect(e.do("POST", "/settings/general/warning", url.Values{"warn": {"custom"}}), "/settings/general?warn=custom")
	got, _ := e.h.prefs.GetPreferences(e.ctx, connect.NewRequest(&psmithv1.GetPreferencesRequest{}))
	if got.Msg.GetPreferences().GetContextWarningTokens() != 123000 {
		t.Errorf("warning = %d, want 123000", got.Msg.GetPreferences().GetContextWarningTokens())
	}
	if rec := e.do("POST", "/settings/general/warning", url.Values{"warn": {"lots"}}); rec.Code != http.StatusBadRequest {
		t.Errorf("bad warning status %d", rec.Code)
	}
}

func TestSettingsChangePassword(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)

	rec := e.do("POST", "/settings/general/password", url.Values{"current": {"old-pass"}, "new": {"a"}, "confirm": {"b"}})
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "don’t match") {
		t.Errorf("mismatch: %d", rec.Code)
	}
	rec = e.do("POST", "/settings/general/password", url.Values{"current": {"nope"}, "new": {"n"}, "confirm": {"n"}})
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "current password is wrong") {
		t.Errorf("wrong current: %d %s", rec.Code, rec.Body.String())
	}
	e.mustRedirect(e.do("POST", "/settings/general/password", url.Values{"current": {"old-pass"}, "new": {"new-pass"}, "confirm": {"new-pass"}}), "/settings/general?pw=ok")
	e.mustOK(e.do("GET", "/settings/general?pw=ok", nil), "Password changed just now")
	row, _ := e.q.GetUserByID(e.ctx, e.user.ID)
	if bcrypt.CompareHashAndPassword([]byte(row.PasswordHash), []byte("new-pass")) != nil {
		t.Error("password not changed")
	}
}

func TestSettingsAppearance(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	body := e.mustOK(e.do("GET", "/settings/appearance", nil), `data-theme="sage"`, `data-theme="nordic"`, `aria-valuetext="100%"`)
	if strings.Count(body, `class="tcard"`) != len(themeIDs) {
		t.Errorf("want %d theme cards", len(themeIDs))
	}

	rec := e.do("POST", "/prefs/display", url.Values{"text_size": {"120"}, "turn_details": {"true"}})
	e.mustRedirect(rec, "/settings/appearance")
	cookies := map[string]string{}
	for _, c := range rec.Result().Cookies() {
		cookies[c.Name] = c.Value
	}
	if cookies[textSizeCookie] != "120" || cookies[turnsCookie] != "1" {
		t.Errorf("cookies = %v", cookies)
	}
	if rec := e.do("POST", "/prefs/display", url.Values{"text_size": {"300"}}); rec.Code != http.StatusBadRequest {
		t.Errorf("out of range size: %d", rec.Code)
	}

	req := httptest.NewRequest("GET", "/settings/appearance", nil)
	req.AddCookie(&http.Cookie{Name: textSizeCookie, Value: "140"})
	req.AddCookie(&http.Cookie{Name: turnsCookie, Value: "1"})
	if p := saReadDisplayPrefs(req); p.TextSize != 140 || !p.Turns {
		t.Errorf("read prefs = %+v", p)
	}
}

func TestSettingsUsage(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	e.provider("anthropic", "Anth", `{"api_key":"k"}`)
	for _, r := range []string{"", "?range=30d", "?range=custom&from=2026-01-01&to=2026-01-31"} {
		e.mustOK(e.do("GET", "/settings/cost"+r, nil), "Anth", "No events", "$0.00", "0 turns")
	}
	e.mustOK(e.do("GET", "/settings/cost?range=custom&from=2026-01-01&to=2026-01-31", nil), "January 1 to 31, 2026", `type="date"`)
}

func TestSettingsProvidersFlow(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, true)
	id := e.provider("anthropic", "Mine", `{"api_key":"sk-ant-api03-abcdefgh1234"}`)

	e.mustOK(e.do("GET", "/settings/providers", nil), "Mine", "Not tested", "Model catalog", "Refresh now")

	// Anthropic is added, so its tile is gone; Custom is always offered.
	body := e.mustOK(e.do("GET", "/settings/providers/new", nil), "?t=custom", "Add provider")
	if strings.Contains(body, "?t=anthropic") {
		t.Error("an added provider is still offered")
	}
	e.mustOK(e.do("GET", "/settings/providers/new?t=custom", nil), `name="driver"`)
	if rec := e.do("POST", "/settings/providers", url.Values{"t": {"custom"}, "label": {"X"}}); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("custom without base url: %d", rec.Code)
	}

	page := e.mustOK(e.do("GET", "/settings/providers/"+id, nil), "Mine", "sk-ant-", "1234", "No models on yet", "Remove provider")
	if strings.Contains(page, "abcdefgh") {
		t.Error("the key leaked into the page")
	}
	e.mustOK(e.do("GET", "/settings/providers/"+id+"?remove=1", nil), "Remove Mine?", "/delete")
	e.mustOK(e.do("GET", "/settings/providers/"+id+"?key=1", nil), `name="api_key"`)

	// Save merges into the stored defaults.
	e.mustRedirect(e.do("POST", "/settings/providers/"+id, url.Values{"label": {"Renamed"}, "max_output_tokens": {"16,384"}, "temperature": {"0.5"}, "cache_enabled": {"false"}, "api_key": {"sk-new-key-9999"}}), "/settings/providers/"+id)
	got, _ := e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	p := got.Msg.GetProvider()
	ds := p.GetDefaultSettings()
	if p.GetLabel() != "Renamed" || ds.GetMaxOutputTokens() != 16384 || ds.GetTemperature() != 0.5 || ds.GetAnthropic().CacheEnabled == nil || ds.GetAnthropic().GetCacheEnabled() {
		t.Errorf("saved = %v / %v", p.GetLabel(), ds)
	}
	if !strings.Contains(string(p.GetConfig()), "sk-new-key-9999") {
		t.Error("key not replaced")
	}
	if rec := e.do("POST", "/settings/providers/"+id, url.Values{"max_output_tokens": {"lots"}}); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("bad number: %d", rec.Code)
	}

	// Full defaults round-trip every field the page posts.
	e.mustOK(e.do("GET", "/settings/providers/"+id+"/defaults", nil), "Renamed defaults", "OpenAI extras", "Not used by Renamed models")
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/defaults", url.Values{
		"temperature": {"0.7"}, "max_output_tokens": {"16,384"}, "top_k": {"40"}, "stop": {"</a>"}, "stop_new": {"END"}, "effort": {"high"},
		"cache_ttl": {"1h"}, "seed": {"7"}, "service_tier": {"priority"}, "harassment": {"none"}, "candidate_count": {"2"},
	}), "/settings/providers/"+id+"/defaults")
	got, _ = e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	ds = got.Msg.GetProvider().GetDefaultSettings()
	if ds.GetTopK() != 40 || len(ds.GetStopSequences()) != 2 || ds.GetThinking().GetEffort() != psmithv1.ThinkingEffort_THINKING_EFFORT_HIGH ||
		ds.GetAnthropic().GetCacheTtl() != psmithv1.CacheTTL_CACHE_TTL_1H || ds.GetOpenai().GetSeed() != 7 || ds.GetGoogle().GetCandidateCount() != 2 {
		t.Errorf("defaults = %v", ds)
	}
	if rec := e.do("POST", "/settings/providers/"+id+"/defaults", url.Values{"top_k": {"9000"}}); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("out of range top k: %d", rec.Code)
	}

	// Manual model, its page, save, favorite, defaults, disable.
	e.mustOK(e.do("GET", "/settings/providers/"+id+"/add-model", nil), "Add a model by hand")
	if rec := e.do("POST", "/settings/providers/"+id+"/add-model", url.Values{"model_id": {""}}); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("empty manual model: %d", rec.Code)
	}
	mid := "org/fine-tune:v2"
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/add-model", url.Values{
		"model_id": {mid}, "display_name": {"Tune"}, "context_window": {"262,144"}, "price_in": {"1.5"},
		"cap": {"streaming", "tool_use"}, "modality": {"text"},
	}), "/settings/providers/"+id+"/models/org/fine-tune:v2")
	mp := "/settings/providers/" + id + "/models/" + saModelPath(mid)
	e.mustOK(e.do("GET", mp, nil), "Tune", "262,144", "1.50", "Entered by hand", "Inherits 16,384 from Renamed", "Inherit (High)")

	e.mustRedirect(e.do("POST", mp, url.Values{"display_name": {"Tuned"}, "context_window": {""}, "price_out": {"3"}, "cap": {"vision"}, "modality": {"text", "image"}, "temperature": {"0.2"}, "effort": {"low"}}), mp)
	ms, _ := e.models.ListUserModels(e.ctx, connect.NewRequest(&psmithv1.ListUserModelsRequest{UserModelProviderId: id}))
	m := ms.Msg.GetModels()[0]
	if m.GetDisplayName() != "Tuned" || m.ContextWindow != nil || m.GetPricing().GetOutputPerMillionTokens() != 3 || !m.GetCapabilities().GetVision() ||
		m.GetCapabilities().GetToolUse() || len(m.GetModalities()) != 2 || m.GetDefaultSettings().GetTemperature() != 0.2 {
		t.Errorf("model = %v", m)
	}
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/model-op/favorite/"+saModelPath(mid), nil), mp)
	ms, _ = e.models.ListUserModels(e.ctx, connect.NewRequest(&psmithv1.ListUserModelsRequest{UserModelProviderId: id}))
	if !ms.Msg.GetModels()[0].GetFavorite() {
		t.Error("favorite not set")
	}
	e.mustOK(e.do("POST", "/settings/providers/"+id+"/model-op/refresh/"+saModelPath(mid), nil), "no entry for this model")
	md := "/settings/providers/" + id + "/model-defaults/" + saModelPath(mid)
	e.mustOK(e.do("GET", md, nil), "Tuned call settings")
	e.mustRedirect(e.do("POST", md, url.Values{"top_p": {"0.9"}}), md)
	ms, _ = e.models.ListUserModels(e.ctx, connect.NewRequest(&psmithv1.ListUserModelsRequest{UserModelProviderId: id}))
	if ms.Msg.GetModels()[0].GetDefaultSettings().GetTopP() != 0.9 {
		t.Error("model defaults not saved")
	}
	e.mustOK(e.do("GET", "/settings/providers/"+id, nil), "Tuned", "Models · 1 on")
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/model-op/disable/"+saModelPath(mid), nil), "/settings/providers/"+id)
	if rec := e.do("GET", mp, nil); rec.Code != http.StatusNotFound {
		t.Errorf("disabled model page: %d", rec.Code)
	}

	// The provider table's switch disables too.
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/add-model", url.Values{"model_id": {"m2"}, "display_name": {"M2"}}), "/settings/providers/"+id)
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/disable", url.Values{"model_id": {"m2"}}), "/settings/providers/"+id)
	e.mustOK(e.do("GET", "/settings/providers/"+id, nil), "No models on yet")

	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/delete", nil), "/settings/providers")
	if rec := e.do("GET", "/settings/providers/"+id, nil); rec.Code != http.StatusNotFound {
		t.Errorf("deleted provider page: %d", rec.Code)
	}
}

func TestSettingsProviderStatusRemembered(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("openai-compatible", "Local", `{"api_key":"x","base_url":"http://127.0.0.1:1/v1"}`)
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/test", nil), "/settings/providers/"+id)
	e.mustOK(e.do("GET", "/settings/providers/"+id, nil), "Connection failed")
	e.mustOK(e.do("GET", "/settings/providers", nil), "Last test failed", "127.0.0.1:1")
	e.mustOK(e.do("GET", "/settings/providers/"+id+"/discover", nil), "Discover failed")
}

func TestSettingsUsers(t *testing.T) {
	t.Parallel()
	member := newSAEnv(t, false)
	if rec := member.do("GET", "/settings/users", nil); rec.Code != http.StatusNotFound {
		t.Errorf("non-admin sees users: %d", rec.Code)
	}
	if rec := member.do("POST", "/settings/catalog/refresh", nil); rec.Code != http.StatusNotFound {
		t.Errorf("non-admin refreshes catalog: %d", rec.Code)
	}

	e := newSAEnv(t, true)
	e.mustOK(e.do("GET", "/settings/users?new=1", nil), `id="newuser"`, "You")
	e.mustRedirect(e.do("POST", "/settings/users", url.Values{"username": {"maya"}, "display_name": {"Maya"}, "password": {"pw"}}), "/settings/users")
	if rec := e.do("POST", "/settings/users", url.Values{"username": {"nopw"}}); rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), `value="nopw"`) {
		t.Errorf("create without password: %d", rec.Code)
	}
	users, _ := e.h.auth.ListUsers(e.ctx, connect.NewRequest(&psmithv1.ListUsersRequest{}))
	var maya string
	for _, u := range users.Msg.GetUsers() {
		if u.GetUsername() == "maya" {
			maya = u.GetId()
		}
	}
	if maya == "" {
		t.Fatal("maya not created")
	}
	e.mustOK(e.do("GET", "/settings/users?reset="+maya, nil), "New password for Maya")
	e.mustOK(e.do("GET", "/settings/users?delete="+maya, nil), "Delete Maya?")
	e.mustRedirect(e.do("POST", "/settings/users/"+maya+"/role", url.Values{"role": {"admin"}}), "/settings/users")
	e.mustOK(e.do("POST", "/settings/users/"+maya+"/password", url.Values{"password": {"fresh"}}), "Password set")
	row, _ := e.q.GetUserByID(e.ctx, uuid.MustParse(maya))
	if !row.IsAdmin || bcrypt.CompareHashAndPassword([]byte(row.PasswordHash), []byte("fresh")) != nil {
		t.Error("role or password not saved")
	}
	e.mustRedirect(e.do("POST", "/settings/users/"+maya+"/delete", nil), "/settings/users")
	if _, err := e.q.GetUserByID(e.ctx, uuid.MustParse(maya)); err == nil {
		t.Error("maya not deleted")
	}
	if rec := e.do("POST", "/settings/users/"+e.user.ID.String()+"/delete", nil); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("deleting yourself: %d", rec.Code)
	}
}
