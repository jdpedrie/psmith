package web

import (
	"bytes"
	"context"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"net/url"
	"regexp"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/conversations"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/files"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/storage"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
	"github.com/jdpedrie/psmith/server/testutil"
)

// convFixture is a handler with files wired, a sendable conversation, and the
// caller's context.
type convFixture struct {
	pool   *pgxpool.Pool
	h      *Handler
	q      *store.Queries
	fx     sendFixture
	ctx    context.Context
	ctxID  uuid.UUID
	convID string
}

func newConvFixture(t *testing.T) convFixture {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, modelmeta.NewLiveCatalog(nil), sup, crypto.Nop{}, nil, slog.Default())
	st, err := storage.NewFS(t.TempDir())
	if err != nil {
		t.Fatalf("storage: %v", err)
	}
	filesSvc := files.NewService(q, st, []byte("test-signing-key-0123456789abcdef"), "")
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Files: filesSvc, Supervisor: sup, Logger: slog.Default()})
	fx := seedSendable(t, q, "http://127.0.0.1:1")
	ctx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})
	pid, mid := fx.providerID.String(), fx.modelID
	if _, err := convos.UpdateConversation(ctx, connect.NewRequest(&psmithv1.UpdateConversationRequest{
		Id: fx.convID.String(), Settings: &psmithv1.ConversationSettings{DefaultProviderId: &pid, DefaultModelId: &mid},
	})); err != nil {
		t.Fatalf("UpdateConversation: %v", err)
	}
	return convFixture{pool: pool, h: h, q: q, fx: fx, ctx: ctx, ctxID: activeContextID(t, convos, ctx, fx.convID.String()), convID: fx.convID.String()}
}

// msg stores a message under parent ("" for the root) and returns its id.
func (f convFixture) msg(t *testing.T, parent, role, content string) string {
	t.Helper()
	id, _ := uuid.NewV7()
	p := store.CreateMessageParams{ID: id, ContextID: f.ctxID, Role: role, Content: content}
	if parent != "" {
		pid := uuid.MustParse(parent)
		p.ParentID = &pid
	}
	if _, err := f.q.CreateMessage(context.Background(), p); err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}
	return id.String()
}

func (f convFixture) req(method, path string, form url.Values) *http.Request {
	var body *strings.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	} else {
		body = strings.NewReader("")
	}
	r := httptest.NewRequest(method, path, body).WithContext(f.ctx)
	if form != nil {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	r.SetPathValue("id", f.convID)
	return r
}

func (f convFixture) leaf(t *testing.T) string {
	t.Helper()
	resp, err := f.h.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.convID}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	return resp.Msg.GetActiveContext().GetCurrentLeafMessageId()
}

func TestConvPageStates(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	u := f.msg(t, "", "user", "Is the lazy stack the problem?")
	a := f.msg(t, u, "assistant", "It is.")

	cases := []struct{ query, want string }{
		{"", `aria-label="Reply"`},
		{"m=" + u + "&s=delete", "Delete this message?"},
		{"m=" + a + "&s=edit", `aria-label="Edit reply"`},
		{"m=" + a + "&s=menu", `aria-label="Reply actions"`},
		{"m=" + a + "&s=regen", `aria-label="Regenerate with"`},
		{"rename=1", `aria-label="Rename conversation"`},
		{"draft=hello+there", ">hello there</textarea>"},
	}
	for _, c := range cases {
		r := f.req("GET", "/c/"+f.convID+"?"+c.query, nil)
		rec := do(f.h.handleConversation, r)
		if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), c.want) {
			t.Errorf("?%s: status %d, missing %q", c.query, rec.Code, c.want)
		}
	}
	// A menu is never drawn on a user turn.
	rec := do(f.h.handleConversation, f.req("GET", "/c/"+f.convID+"?m="+u+"&s=menu", nil))
	if strings.Contains(rec.Body.String(), `aria-label="Reply actions"`) {
		t.Error("user turn drew the reply menu")
	}
}

