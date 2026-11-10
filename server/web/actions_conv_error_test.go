package web

import (
	"context"
	"net/http"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"net/url"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
)

// A transcript action the server refuses lands back on the transcript with
// the reason in its alert line. It used to answer with an error status,
// which htmx drops without a swap, so nothing on the page changed.
func TestConvRefusedActionShowsWhy(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	missing := uuid.NewString()
	rec := do(f.h.handleRegenerate, f.req("POST", "/c/"+f.convID+"/regenerate", url.Values{"parent_message_id": {missing}}))
	loc := rec.Header().Get("Location")
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(loc, "/c/"+f.convID+"?error=") {
		t.Fatalf("refused regenerate = %d %q, want a redirect carrying the error", rec.Code, loc)
	}
	u, _ := url.Parse(loc)
	page := do(f.h.handleConversation, f.req("GET", loc, nil))
	body := page.Body.String()
	if !strings.Contains(body, `class="reply-error" role="alert"`) {
		t.Fatalf("the transcript has no alert line")
	}
	if why := u.Query().Get("error"); why == "" || !strings.Contains(body, htmlEscape(why)) {
		t.Errorf("the alert doesn't carry the reason %q", why)
	}
}

func htmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&#34;", "'", "&#39;").Replace(s)
}

// The composer's model is saved as the conversation's default with the send.
// It was saved after the send started its run, which the conversation
// refuses (settings can't change mid-stream), so it never stuck and a later
// regenerate had no model to use.
func TestConvSendKeepsTheChosenModel(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	// Start from no conversation default, as a fresh conversation has.
	if _, err := f.h.convos.UpdateConversation(f.ctx, connect.NewRequest(&psmithv1.UpdateConversationRequest{
		Id: f.convID, Settings: &psmithv1.ConversationSettings{},
	})); err != nil {
		t.Fatalf("clear settings: %v", err)
	}
	r := f.req("POST", "/c/"+f.convID+"/send", url.Values{
		"message": {"hello"}, "model": {modelValue(f.fx.providerID.String(), f.fx.modelID)},
	})
	r.Header.Set("HX-Request", "true")
	if rec := do(f.h.handleSend, r); rec.Code != http.StatusOK {
		t.Fatalf("send = %d %s", rec.Code, rec.Body.String())
	}
	resp, err := f.h.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.convID}))
	if err != nil {
		t.Fatal(err)
	}
	s := resp.Msg.GetConversation().GetSettings()
	if s.GetDefaultModelId() != f.fx.modelID || s.GetDefaultProviderId() != f.fx.providerID.String() {
		t.Errorf("conversation default = %s/%s, want %s/%s", s.GetDefaultProviderId(), s.GetDefaultModelId(), f.fx.providerID, f.fx.modelID)
	}
}

// ?rename=1 renames the conversation; the inspector's contexts tab puts a
// context id in rename, which must not open the header's rename as well.
func TestConvRenameOnlyForTheHeader(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	head := do(f.h.handleConversation, f.req("GET", "/c/"+f.convID+"?rename=1", nil)).Body.String()
	other := do(f.h.handleConversation, f.req("GET", "/c/"+f.convID+"?tab=contexts&rename="+f.ctxID.String(), nil)).Body.String()
	if !strings.Contains(head, `name="title"`) {
		t.Error("?rename=1 didn't open the header's rename")
	}
	if strings.Contains(other, `class="rename"`) {
		t.Error("renaming a context also opened the conversation's rename")
	}
}

// The reply stream serves only the caller's conversation and that
// conversation's own runs; the supervisor serves any run id it's given.
func TestStreamRefusesOtherRuns(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	var other sendFixture
	t.Run("other account", func(t *testing.T) { other = seedSendable(t, f.q, "http://unused") })
	cx, err := f.q.ListContextsByConversation(context.Background(), other.convID)
	if err != nil || len(cx) == 0 {
		t.Fatal(err)
	}
	id, _ := uuid.NewV7()
	if _, err := f.q.CreateStreamRun(context.Background(), store.CreateStreamRunParams{ID: id, ConversationID: other.convID, ContextID: cx[0].ID, ModelID: "m", Status: "completed", Purpose: "assistant_response"}); err != nil {
		t.Fatal(err)
	}
	mine := do(f.h.handleStream, f.req("GET", "/c/"+f.convID+"/stream?run="+id.String(), nil))
	if mine.Code != http.StatusNotFound {
		t.Errorf("another account's run through my conversation = %d", mine.Code)
	}
	r := f.req("GET", "/c/"+other.convID.String()+"/stream?run="+id.String(), nil)
	r.SetPathValue("id", other.convID.String())
	if theirs := do(f.h.handleStream, r); theirs.Code != http.StatusNotFound {
		t.Errorf("another account's conversation = %d", theirs.Code)
	}
}

// A failed compression summary retries as a compression (the compress
// card), not through regenerate, which would rerun it as a chat turn. A
// pending summary has no Regenerate either; Edit and Delete stay.
func TestConvSummaryRowsDontRegenerate(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	u := f.msg(t, "", "user", "hello")
	a := f.msg(t, u, "assistant", "hi")
	failed := f.msg(t, a, "compression_summary", "partial summary")
	if _, err := f.pool.Exec(context.Background(), `UPDATE messages SET error_payload = '{"message":"overloaded"}' WHERE id = $1`, failed); err != nil {
		t.Fatal(err)
	}
	body := do(f.h.handleConversation, f.req("GET", "/c/"+f.convID, nil)).Body.String()
	row := between(body, `id="m-`+failed+`"`, "</article>")
	if row == "" {
		t.Fatalf("no row for the failed summary")
	}
	if strings.Contains(row, "/regenerate") {
		t.Error("a failed summary's Retry reruns it as a chat turn")
	}
	if !strings.Contains(row, `href="/c/`+f.convID+`/compact"`) {
		t.Error("a failed summary's Retry doesn't open the compress card")
	}

	pending := f.msg(t, a, "compression_summary", "a clean summary")
	body = do(f.h.handleConversation, f.req("GET", "/c/"+f.convID, nil)).Body.String()
	row = between(body, `id="m-`+pending+`"`, "</article>")
	if row == "" {
		t.Fatalf("no row for the pending summary")
	}
	if strings.Contains(row, `aria-label="Regenerate"`) {
		t.Error("a pending summary offers Regenerate")
	}
	if !strings.Contains(row, `aria-label="Edit"`) || !strings.Contains(row, `aria-label="Delete"`) {
		t.Error("a pending summary lost Edit or Delete")
	}
}

func between(s, from, to string) string {
	i := strings.Index(s, from)
	if i < 0 {
		return ""
	}
	j := strings.Index(s[i:], to)
	if j < 0 {
		return s[i:]
	}
	return s[i : i+j]
}

// A rename the server refuses keeps the form open with what was typed and
// the reason; an error status left the form looking as if Save did nothing.
func TestConvRenameRefusedKeepsTheForm(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	if _, err := f.h.convos.ArchiveConversation(f.ctx, connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: f.convID})); err != nil {
		t.Fatal(err)
	}
	r := f.req("POST", "/c/"+f.convID+"/rename", url.Values{"title": {"Tide pools"}})
	r.Header.Set("HX-Request", "true")
	rec := do(f.h.handleRename, r)
	body := rec.Body.String()
	if rec.Code != http.StatusOK || !strings.Contains(body, `class="head-rename-hint err" role="alert"`) {
		t.Fatalf("refused rename = %d, no alert in %q", rec.Code, body)
	}
	if !strings.Contains(body, `value="Tide pools"`) {
		t.Error("the typed title was lost")
	}
}
