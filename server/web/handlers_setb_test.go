package web

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/embeddersvc"
	"github.com/jdpedrie/psmith/server/langfuse"
	"github.com/jdpedrie/psmith/server/langfusesvc"
	"github.com/jdpedrie/psmith/server/profiles"
	"github.com/jdpedrie/psmith/server/speechsvc"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/testutil"

	// Registered for the global Plugins tests: one plugin with a shared key,
	// one that uses the embedder.
	_ "github.com/jdpedrie/psmith/plugins/brave_search"
	_ "github.com/jdpedrie/psmith/plugins/memory"
)

// setbEnv is a handler over a fresh database with one signed-in user.
type setbEnv struct {
	h    *Handler
	q    *store.Queries
	prof *profiles.Service
	ctx  context.Context
	uid  uuid.UUID
}

func newSetbEnv(t *testing.T) setbEnv {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	prof := profiles.NewService(q, pool, crypto.Nop{})
	emitter := langfuse.NewEmitter(slog.Default(), langfuse.EmitterConfig{})
	t.Cleanup(func() { emitter.Stop(context.Background()) })
	h := New(Deps{
		Queries: q, Auth: auth.NewService(q), Profiles: prof, Logger: slog.Default(),
		Embedder: embeddersvc.NewService(q, crypto.Nop{}, func(uuid.UUID) {}, slog.Default()),
		Langfuse: langfusesvc.NewService(q, crypto.Nop{}, emitter, slog.Default()),
		Speech:   speechsvc.NewService(q, crypto.Nop{}, slog.Default()),
	})
	ctx, uid := seedUserCtx(t, q)
	return setbEnv{h: h, q: q, prof: prof, ctx: ctx, uid: uid}
}

func (e setbEnv) get(fn http.HandlerFunc, target string, path map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", target, nil).WithContext(e.ctx)
	for k, v := range path {
		req.SetPathValue(k, v)
	}
	return do(fn, req)
}

func (e setbEnv) post(fn http.HandlerFunc, target string, path map[string]string, form url.Values) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", target, strings.NewReader(form.Encode())).WithContext(e.ctx)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for k, v := range path {
		req.SetPathValue(k, v)
	}
	return do(fn, req)
}

func (e setbEnv) profile(t *testing.T, name, parent string) string {
	t.Helper()
	req := &psmithv1.CreateProfileRequest{Name: name}
	if parent != "" {
		req.ParentProfileId = &parent
	}
	resp, err := e.prof.CreateProfile(e.ctx, connect.NewRequest(req))
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return resp.Msg.GetProfile().GetId()
}

func (e setbEnv) load(t *testing.T, id string) *psmithv1.Profile {
	t.Helper()
	resp, err := e.prof.GetProfile(e.ctx, connect.NewRequest(&psmithv1.GetProfileRequest{Id: id}))
	if err != nil {
		t.Fatalf("GetProfile: %v", err)
	}
	return resp.Msg.GetProfile()
}

func wantStatus(t *testing.T, rec *httptest.ResponseRecorder, code int) string {
	t.Helper()
	if rec.Code != code {
		t.Fatalf("status=%d want %d; body:\n%s", rec.Code, code, rec.Body.String())
	}
	return rec.Body.String()
}