func TestConvMessageRow(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	u := f.msg(t, "", "user", "hello")
	a := f.msg(t, u, "assistant", "hi")

	get := func(mid, state string) *httptest.ResponseRecorder {
		r := f.req("GET", "/c/"+f.convID+"/message/"+mid+"?s="+state, nil)
		r.SetPathValue("mid", mid)
		return do(f.h.handleMessageRow, r)
	}
	if rec := get(a, "edit"); !strings.Contains(rec.Body.String(), `id="m-`+a+`"`) || !strings.Contains(rec.Body.String(), `name="content"`) {
		t.Errorf("edit row: %s", rec.Body.String())
	}
	if rec := get(u, ""); !strings.Contains(rec.Body.String(), `class="bubble"`) {
		t.Errorf("plain user row: %s", rec.Body.String())
	}
	if rec := get(uuid.NewString(), ""); rec.Code != http.StatusNotFound {
		t.Errorf("unknown message status = %d", rec.Code)
	}

	// The old edit URL lands on the page with the row open, or as a row for htmx.
	r := f.req("GET", "/c/"+f.convID+"/message/"+a+"/edit", nil)
	r.SetPathValue("mid", a)
	rec := do(f.h.handleRowStatePage("edit"), r)
	if loc := rec.Header().Get("Location"); rec.Code != http.StatusSeeOther || !strings.Contains(loc, "m="+a+"&s=edit") {
		t.Errorf("edit page redirect = %d %q", rec.Code, loc)
	}
	r.Header.Set("HX-Request", "true")
	if rec := do(f.h.handleRowStatePage("delete"), r); !strings.Contains(rec.Body.String(), "Delete this message?") {
		t.Errorf("htmx delete row: %s", rec.Body.String())
	}
}

func TestConvEditRoleAndResend(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	u := f.msg(t, "", "user", "original")
	a := f.msg(t, u, "assistant", "reply")

	// Changing an assistant turn to a user turn.
	r := f.req("POST", "/c/"+f.convID+"/message/"+a+"/edit", url.Values{"content": {"now mine"}, "role": {"user"}})
	r.SetPathValue("mid", a)
	if rec := do(f.h.handleEditSave, r); rec.Code != http.StatusSeeOther {
		t.Fatalf("edit status %d: %s", rec.Code, rec.Body.String())
	}
	got, _ := f.h.convos.GetMessage(f.ctx, connect.NewRequest(&psmithv1.GetMessageRequest{Id: a}))
	if got.Msg.GetMessage().GetRole() != psmithv1.MessageRole_MESSAGE_ROLE_USER || got.Msg.GetMessage().GetContent() != "now mine" {
		t.Errorf("edited = %v %q", got.Msg.GetMessage().GetRole(), got.Msg.GetMessage().GetContent())
	}

	// Save and resend on a user turn starts a run.
	r = f.req("POST", "/c/"+f.convID+"/message/"+u+"/edit", url.Values{"content": {"edited"}, "role": {"user"}, "resend": {"1"}})
	r.SetPathValue("mid", u)
	rec := do(f.h.handleEditSave, r)
	if loc := rec.Header().Get("Location"); !strings.HasPrefix(loc, "/c/"+f.convID+"?run=") {
		t.Errorf("resend redirect = %d %q", rec.Code, loc)
	}
}

func TestConvRegenerateWithModel(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	u := f.msg(t, "", "user", "hi")
	rec := do(f.h.handleRegenerate, f.req("POST", "/c/"+f.convID+"/regenerate", url.Values{
		"parent_message_id": {u}, "model": {modelValue(f.fx.providerID.String(), f.fx.modelID)},
	}))
	if loc := rec.Header().Get("Location"); !strings.HasPrefix(loc, "/c/"+f.convID+"?run=") {
		t.Errorf("regenerate = %d %q %s", rec.Code, loc, rec.Body.String())
	}
	if rec := do(f.h.handleRegenerate, f.req("POST", "/c/"+f.convID+"/regenerate", url.Values{})); rec.Code != http.StatusBadRequest {
		t.Errorf("missing parent status = %d", rec.Code)
	}
}

