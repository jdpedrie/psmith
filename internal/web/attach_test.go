package web

import (
	"bytes"
	"context"
	"log/slog"
	"mime/multipart"
	"net/http/httptest"
	"net/textproto"
	"strings"
	"testing"

	"connectrpc.com/connect"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/auth"
	"github.com/jdpedrie/spalt/internal/conversations"
	"github.com/jdpedrie/spalt/internal/crypto"
	"github.com/jdpedrie/spalt/internal/files"
	"github.com/jdpedrie/spalt/internal/modelmeta"
	_ "github.com/jdpedrie/spalt/internal/providers/anthropic" // register driver
	"github.com/jdpedrie/spalt/internal/storage"
	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/internal/stream"
	"github.com/jdpedrie/spalt/internal/testutil"
)

// TestSend_WithAttachment proves the composer upload path: a posted image is
// stored, attached to the turn, and rendered back in the user's bubble.
func TestSend_WithAttachment(t *testing.T) {
	t.Parallel()

	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())

	st, err := storage.NewFS(t.TempDir())
	if err != nil {
		t.Fatalf("storage: %v", err)
	}
	filesSvc := files.NewService(q, st, []byte("test-signing-key-0123456789abcdef"), "")
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Files: filesSvc, Supervisor: sup, Logger: slog.Default()})

	fx := seedSendable(t, q, "http://127.0.0.1:1") // provider unreachable; the async run failing is irrelevant here
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	// Build a multipart body with a message, the model, and an image file.
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("message", "look at this")
	_ = mw.WriteField("model", fx.providerID.String()+"|"+fx.modelID)
	hdr := textproto.MIMEHeader{}
	hdr.Set("Content-Disposition", `form-data; name="file"; filename="pic.png"`)
	hdr.Set("Content-Type", "image/png")
	part, _ := mw.CreatePart(hdr)
	_, _ = part.Write([]byte("\x89PNG\r\n\x1a\nfake-image-bytes"))
	_ = mw.Close()

	req := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/send", &body).WithContext(userCtx)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("HX-Request", "true")
	req.SetPathValue("id", fx.convID.String())

	rec := do(h.handleSend, req)
	out := rec.Body.String()
	if !strings.Contains(out, `class="attachment"`) {
		t.Fatalf("response missing rendered attachment; body:\n%s", out)
	}
	if !strings.Contains(out, "/files/") {
		t.Errorf("response missing signed file URL; body:\n%s", out)
	}

	// The stored user message should carry one image attachment.
	getResp, err := h.convos.GetConversation(userCtx, connect.NewRequest(&spaltv1.GetConversationRequest{Id: fx.convID.String()}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	msgs, err := h.convos.ListMessages(userCtx, connect.NewRequest(&spaltv1.ListMessagesRequest{ContextId: getResp.Msg.GetActiveContext().GetId()}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	var userImageAttachments int
	for _, m := range msgs.Msg.GetMessages() {
		for _, a := range m.GetAttachments() {
			if a.GetKind() == "image" {
				userImageAttachments++
			}
		}
	}
	if userImageAttachments != 1 {
		t.Errorf("image attachments on stored messages = %d, want 1", userImageAttachments)
	}
}