func TestProfilesList_TreeDefaultAndMenu(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	chief := e.profile(t, "Chief", "")
	demo := e.profile(t, "Demo", chief)
	e.profile(t, "Pirate", "")

	body := wantStatus(t, e.post(e.h.handleProfileMakeDefault, "/", map[string]string{"id": chief}, nil), http.StatusSeeOther)
	_ = body
	if !e.load(t, chief).GetIsDefault() {
		t.Fatal("make default did not stick")
	}

	body = wantStatus(t, e.get(e.h.handleProfiles, "/settings/profiles", nil), http.StatusOK)
	for _, want := range []string{"3 profiles", "Parent of Demo.", "Inherits from Chief.", `class="sb-badge">Default`, "Make default", "/settings/profiles/" + demo + "/export"} {
		if !strings.Contains(body, want) {
			t.Errorf("list missing %q", want)
		}
	}
	// Demo sits right under its parent, indented.
	if i, j := strings.Index(body, `id="prow-`+chief), strings.Index(body, `id="prow-`+demo); i < 0 || j < i || !strings.Contains(body, `sb-prow d1" id="prow-`+demo) {
		t.Errorf("Demo not nested under Chief")
	}

	// The row's delete confirm comes back as a fragment.
	frag := wantStatus(t, e.get(e.h.handleProfiles, "/settings/profiles?confirm="+demo+"&fragment=prow-"+demo, nil), http.StatusOK)
	if !strings.Contains(frag, "Delete Demo?") || strings.Contains(frag, "<html") {
		t.Errorf("confirm fragment wrong:\n%s", frag)
	}

	// A parent with children can't go; the list explains in place.
	body = wantStatus(t, e.post(e.h.handleProfileDelete, "/", map[string]string{"id": chief}, url.Values{"from": {"list"}}), http.StatusOK)
	if !strings.Contains(body, `role="alert"`) {
		t.Errorf("delete refusal not shown")
	}
	wantStatus(t, e.post(e.h.handleProfileDelete, "/", map[string]string{"id": demo}, nil), http.StatusSeeOther)
}

func TestProfileGeneral_SavesEveryField(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	parent := e.profile(t, "Parent", "")
	id := e.profile(t, "Kid", "")

	body := wantStatus(t, e.get(e.h.handleProfileEdit, "/", map[string]string{"id": id}), http.StatusOK)
	if !strings.Contains(body, `aria-label="Profile sections"`) || !strings.Contains(body, ">Parent</option>") {
		t.Fatalf("general tab missing tabs or parent option")
	}

	form := url.Values{
		"name": {"Kid 2"}, "description": {"A kid"}, "parent": {parent},
		"default": {"true"}, "favorite": {"true"}, "parent_only": {"false"},
		"system_message": {"Be brief."}, "first_message": {"Hi"}, "welcome_message": {"Ahoy"},
	}
	wantStatus(t, e.post(e.h.handleProfileUpdate, "/", map[string]string{"id": id}, form), http.StatusSeeOther)
	p := e.load(t, id)
	if p.GetName() != "Kid 2" || p.GetParentProfileId() != parent || !p.GetIsDefault() || !p.GetFavorite() ||
		p.GetSystemMessage() != "Be brief." || p.GetDefaultUserMessage() != "Hi" || p.GetWelcomeMessage() != "Ahoy" {
		t.Fatalf("not saved: %+v", p)
	}

	// Emptying fields clears them back to inherit; switching default off clears it.
	form = url.Values{"name": {"Kid 2"}, "default": {"false"}}
	wantStatus(t, e.post(e.h.handleProfileUpdate, "/", map[string]string{"id": id}, form), http.StatusSeeOther)
	p = e.load(t, id)
	if p.SystemMessage != nil || p.ParentProfileId != nil || p.GetIsDefault() {
		t.Fatalf("not cleared: %+v", p)
	}

	body = wantStatus(t, e.post(e.h.handleProfileUpdate, "/", map[string]string{"id": id}, url.Values{"name": {" "}}), http.StatusBadRequest)
	if !strings.Contains(body, "A profile needs a name.") {
		t.Error("empty name not explained")
	}
}

func TestProfileCreate_WithParentAndDefault(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	parent := e.profile(t, "Parent", "")
	body := wantStatus(t, e.get(e.h.handleProfileNew, "/settings/profiles/new?parent="+parent, nil), http.StatusOK)
	if !strings.Contains(body, "Create profile") || !strings.Contains(body, `value="`+parent+`" selected`) {
		t.Fatalf("new form wrong:\n%s", body)
	}
	wantStatus(t, e.post(e.h.handleProfileCreate, "/", nil, url.Values{"name": {"Bad"}, "default": {"true"}, "parent_only": {"true"}}), http.StatusBadRequest)
	wantStatus(t, e.post(e.h.handleProfileCreate, "/", nil, url.Values{"name": {"Kid"}, "parent": {parent}, "default": {"true"}, "favorite": {"true"}}), http.StatusSeeOther)
	resp, _ := e.prof.ListProfiles(e.ctx, connect.NewRequest(&psmithv1.ListProfilesRequest{}))
	for _, p := range resp.Msg.GetProfiles() {
		if p.GetName() == "Bad" {
			t.Error("refused profile was created anyway")
		}
		if p.GetName() == "Kid" && (p.GetParentProfileId() != parent || !p.GetIsDefault() || !p.GetFavorite()) {
			t.Fatalf("created wrong: %+v", p)
		}
	}
}

