package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/store"
)

// addManual adds a model by hand and returns nothing; failures stop the test.
func (e *saEnv) addManual(prov string, req *psmithv1.AddManualModelRequest) {
	e.t.Helper()
	req.UserModelProviderId = prov
	if _, err := e.models.AddManualModel(e.ctx, connect.NewRequest(req)); err != nil {
		e.t.Fatalf("AddManualModel: %v", err)
	}
}

func (e *saEnv) providerModels(prov string) (on, off []*psmithv1.UserModel) {
	e.t.Helper()
	resp, err := e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: prov}))
	if err != nil {
		e.t.Fatal(err)
	}
	return resp.Msg.GetEnabledModels(), resp.Msg.GetDisabledModels()
}

// A hand-added model that is off keeps its row on the server, so the
// provider's list draws it with its switch off; the switch turns it back on.
func TestSetaOffManualModelRow(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	e.addManual(id, &psmithv1.AddManualModelRequest{ModelId: "ft-1", DisplayName: "Support tune"})
	e.addManual(id, &psmithv1.AddManualModelRequest{ModelId: "ft-2", DisplayName: "Another"})
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/disable", url.Values{"model_id": {"ft-1"}}), "/settings/providers/"+id)

	body := e.mustOK(e.do("GET", "/settings/providers/"+id, nil), "Models · 1 on", "Support tune", "Added by hand",
		`aria-checked="false" aria-label="Support tune on" name="model_ids" value="ft-1"`)
	if strings.Contains(body, `href="/settings/providers/`+id+`/models/ft-1"`) {
		t.Error("the off row links to a model page that can't load")
	}
	if strings.Index(body, "Another") > strings.Index(body, "Support tune") {
		t.Error("the off row lists before the one that is on")
	}

	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/enable", url.Values{"model_ids": {"ft-1"}}), "/settings/providers/"+id)
	if on, off := e.providerModels(id); len(on) != 2 || len(off) != 0 {
		t.Fatalf("on %d, off %d; want 2, 0", len(on), len(off))
	}
}

// Delete removes a hand-added model for good: from its off row, after the row
// asks in place, and from the model page's Delete section.
func TestSetaDeleteManualModel(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	base := "/settings/providers/" + id
	e.addManual(id, &psmithv1.AddManualModelRequest{ModelId: "org/ft:1", DisplayName: "Draft tune"})
	e.addManual(id, &psmithv1.AddManualModelRequest{ModelId: "ft-2", DisplayName: "Kept tune"})
	e.mustRedirect(e.do("POST", base+"/disable", url.Values{"model_id": {"org/ft:1"}}), base)

	page := e.mustOK(e.do("GET", base, nil), `aria-label="Delete Draft tune"`)
	if strings.Contains(page, "Delete Draft tune?") {
		t.Error("the row asks before Delete was pressed")
	}
	e.mustOK(e.do("GET", base+"?delmodel="+url.QueryEscape("org/ft:1"), nil), "Delete Draft tune?", "won’t bring it back",
		`formaction="`+base+`/delete-model/org/ft:1"`)
	e.mustRedirect(e.do("POST", base+"/delete-model/org/ft:1", nil), base)
	if _, off := e.providerModels(id); len(off) != 0 {
		t.Fatalf("the off model is still kept: %v", off)
	}

	// The model page of a hand-added model that is on has a Delete section.
	mp := base + "/models/ft-2"
	body := e.mustOK(e.do("GET", mp, nil), `id="mdelete"`, "Delete model")
	if strings.Contains(body, "Delete Kept tune?") {
		t.Error("the model page asks before Delete was pressed")
	}
	e.mustOK(e.do("GET", mp+"?delete=1", nil), "Delete Kept tune?", `formaction="`+base+`/delete-model/ft-2"`)
	e.mustRedirect(e.do("POST", base+"/delete-model/ft-2", nil), base)
	if on, off := e.providerModels(id); len(on) != 0 || len(off) != 0 {
		t.Fatalf("on %d, off %d after delete; want none", len(on), len(off))
	}
}

