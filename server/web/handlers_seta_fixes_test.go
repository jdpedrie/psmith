package web

import (
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// The provider page's quick defaults go through the same limits as the full
// defaults page: a temperature of 7 or zero output tokens is refused, not
// stored for every send to fail on.
func TestSetaProviderSaveRejectsOutOfRange(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	for _, form := range []url.Values{
		{"temperature": {"7"}},
		{"temperature": {"-1"}},
		{"max_output_tokens": {"0"}},
		{"max_output_tokens": {"-5"}},
	} {
		rec := e.do("POST", "/settings/providers/"+id, form)
		if rec.Code != http.StatusUnprocessableEntity {
			t.Errorf("%v: status %d, want 422", form, rec.Code)
		}
	}
	got, _ := e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	if ds := got.Msg.GetProvider().GetDefaultSettings(); ds.GetTemperature() != 0 || ds.GetMaxOutputTokens() != 0 {
		t.Errorf("an out-of-range value was stored: %v", ds)
	}
}

// The model page refuses negative limits and prices and zero output tokens.
func TestSetaModelSaveRejectsOutOfRange(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	if _, err := e.models.AddManualModel(e.ctx, connect.NewRequest(&psmithv1.AddManualModelRequest{UserModelProviderId: id, ModelId: "m1", DisplayName: "M1"})); err != nil {
		t.Fatal(err)
	}
	base := url.Values{"display_name": {"M1"}, "cap": {"streaming"}, "modality": {"text"}}
	for k, v := range map[string]string{"context_window": "-1", "max_output": "0", "price_in": "-2", "max_output_tokens": "0"} {
		form := url.Values{}
		for bk, bv := range base {
			form[bk] = bv
		}
		form.Set(k, v)
		if rec := e.do("POST", "/settings/providers/"+id+"/models/m1", form); rec.Code != http.StatusUnprocessableEntity {
			t.Errorf("%s=%s: status %d, want 422", k, v, rec.Code)
		}
	}
}

// Setting a user's password lands on the Users page by redirect, so a reload
// doesn't post the password again.
func TestSetaUserPasswordRedirects(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, true)
	resp, err := e.h.auth.CreateUser(e.ctx, connect.NewRequest(&psmithv1.CreateUserRequest{Username: "maya", Password: "pw"}))
	if err != nil {
		t.Fatal(err)
	}
	loc := e.mustRedirect(e.do("POST", "/settings/users/"+resp.Msg.GetUser().GetId()+"/password", url.Values{"password": {"new-one"}}), "/settings/users")
	e.mustOK(e.do("GET", loc, nil), "Password set. Tell them the new one yourself; nothing is emailed.")
}

// New user opens the form with the cursor in Username. A URL fragment stops
// Chrome from honoring autofocus, so the link carries none.
func TestSetaNewUserLinkHasNoFragment(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, true)
	body := e.mustOK(e.do("GET", "/settings/users", nil), `href="/settings/users?new=1"`)
	if strings.Contains(body, "#newuser") {
		t.Error("New user still links to a fragment")
	}
}

// The price fields are labelled for a screen reader as the board names them.
func TestSetaPriceFieldLabels(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	if _, err := e.models.AddManualModel(e.ctx, connect.NewRequest(&psmithv1.AddManualModelRequest{UserModelProviderId: id, ModelId: "m1", DisplayName: "M1"})); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/settings/providers/" + id + "/models/m1", "/settings/providers/" + id + "/add-model"} {
		body := e.mustOK(e.do("GET", path, nil), `aria-label="Input price"`, `aria-label="Output price"`, `aria-label="Cache read price"`, `aria-label="Cache write price"`)
		if strings.Contains(body, "saPrice") {
			t.Errorf("%s: a code identifier leaked into a label", path)
		}
	}
}

// A hand-added model turned off keeps its row, so adding it by hand again
// used to fail with "already exists" and leave no way back on the web. Adding
// it again turns it back on with what was typed.
func TestSetaReaddOffManualModel(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	id := e.provider("anthropic", "Mine", `{"api_key":"k"}`)
	cw := int32(1000)
	if _, err := e.models.AddManualModel(e.ctx, connect.NewRequest(&psmithv1.AddManualModelRequest{UserModelProviderId: id, ModelId: "ft-1", DisplayName: "Old name", ContextWindow: &cw})); err != nil {
		t.Fatal(err)
	}
	e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/model-op/disable/ft-1", nil), "/settings/providers/"+id)

	loc := e.mustRedirect(e.do("POST", "/settings/providers/"+id+"/add-model", url.Values{
		"model_id": {"ft-1"}, "display_name": {"New name"}, "context_window": {"2,000"}, "cap": {"streaming", "tool_use"}, "modality": {"text"},
	}), "/settings/providers/"+id+"/models/ft-1")
	e.mustOK(e.do("GET", loc, nil), `value="New name"`, `value="2,000"`)

	got, _ := e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	if len(got.Msg.GetEnabledModels()) != 1 || len(got.Msg.GetDisabledModels()) != 0 {
		t.Fatalf("enabled %d, disabled %d; want 1, 0", len(got.Msg.GetEnabledModels()), len(got.Msg.GetDisabledModels()))
	}
	m := got.Msg.GetEnabledModels()[0]
	if m.GetDisplayName() != "New name" || m.GetContextWindow() != 2000 || !m.GetCapabilities().GetToolUse() {
		t.Errorf("re-added model kept the old metadata: %v", m)
	}

	// An id that is on already still says so.
	if rec := e.do("POST", "/settings/providers/"+id+"/add-model", url.Values{"model_id": {"ft-1"}, "display_name": {"Again"}}); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("adding an id that is on: status %d, want 422", rec.Code)
	}
}

// A custom range picked backwards (To before From) reads as the same days in
// order, not as an empty window labelled "November 9 to 1".
func TestSetaUsageWindowBackwards(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	since, until, label := usageWindow(now, "custom", "2026-11-09", "2026-11-01")
	if since == nil || until == nil || !since.Before(*until) {
		t.Fatalf("window %v to %v is empty", since, until)
	}
	if want := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC); !since.Equal(want) {
		t.Errorf("since %v, want %v", since, want)
	}
	if want := time.Date(2026, 11, 10, 0, 0, 0, 0, time.UTC); !until.Equal(want) {
		t.Errorf("until %v, want %v", until, want)
	}
	if label != "November 1 to 9, 2026" {
		t.Errorf("label %q", label)
	}
}

// The signed-in row names the login once when there's no display name.
func TestSetaGeneralNamesLoginOnce(t *testing.T) {
	t.Parallel()
	e := newSAEnv(t, false)
	if body := e.mustOK(e.do("GET", "/settings/general", nil)); strings.Contains(body, `class="mono-sm"`) {
		t.Error("the login repeats beside the same name")
	}
}