func TestConvBranchWalksToNewestLeaf(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	u := f.msg(t, "", "user", "q")
	a1 := f.msg(t, u, "assistant", "first")
	u2 := f.msg(t, a1, "user", "follow-up")
	a2 := f.msg(t, u2, "assistant", "answer")
	b1 := f.msg(t, u, "assistant", "second")

	rec := do(f.h.handleBranch, f.req("POST", "/c/"+f.convID+"/branch", url.Values{"message_id": {a1}}))
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("branch status %d: %s", rec.Code, rec.Body.String())
	}
	if got := f.leaf(t); got != a2 {
		t.Errorf("leaf after switching to the first reply = %s, want its newest descendant %s", got, a2)
	}
	do(f.h.handleBranch, f.req("POST", "/c/"+f.convID+"/branch", url.Values{"message_id": {b1}}))
	if got := f.leaf(t); got != b1 {
		t.Errorf("leaf = %s, want %s", got, b1)
	}

	// The transcript now offers 2 of 2 on the reply.
	page := do(f.h.handleConversation, f.req("GET", "/c/"+f.convID, nil)).Body.String()
	if !strings.Contains(page, "2 of 2") || !strings.Contains(page, `aria-label="Previous reply"`) {
		t.Errorf("branch nav missing from transcript")
	}
	if rec := do(f.h.handleBranch, f.req("POST", "/c/"+f.convID+"/branch", url.Values{"message_id": {uuid.NewString()}})); rec.Code != http.StatusBadRequest {
		t.Errorf("foreign message status = %d", rec.Code)
	}
}

func TestConvRenameAndHead(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	rec := do(f.h.handleRename, f.req("POST", "/c/"+f.convID+"/rename", url.Values{"title": {"  Scroll jump  "}}))
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("rename status %d", rec.Code)
	}
	got, _ := f.h.convos.GetConversation(f.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: f.convID}))
	if got.Msg.GetConversation().GetTitle() != "Scroll jump" {
		t.Errorf("title = %q", got.Msg.GetConversation().GetTitle())
	}
	r := f.req("POST", "/c/"+f.convID+"/rename", url.Values{"title": {"Again"}})
	r.Header.Set("HX-Request", "true")
	if body := do(f.h.handleRename, r).Body.String(); !strings.Contains(body, `id="conv-head"`) || !strings.Contains(body, "Again") {
		t.Errorf("htmx rename answered %s", body)
	}
	if body := do(f.h.handleHead, f.req("GET", "/c/"+f.convID+"/head?rename=1", nil)).Body.String(); !strings.Contains(body, `id="conv-title"`) {
		t.Errorf("rename head: %s", body)
	}
}

func TestConvStopWithoutRun(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	if rec := do(f.h.handleStop, f.req("POST", "/c/"+f.convID+"/stop", nil)); rec.Code != http.StatusNoContent {
		t.Errorf("fetch stop status = %d", rec.Code)
	}
	r := f.req("POST", "/c/"+f.convID+"/stop", nil)
	r.Header.Set("Sec-Fetch-Mode", "navigate")
	if rec := do(f.h.handleStop, r); rec.Code != http.StatusSeeOther {
		t.Errorf("form stop status = %d", rec.Code)
	}
}