func TestProfileModels_CallSettingsLayer(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	id := e.profile(t, "M", "")
	body := wantStatus(t, e.get(e.h.handleProfileModels, "/", map[string]string{"id": id}), http.StatusOK)
	for _, want := range []string{"Compression mode", "Thinking effort", "Prompt caching", `aria-current="page">Models`} {
		if !strings.Contains(body, want) {
			t.Errorf("models tab missing %q", want)
		}
	}
	form := url.Values{"temperature": {"0.7"}, "max_output_tokens": {"16,384"}, "thinking_effort": {"high"}, "prompt_caching": {"off"}, "compression_mode": {"APPEND"}, "title_guide": {"Short"}}
	wantStatus(t, e.post(e.h.handleProfileModelsSave, "/", map[string]string{"id": id}, form), http.StatusSeeOther)
	cs := e.load(t, id).GetDefaultSettings().GetCallSettings()
	if cs.GetTemperature() != 0.7 || cs.GetMaxOutputTokens() != 16384 || cs.GetThinking().GetEffort() != psmithv1.ThinkingEffort_THINKING_EFFORT_HIGH || cs.ExplicitCache == nil || cs.GetExplicitCache() {
		t.Fatalf("call settings not saved: %+v", cs)
	}
	if p := e.load(t, id); p.GetCompressionMode() != psmithv1.CompressionMode_COMPRESSION_MODE_APPEND || p.GetTitleGuide() != "Short" {
		t.Fatalf("mode/guide not saved: %+v", p)
	}

	// Blank inherits again.
	wantStatus(t, e.post(e.h.handleProfileModelsSave, "/", map[string]string{"id": id}, url.Values{}), http.StatusSeeOther)
	cs = e.load(t, id).GetDefaultSettings().GetCallSettings()
	if cs.Temperature != nil || cs.MaxOutputTokens != nil || cs.Thinking != nil || cs.ExplicitCache != nil {
		t.Fatalf("not cleared: %+v", cs)
	}

	body = wantStatus(t, e.post(e.h.handleProfileModelsSave, "/", map[string]string{"id": id}, url.Values{"temperature": {"hot"}}), http.StatusBadRequest)
	if !strings.Contains(body, "Temperature is a number") {
		t.Error("bad temperature not explained")
	}
}