// A model from the provider's own list can't be deleted, only turned off, so
// its page has no Delete section.
func TestSetaDiscoveredModelHasNoDelete(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	if _, err := e.q.UpsertUserModel(e.ctx, store.UpsertUserModelParams{
		UserModelProviderID: uuid.MustParse(id), ModelID: "m1", DisplayName: "M1",
		MetadataSource: "catalog", MetadataSnapshotAt: time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}
	if body := e.mustOK(e.do("GET", "/settings/providers/"+id+"/models/m1", nil)); strings.Contains(body, `id="mdelete"`) {
		t.Error("a catalog model offers Delete")
	}
}

// An OpenAI-compatible provider's page edits its base URL and model catalog,
// as the Mac's does. Saving sends only those keys, so the stored key stays.
func TestSetaCompatibleBaseURLAndCatalog(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("openai-compatible", "Home Ollama", `{"api_key":"secret","base_url":"http://localhost:11434/v1"}`)
	base := "/settings/providers/" + id

	tresp, err := e.models.ListProviderTemplates(e.ctx, connect.NewRequest(&psmithv1.ListProviderTemplatesRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	var cat, catName string
	for _, tp := range tresp.Msg.GetTemplates() {
		if tp.GetDriverType() == "openai-compatible" && tp.GetCatalogProviderId() != "" {
			cat, catName = tp.GetCatalogProviderId(), tp.GetName()
			break
		}
	}
	if cat == "" {
		t.Fatal("no OpenAI-compatible template names a catalog")
	}

	e.mustOK(e.do("GET", base, nil), `name="base_url"`, `value="http://localhost:11434/v1"`, `<option value="" selected>None</option>`,
		`<option value="`+cat+`">`+catName+`</option>`)

	e.mustRedirect(e.do("POST", base, url.Values{"label": {"Home Ollama"}, "base_url": {" http://10.0.0.12:11434/v1 "}, "catalog": {cat}}), base)
	got, _ := e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	var cfg map[string]string
	_ = json.Unmarshal(got.Msg.GetProvider().GetConfig(), &cfg)
	if cfg["base_url"] != "http://10.0.0.12:11434/v1" || cfg["catalog_provider_id"] != cat || cfg["api_key"] != "secret" {
		t.Errorf("config after save: %v", cfg)
	}
	e.mustOK(e.do("GET", base, nil), `value="http://10.0.0.12:11434/v1"`, `<option value="`+cat+`" selected>`)

	// None clears the catalog; an empty base URL is refused.
	e.mustRedirect(e.do("POST", base, url.Values{"base_url": {"http://10.0.0.12:11434/v1"}, "catalog": {""}}), base)
	got, _ = e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	cfg = nil
	_ = json.Unmarshal(got.Msg.GetProvider().GetConfig(), &cfg)
	if cfg["catalog_provider_id"] != "" {
		t.Errorf("None left catalog %q", cfg["catalog_provider_id"])
	}
	if rec := e.do("POST", base, url.Values{"base_url": {"  "}}); rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "needs a base URL") {
		t.Errorf("empty base URL: %d", rec.Code)
	}

	// Native drivers keep their host: no field to change it.
	aid := e.provider("anthropic", "Anthropic", `{"api_key":"k"}`)
	if body := e.mustOK(e.do("GET", "/settings/providers/"+aid, nil)); strings.Contains(body, `name="base_url"`) || strings.Contains(body, `name="catalog"`) {
		t.Error("an Anthropic provider shows base URL or catalog fields")
	}
}

// The model page and Add model carry the knowledge cutoff, as Mac and iOS do.
func TestSetaKnowledgeCutoff(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	base := "/settings/providers/" + id

	e.mustRedirect(e.do("POST", base+"/add-model", url.Values{"model_id": {"m1"}, "display_name": {"M1"}, "knowledge_cutoff": {"2025-03-01"}}), base+"/models/m1")
	on, _ := e.providerModels(id)
	if len(on) != 1 || on[0].GetKnowledgeCutoff() != "2025-03-01" {
		t.Fatalf("add didn't store the cutoff: %v", on)
	}
	e.mustOK(e.do("GET", base+"/models/m1", nil), `name="knowledge_cutoff" type="date"`, `value="2025-03-01"`, "Knowledge cutoff")
	e.mustOK(e.do("GET", base+"/add-model", nil), `name="knowledge_cutoff"`)

	form := url.Values{"display_name": {"M1"}, "cap": {"streaming"}, "modality": {"text"}, "knowledge_cutoff": {"2024-12-31"}}
	e.mustRedirect(e.do("POST", base+"/models/m1", form), base+"/models/m1")
	if on, _ = e.providerModels(id); on[0].GetKnowledgeCutoff() != "2024-12-31" {
		t.Errorf("cutoff %q, want 2024-12-31", on[0].GetKnowledgeCutoff())
	}
	form.Set("knowledge_cutoff", "March")
	if rec := e.do("POST", base+"/models/m1", form); rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "Knowledge cutoff must be a date") {
		t.Errorf("a bad date: %d", rec.Code)
	}
	form.Set("knowledge_cutoff", "")
	e.mustRedirect(e.do("POST", base+"/models/m1", form), base+"/models/m1")
	if on, _ = e.providerModels(id); on[0].KnowledgeCutoff != nil {
		t.Errorf("clearing left %q", on[0].GetKnowledgeCutoff())
	}
}

// A model whose constraints lock its temperature shows the locked value read
// only, on its page and its full call settings, and saving keeps what's
// stored. A model with a range refuses a temperature outside it.
func TestSetaLockedTemperature(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("openai-compatible", "OpenAI", `{"api_key":"k","base_url":"http://127.0.0.1:1/v1"}`)
	base := "/settings/providers/" + id
	keep := 0.4
	e.addManual(id, &psmithv1.AddManualModelRequest{ModelId: "gpt-5-mini", DisplayName: "GPT-5 mini", DefaultSettings: &psmithv1.CallSettings{Temperature: &keep}})

	for _, path := range []string{base + "/models/gpt-5-mini", base + "/model-defaults/gpt-5-mini"} {
		body := e.mustOK(e.do("GET", path, nil), "This model locks temperature at 1.", `class="field num locked"`, `value="1" readonly`)
		if strings.Contains(body, `name="temperature"`) {
			t.Errorf("%s: the locked temperature is still a field", path)
		}
	}
	e.mustRedirect(e.do("POST", base+"/models/gpt-5-mini", url.Values{"display_name": {"GPT-5 mini"}, "temperature": {"0.2"}}), base+"/models/gpt-5-mini")
	e.mustRedirect(e.do("POST", base+"/model-defaults/gpt-5-mini", url.Values{"temperature": {"0.2"}}), base+"/model-defaults/gpt-5-mini")
	if on, _ := e.providerModels(id); on[0].GetDefaultSettings().GetTemperature() != keep {
		t.Errorf("temperature %v after saves, want the stored %v", on[0].GetDefaultSettings().GetTemperature(), keep)
	}

	aid := e.provider("anthropic", "Anthropic", `{"api_key":"k"}`)
	abase := "/settings/providers/" + aid
	e.addManual(aid, &psmithv1.AddManualModelRequest{ModelId: "my-claude", DisplayName: "My Claude"})
	if body := e.mustOK(e.do("GET", abase+"/models/my-claude", nil)); !strings.Contains(body, `name="temperature"`) {
		t.Error("an unlocked temperature lost its field")
	}
	rec := e.do("POST", abase+"/models/my-claude", url.Values{"display_name": {"My Claude"}, "temperature": {"1.5"}})
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "My Claude takes a temperature from 0 to 1") {
		t.Errorf("out of the model's range: %d", rec.Code)
	}
	if rec := e.do("POST", abase+"/model-defaults/my-claude", url.Values{"temperature": {"1.5"}}); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("defaults page, out of range: %d", rec.Code)
	}
}