func TestConvChoice(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	rec := do(f.h.handleChoice, f.req("POST", "/c/"+f.convID+"/choice", url.Values{"choice": {"compose:Page by day"}}))
	if loc := rec.Header().Get("Location"); loc != "/c/"+f.convID+"?draft=Page+by+day" {
		t.Errorf("compose redirect = %q", loc)
	}
	rec = do(f.h.handleChoice, f.req("POST", "/c/"+f.convID+"/choice", url.Values{"choice": {"send:B"}}))
	if loc := rec.Header().Get("Location"); !strings.HasPrefix(loc, "/c/"+f.convID+"?run=") {
		t.Errorf("send redirect = %d %q %s", rec.Code, loc, rec.Body.String())
	}
	for _, bad := range []string{"external:https://x", "send:", ""} {
		if rec := do(f.h.handleChoice, f.req("POST", "/c/"+f.convID+"/choice", url.Values{"choice": {bad}})); rec.Code != http.StatusBadRequest {
			t.Errorf("choice %q status = %d", bad, rec.Code)
		}
	}
}

func TestConvContinueNeedsParent(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)
	if rec := do(f.h.handleContinue, f.req("POST", "/c/"+f.convID+"/continue", url.Values{})); rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d", rec.Code)
	}
}

func uploadBody(t *testing.T, name, mime string, data []byte) (*bytes.Buffer, string) {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	hdr := textproto.MIMEHeader{}
	hdr.Set("Content-Disposition", `form-data; name="file"; filename="`+name+`"`)
	hdr.Set("Content-Type", mime)
	part, _ := mw.CreatePart(hdr)
	_, _ = part.Write(data)
	_ = mw.Close()
	return &body, mw.FormDataContentType()
}

var attachmentID = regexp.MustCompile(`name="attachment" value="([^"]+)"`)

func TestConvUploadThenSendAndView(t *testing.T) {
	t.Parallel()
	f := newConvFixture(t)

	upload := func(name, mime string, data []byte) string {
		body, ct := uploadBody(t, name, mime, data)
		r := httptest.NewRequest("POST", "/c/"+f.convID+"/upload", body).WithContext(f.ctx)
		r.Header.Set("Content-Type", ct)
		r.SetPathValue("id", f.convID)
		rec := do(f.h.handleUpload, r)
		m := attachmentID.FindStringSubmatch(rec.Body.String())
		if rec.Code != http.StatusOK || m == nil {
			t.Fatalf("upload %s: %d %s", name, rec.Code, rec.Body.String())
		}
		return m[1]
	}
	img := upload("shot.png", "image/png", []byte("\x89PNG\r\n\x1a\nfake"))
	pdf := upload("trace.pdf", "application/pdf", []byte("%PDF-1.4 fake"))

	r := f.req("POST", "/c/"+f.convID+"/send", url.Values{"message": {"look"}, "attachment": {img, pdf}})
	r.Header.Set("HX-Request", "true")
	out := do(f.h.handleSend, r).Body.String()
	if !strings.Contains(out, "img-tile") || !strings.Contains(out, "file-chip") || !strings.Contains(out, "PDF") {
		t.Fatalf("send echo missing attachments: %s", out)
	}

	view := func(fid string) *httptest.ResponseRecorder {
		r := f.req("GET", "/c/"+f.convID+"/file/"+fid, nil)
		r.SetPathValue("fid", fid)
		return do(f.h.handleFilePage, r)
	}
	if rec := view(img); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "shot.png") || !strings.Contains(rec.Body.String(), "sent by you today") {
		t.Errorf("image page: %d %s", rec.Code, rec.Body.String())
	}
	if rec := view(pdf); rec.Code != http.StatusSeeOther || !strings.Contains(rec.Header().Get("Location"), "/files/") {
		t.Errorf("file download: %d %q", rec.Code, rec.Header().Get("Location"))
	}
	if rec := view(uuid.NewString()); rec.Code != http.StatusNotFound {
		t.Errorf("unknown file status = %d", rec.Code)
	}

	// No file in the upload is a bad request.
	r = httptest.NewRequest("POST", "/c/"+f.convID+"/upload", strings.NewReader("")).WithContext(f.ctx)
	r.Header.Set("Content-Type", "multipart/form-data; boundary=x")
	r.SetPathValue("id", f.convID)
	if rec := do(f.h.handleUpload, r); rec.Code != http.StatusBadRequest {
		t.Errorf("empty upload status = %d", rec.Code)
	}
}