func TestProfilePlugins_InheritedSwitchAndRemove(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	parent := e.profile(t, "Parent", "")
	kid := e.profile(t, "Kid", parent)
	set := func(id string, names ...string) {
		var ps []*psmithv1.ProfilePlugin
		for _, n := range names {
			ps = append(ps, &psmithv1.ProfilePlugin{PluginName: n, Config: []byte("{}")})
		}
		if _, err := e.prof.SetProfilePlugins(e.ctx, connect.NewRequest(&psmithv1.SetProfilePluginsRequest{ProfileId: id, Plugins: ps})); err != nil {
			t.Fatalf("SetProfilePlugins: %v", err)
		}
	}
	set(parent, "basic_grounding")
	set(kid, "lettered_choices")

	body := wantStatus(t, e.get(e.h.handlePluginsPage, "/", map[string]string{"id": kid}), http.StatusOK)
	for _, want := range []string{"From Parent", `name="inh_name_0" value="basic_grounding"`, `name="pname_0" value="lettered_choices"`, "Add plugin"} {
		if !strings.Contains(body, want) {
			t.Errorf("plugins tab missing %q", want)
		}
	}

	// Switch the inherited one off and remove the attached one in one save.
	form := url.Values{"inh_name_0": {"basic_grounding"}, "inh_on_0": {"false"}, "pname_0": {"lettered_choices"}, "premoved_0": {"true"}}
	wantStatus(t, e.post(e.h.handlePluginsSave, "/", map[string]string{"id": kid}, form), http.StatusSeeOther)
	got := e.h.profilePlugins(e.ctx, kid)
	if len(got) != 1 || got[0].GetPluginName() != "basic_grounding" || !got[0].GetDisabled() {
		t.Fatalf("pipeline after save = %+v", got)
	}
	body = wantStatus(t, e.get(e.h.handlePluginsPage, "/", map[string]string{"id": kid}), http.StatusOK)
	if !strings.Contains(body, "Off for Kid.") || !strings.Contains(body, `aria-checked="false"`) {
		t.Error("switched-off plugin not shown off")
	}

	// Adding a plugin that is switched off replaces the off row.
	wantStatus(t, e.post(e.h.handlePluginAdd, "/", map[string]string{"id": kid}, url.Values{"plugin_name": {"basic_grounding"}}), http.StatusSeeOther)
	got = e.h.profilePlugins(e.ctx, kid)
	if len(got) != 1 || got[0].GetDisabled() {
		t.Fatalf("after add = %+v", got)
	}
}

func TestProfileShare_ExportImportDelete(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	id := e.profile(t, "Pirate", "")

	body := wantStatus(t, e.get(e.h.handleProfileShare, "/", map[string]string{"id": id}), http.StatusOK)
	for _, want := range []string{"Download ", "Import a profile", "Delete Pirate", `aria-current="page">Share`} {
		if !strings.Contains(body, want) {
			t.Errorf("share tab missing %q", want)
		}
	}
	frag := wantStatus(t, e.get(e.h.handleProfileShare, "/?delete=1&fragment=sb-delete", map[string]string{"id": id}), http.StatusOK)
	if !strings.Contains(frag, "Delete Pirate?") || strings.Contains(frag, "<html") {
		t.Errorf("delete confirm fragment wrong")
	}

	rec := e.get(e.h.handleProfileExport, "/", map[string]string{"id": id})
	payload := rec.Body.Bytes()
	if rec.Code != http.StatusOK || !strings.Contains(rec.Header().Get("Content-Disposition"), ".psmithprofile") || !bytes.HasPrefix(payload, bundleMagic) {
		t.Fatalf("export: code=%d disp=%q", rec.Code, rec.Header().Get("Content-Disposition"))
	}

	// Review: a dry run that names the rename and creates nothing.
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	_ = mw.WriteField("from", id)
	fw, _ := mw.CreateFormFile("file", "pirate.psmithprofile")
	_, _ = fw.Write(payload)
	_ = mw.Close()
	req := httptest.NewRequest("POST", "/settings/profiles/import", &buf).WithContext(e.ctx)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	body = wantStatus(t, do(e.h.handleProfileImport, req), http.StatusOK)
	for _, want := range []string{"pirate.psmithprofile", "1 profile · exported by u", "Renamed to <strong>Pirate (2)</strong>", "Nothing is created until you import."} {
		if !strings.Contains(body, want) {
			t.Errorf("review missing %q", want)
		}
	}
	if n := countProfiles(t, e); n != 1 {
		t.Fatalf("review created profiles: %d", n)
	}

	// Commit posts the payload back.
	enc := between(body, `name="payload" value="`, `"`)
	rec = e.post(e.h.handleProfileImport, "/", nil, url.Values{"payload": {enc}})
	wantStatus(t, rec, http.StatusSeeOther)
	if n := countProfiles(t, e); n != 2 {
		t.Fatalf("import created %d profiles, want 2 total", n)
	}

	// Garbage is refused with a reason, on the import page.
	body = wantStatus(t, e.post(e.h.handleProfileImport, "/", nil, url.Values{"payload": {"!!!"}}), http.StatusOK)
	if !strings.Contains(body, "Choose it again") {
		t.Error("bad payload not explained")
	}

	wantStatus(t, e.post(e.h.handleProfileDelete, "/", map[string]string{"id": id}, nil), http.StatusSeeOther)
}