// Test on a row of the provider's list reports in that row.
func TestSetaRowTest(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("openai-compatible", "Nowhere", `{"api_key":"k","base_url":"http://127.0.0.1:1/v1"}`)
	e.addManual(id, &psmithv1.AddManualModelRequest{ModelId: "a", DisplayName: "Alpha"})
	e.addManual(id, &psmithv1.AddManualModelRequest{ModelId: "b", DisplayName: "Beta"})
	base := "/settings/providers/" + id
	e.mustOK(e.do("GET", base, nil), `formaction="`+base+`/row-test/b"`, `hx-target="#mtest-1"`)

	body := e.mustOK(e.do("POST", base+"/row-test/b", nil))
	i := strings.Index(body, `id="mtest-1"`)
	if i < 0 {
		t.Fatal("no result slot for the second row")
	}
	if slot := body[i:min(len(body), i+400)]; !strings.Contains(slot, "Test failed") {
		t.Errorf("Beta's slot holds no outcome: %s", slot)
	}
	if j := strings.Index(body, `id="mtest-0"`); strings.Contains(body[j:i], "Test failed") {
		t.Error("the outcome landed on Alpha's row too")
	}
}

// A context warning that isn't a number says so beside the field, keeping
// what was typed. It used to reopen the field with no message.
func TestSetaWarningNotANumber(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	rec := e.do("POST", "/settings/general/warning", url.Values{"warn": {"custom"}, "custom": {"lots"}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status %d, want 422", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{`role="alert"`, "The warning must be a whole number, not &#34;lots&#34;", `value="lots"`, `aria-invalid`} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q", want)
		}
	}
	if rec := e.do("POST", "/settings/general/warning", url.Values{"warn": {"custom"}, "custom": {"-5"}}); rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "below zero") {
		t.Errorf("negative: %d", rec.Code)
	}
}

