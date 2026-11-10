package web

import (
	"net/url"
	"regexp"
	"strings"
	"testing"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// Going back from setup's key step to the provider step and forward again
// keeps working on the provider already made instead of making a second.
func TestSetup_BackAndForwardKeepsOneProvider(t *testing.T) {
	e := newListEnv(t)
	count := func() int {
		resp, err := e.models.ListUserModelProviders(e.ctx, connect.NewRequest(&psmithv1.ListUserModelProvidersRequest{}))
		if err != nil {
			t.Fatal(err)
		}
		return len(resp.Msg.GetProviders())
	}
	start := count()

	rec := e.post(e.h.handleSetupKey, "/setup/key", url.Values{"t": {"anthropic"}, "label": {"Mine"}, "api_key": {"sk-x"}, "action": {"test"}}, nil, false)
	key := rec.Body.String()
	if count() != start+1 {
		t.Fatalf("providers after the first save = %d, want %d", count(), start+1)
	}
	pid := regexp.MustCompile(`name="p" value="([^"]+)"`).FindStringSubmatch(key)[1]

	// Back, as the page links it.
	back := regexp.MustCompile(`<a class="btn ghost h36 lpad" href="([^"]+)">Back</a>`).FindStringSubmatch(key)
	if back == nil {
		t.Fatal("no Back link")
	}
	backURL := strings.ReplaceAll(back[1], "&amp;", "&")
	step1 := e.get(e.h.handleSetup, backURL, nil).Body.String()
	mustContain(t, step1, `name="p" value="`+pid+`"`)

	// Forward with the same provider picked: the key step edits it.
	step2 := e.get(e.h.handleSetupKeyForm, "/setup/key?t=anthropic&p="+pid, nil).Body.String()
	mustContain(t, step2, `name="p" value="`+pid+`"`, `value="Mine"`)
	e.post(e.h.handleSetupKey, "/setup/key", url.Values{"t": {"anthropic"}, "p": {pid}, "label": {"Mine"}, "action": {"continue"}}, nil, false)
	if count() != start+1 {
		t.Errorf("providers after back and forward = %d, want %d", count(), start+1)
	}

	// Forward with a different provider picked: that's a new provider, not
	// an edit of the Anthropic one into something else.
	other := e.get(e.h.handleSetupKeyForm, "/setup/key?t=custom&p="+pid, nil).Body.String()
	if strings.Contains(other, `name="p" value="`+pid+`"`) {
		t.Error("picking another provider still edits the first one")
	}
}