func countProfiles(t *testing.T, e setbEnv) int {
	t.Helper()
	resp, err := e.prof.ListProfiles(e.ctx, connect.NewRequest(&psmithv1.ListProfilesRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	return len(resp.Msg.GetProfiles())
}

func between(s, a, b string) string {
	i := strings.Index(s, a)
	if i < 0 {
		return ""
	}
	s = s[i+len(a):]
	return s[:strings.Index(s, b)]
}

func TestGlobalPlugins_SharedSettings(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	body := wantStatus(t, e.get(e.h.handleGlobalPlugins, "/settings/plugins", nil), http.StatusOK)
	if !strings.Contains(body, "Needs an API key") || !strings.Contains(body, "Uses the") {
		t.Fatalf("plugins page missing statuses:\n%s", body)
	}
	body = wantStatus(t, e.get(e.h.handleGlobalPluginConfig, "/", map[string]string{"name": "brave_search"}), http.StatusOK)
	if !strings.Contains(body, `name="cfg_api_key"`) || !strings.Contains(body, `type="password"`) || !strings.Contains(body, "Per-profile settings") {
		t.Fatalf("config page missing the key field")
	}
	wantStatus(t, e.post(e.h.handleGlobalPluginConfigSave, "/", map[string]string{"name": "brave_search"}, url.Values{"cfg_api_key": {"BSA-1"}}), http.StatusSeeOther)
	got, err := e.prof.GetUserPluginSettings(e.ctx, connect.NewRequest(&psmithv1.GetUserPluginSettingsRequest{PluginName: "brave_search"}))
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]string
	_ = json.Unmarshal(got.Msg.GetSettings().GetConfig(), &cfg)
	if cfg["api_key"] != "BSA-1" {
		t.Fatalf("global key not saved: %s", got.Msg.GetSettings().GetConfig())
	}
	body = wantStatus(t, e.get(e.h.handleGlobalPlugins, "/settings/plugins", nil), http.StatusOK)
	if strings.Contains(body, "Needs an API key") {
		t.Error("still needs a key after saving one")
	}
	wantStatus(t, e.get(e.h.handleGlobalPluginConfig, "/", map[string]string{"name": "nope"}), http.StatusNotFound)
}

func TestMCPServers_StatusDetailAndConfirm(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	// Nothing listens on port 1, so the probe fails fast.
	rec := e.post(e.h.handleMCPServerSave, "/", nil, url.Values{"name": {"Dead"}, "transport": {"http"}, "url": {"http://127.0.0.1:1/mcp"}, "headers": {"Authorization: x"}})
	wantStatus(t, rec, http.StatusSeeOther)
	id := strings.TrimPrefix(rec.Header().Get("Location"), "/settings/mcp-servers/")

	body := wantStatus(t, e.get(e.h.handleMCPServers, "/settings/mcp-servers", nil), http.StatusOK)
	if !strings.Contains(body, "Failing") || !strings.Contains(body, "1 failing") || !strings.Contains(body, "http · http://127.0.0.1:1/mcp") {
		t.Fatalf("list status wrong")
	}
	body = wantStatus(t, e.get(e.h.handleMCPServerDetail, "/", map[string]string{"id": id}), http.StatusOK)
	for _, want := range []string{"Stored encrypted", "Tools · 0", `class="result bad"`, "Delete Dead"} {
		if !strings.Contains(body, want) {
			t.Errorf("detail missing %q", want)
		}
	}
	frag := wantStatus(t, e.get(e.h.handleMCPServerDetail, "/?delete=1&fragment=sb-delete", map[string]string{"id": id}), http.StatusOK)
	if !strings.Contains(frag, "Delete Dead?") {
		t.Error("confirm fragment wrong")
	}
	body = wantStatus(t, e.post(e.h.handleMCPServerSave, "/", nil, url.Values{"name": {""}, "transport": {"http"}, "headers": {"K: v"}}), http.StatusBadRequest)
	if !strings.Contains(body, "name is required") || !strings.Contains(body, "K: v") {
		t.Error("failed save should explain and keep what was typed")
	}
	// In-process servers take their name from their own field.
	rec = e.post(e.h.handleMCPServerSave, "/", nil, url.Values{"name": {"Local"}, "transport": {"inproc"}, "command": {""}, "inproc_server": {"psmith"}})
	wantStatus(t, rec, http.StatusSeeOther)
	servers, _ := e.h.listMCPServers(e.ctx)
	for _, s := range servers {
		if s.GetName() == "Local" && s.GetCommand() != "psmith" {
			t.Errorf("inproc server name = %q", s.GetCommand())
		}
	}
}

func TestSpeechSettings(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	body := wantStatus(t, e.get(e.h.handleSpeech, "/settings/speech", nil), http.StatusOK)
	if !strings.Contains(body, "On-device") || !strings.Contains(body, "Reset to on-device") {
		t.Fatalf("speech page wrong")
	}
	// Only on-device is registered in this binary; the drivers live in main.
	form := url.Values{"kind": {"apple_local"}, "voice": {"alloy"}, "model": {"tts-1"}, "speed": {"1.2"}, "api_key": {"sk-1"}}
	wantStatus(t, e.post(e.h.handleSpeechSave, "/", nil, form), http.StatusSeeOther)
	c := speechConfig(t, e)
	if c.GetKind() != "apple_local" || c.GetVoice() != "alloy" || c.GetSpeed() != 1.2 || !c.GetApiKeySet() {
		t.Fatalf("not saved: %+v", c)
	}
	body = wantStatus(t, e.get(e.h.handleSpeech, "/settings/speech", nil), http.StatusOK)
	if !strings.Contains(body, maskedSecret) || !strings.Contains(body, "1.2×") || strings.Contains(body, "sk-1") {
		t.Error("saved page should mask the key and show the speed")
	}
	wantStatus(t, e.post(e.h.handleSpeechKeyDelete, "/", nil, nil), http.StatusSeeOther)
	if speechConfig(t, e).GetApiKeySet() {
		t.Error("key survived remove")
	}
	frag := wantStatus(t, e.get(e.h.handleSpeech, "/settings/speech?reset=1&fragment=sb-reset", nil), http.StatusOK)
	if !strings.Contains(frag, "Reset speech to on-device?") || !strings.Contains(frag, "formaction") {
		t.Error("reset confirm wrong")
	}
	wantStatus(t, e.post(e.h.handleSpeechDelete, "/", nil, nil), http.StatusSeeOther)
	if k := speechConfig(t, e).GetKind(); k != "apple_local" {
		t.Errorf("after reset kind=%q", k)
	}
}

func speechConfig(t *testing.T, e setbEnv) *psmithv1.SpeechConfig {
	t.Helper()
	resp, err := e.h.speech.GetSpeechConfig(e.ctx, connect.NewRequest(&psmithv1.GetSpeechConfigRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	return resp.Msg.GetConfig()
}

func TestEmbedderLangfuse_RemoveConfirmsInPlace(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	body := wantStatus(t, e.get(e.h.handleEmbedder, "/settings/embedder", nil), http.StatusOK)
	if !strings.Contains(body, "Messages waiting") || !strings.Contains(body, "Worker idle") {
		t.Errorf("embedder state missing")
	}
	frag := wantStatus(t, e.get(e.h.handleEmbedder, "/?remove=1&fragment=sb-remove", nil), http.StatusOK)
	if !strings.Contains(frag, "Remove the embedder configuration?") {
		t.Error("embedder confirm wrong")
	}
	wantStatus(t, e.post(e.h.handleEmbedderDelete, "/", nil, nil), http.StatusSeeOther)

	body = wantStatus(t, e.get(e.h.handleLangfuse, "/settings/langfuse", nil), http.StatusOK)
	if !strings.Contains(body, `name="secret_key"`) || !strings.Contains(body, "None since the server started") {
		t.Errorf("unconfigured langfuse should ask for the secret")
	}
	frag = wantStatus(t, e.get(e.h.handleLangfuse, "/?remove=1&fragment=sb-remove", nil), http.StatusOK)
	if !strings.Contains(frag, "Remove the Langfuse configuration?") {
		t.Error("langfuse confirm wrong")
	}
	wantStatus(t, e.post(e.h.handleLangfuseDelete, "/", nil, nil), http.StatusSeeOther)
}

// --- pure helpers ---

func TestSetbHelpers(t *testing.T) {
	t.Parallel()
	if got := thousands(1234567); got != "1,234,567" {
		t.Errorf("thousands=%q", got)
	}
	if got := thousands(-1204); got != "-1,204" {
		t.Errorf("thousands neg=%q", got)
	}
	now := time.Date(2026, 11, 8, 10, 46, 0, 0, time.UTC)
	if got := agoLabel(now, now.Add(-4*time.Minute)); got != "4 min ago · 10:42" {
		t.Errorf("agoLabel=%q", got)
	}
	if got := shortErr("exit status 1: FIRECRAWL_API_KEY is not set"); got != "exit status 1" {
		t.Errorf("shortErr=%q", got)
	}
	if got := bundleSummary([]byte("nope")); got != "" {
		t.Errorf("bundleSummary on junk=%q", got)
	}
	if got := joinAnd([]string{"A", "B", "C"}); got != "A, B and C" {
		t.Errorf("joinAnd=%q", got)
	}

	brave := &psmithv1.PluginType{Name: "b", ConfigFields: []*psmithv1.ConfigField{
		{Name: "api_key", Display: "API key", Global: true, Required: true, Type: psmithv1.ConfigField_TEXT},
		{Name: "count", Type: psmithv1.ConfigField_NUMBER, DefaultJson: "5"},
		{Name: "model", Required: true, Type: psmithv1.ConfigField_MODEL_PICKER},
		{Name: "safe", Type: psmithv1.ConfigField_SELECT, DefaultJson: `"moderate"`, Options: []*psmithv1.ConfigOption{{Value: "moderate", Label: "Moderate"}}},
	}}
	if got := globalNeeds(brave, nil); got != "Needs an API key" {
		t.Errorf("globalNeeds=%q", got)
	}
	if got := globalNeeds(brave, []byte(`{"api_key":"k"}`)); got != "" {
		t.Errorf("globalNeeds set=%q", got)
	}
	if got := requiredMissing(brave, []byte(`{}`)); got != 1 {
		t.Errorf("requiredMissing=%d", got)
	}
	if got := fieldDefaultSummary(brave.ConfigFields[3]); got != "Default Moderate" {
		t.Errorf("summary=%q", got)
	}
	if got := fieldDefaultSummary(brave.ConfigFields[2]); got != "Not set by default" {
		t.Errorf("summary=%q", got)
	}
	cfg, _ := assembleGlobalConfig(brave, []byte(`{"count":3}`), func(f string) string { return map[string]string{"api_key": "z"}[f] })
	if string(cfg) != `{"api_key":"z","count":3}` {
		t.Errorf("assembleGlobalConfig=%s", cfg)
	}
	if fs := configFieldVMs(brave, nil, nil, true); len(fs) != 1 || !fs[0].Secret {
		t.Errorf("global fields=%+v", fs)
	}

	ix := profileIndex{byID: map[string]*psmithv1.Profile{}}
	pa, pb := "a", "a"
	for _, p := range []*psmithv1.Profile{{Id: "c", Name: "C", ParentProfileId: &pb}, {Id: "a", Name: "A"}, {Id: "b", Name: "B", ParentProfileId: &pa}} {
		ix.list = append(ix.list, p)
		ix.byID[p.Id] = p
	}
	rows := profileRows(ix, nil)
	if len(rows) != 3 || rows[0].ID != "a" || rows[1].Depth != 1 || rows[2].Depth != 1 {
		t.Errorf("profileRows=%+v", rows)
	}
	if opts := parentOpts(ix, "a", ""); len(opts) != 1 {
		t.Errorf("a's descendants offered as parents: %+v", opts)
	}
}