// "Password changed just now" shows once, on the page the change lands on;
// reloading doesn't say it again.
func TestSetaPasswordChangedShowsOnce(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	rec := e.do("POST", "/settings/general/password", url.Values{"current": {"old-pass"}, "new": {"new-pass"}, "confirm": {"new-pass"}})
	if loc := e.mustRedirect(rec, "/settings/general"); loc != "/settings/general" {
		t.Errorf("redirect to %q carries state a reload repeats", loc)
	}
	cookies := rec.Result().Cookies()

	get := func(cs []*http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "/settings/general", nil).WithContext(e.ctx)
		for _, c := range cs {
			req.AddCookie(c)
		}
		mux := http.NewServeMux()
		e.h.mountSettingsAWith(mux, func(next http.HandlerFunc) http.HandlerFunc { return next })
		out := httptest.NewRecorder()
		mux.ServeHTTP(out, req)
		return out
	}
	first := get(cookies)
	e.mustOK(first, "Password changed just now")
	cleared := false
	for _, c := range first.Result().Cookies() {
		if c.Name == pwFlashCookie && c.MaxAge < 0 {
			cleared = true
		}
	}
	if !cleared {
		t.Error("showing the message didn't clear it")
	}
	if body := e.mustOK(get(nil)); strings.Contains(body, "Password changed") {
		t.Error("a reload says the password changed again")
	}
	if body := e.mustOK(e.do("GET", "/settings/general?pw=ok", nil)); strings.Contains(body, "Password changed") {
		t.Error("the old ?pw=ok link still claims a change")
	}
}

// A number Add model can't read names its field.
func TestSetaAddModelNumberErrorNamesField(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	for field, want := range map[string]string{
		"context_window": "Context window must be a whole number, not &#34;abc&#34;",
		"max_output":     "Max output must be a whole number, not &#34;abc&#34;",
		"price_in":       "Input price must be a number, not &#34;abc&#34;",
	} {
		rec := e.do("POST", "/settings/providers/"+id+"/add-model", url.Values{"model_id": {"m"}, "display_name": {"M"}, field: {"abc"}})
		if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), want) {
			t.Errorf("%s: status %d, want %q", field, rec.Code, want)
		}
	}
}

// A row's Test outcome reads as the board draws it.
func TestSetaRowTestResultText(t *testing.T) {
	t.Parallel()
	ok := rowTestResult(connect.NewResponse(&psmithv1.TestUserModelResponse{Ok: true, LatencyMs: 840, InputTokens: 14, OutputTokens: 2}), nil)
	if !ok.OK || ok.Message != "Answered in 840 ms · 14 tokens in, 2 out" {
		t.Errorf("ok: %+v", ok)
	}
	bad := rowTestResult(connect.NewResponse(&psmithv1.TestUserModelResponse{ErrorMessage: "model not found"}), nil)
	if bad.OK || bad.Message != "Test failed: model not found" {
		t.Errorf("bad: %+v", bad)
	}
}
