package conversations

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/providers"
	"github.com/jdpedrie/spalt/internal/store"
)

// TestSendMessage_AttachmentBinding verifies that attachment_file_ids
// on the SendMessage request resolve into message_attachments rows
// on the just-inserted user message, in order, with the kind derived
// from the file's MIME type.
func TestSendMessage_AttachmentBinding(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "send-attach",
		[]providers.Chunk{textChunk("got it"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	ctx := ctxAsUser(f.user)
	imgID := uuid.New()
	docID := uuid.New()
	if _, err := q.CreateFile(ctx, store.CreateFileParams{
		ID: imgID, UserID: f.user.ID, Sha256: "sha-image",
		MimeType: "image/png", SizeBytes: 64,
	}); err != nil {
		t.Fatalf("CreateFile(image): %v", err)
	}
	if _, err := q.CreateFile(ctx, store.CreateFileParams{
		ID: docID, UserID: f.user.ID, Sha256: "sha-doc",
		MimeType: "application/pdf", SizeBytes: 128,
	}); err != nil {
		t.Fatalf("CreateFile(doc): %v", err)
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctx, connect.NewRequest(&spaltv1.SendMessageRequest{
		ConversationId:    f.conv.ID.String(),
		Content:           "look at these",
		ProviderId:        &pid,
		ModelId:           &mid,
		AttachmentFileIds: []string{imgID.String(), docID.String()},
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}

	userMsgID, _ := uuid.Parse(resp.Msg.UserMessage.Id)
	rows, err := q.ListAttachmentsForMessage(context.Background(), userMsgID)
	if err != nil {
		t.Fatalf("ListAttachmentsForMessage: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 attachments, got %d", len(rows))
	}
	if rows[0].FileID != imgID {
		t.Errorf("ordinal 0 file_id: got %v want %v", rows[0].FileID, imgID)
	}
	if rows[0].Kind != "image" {
		t.Errorf("ordinal 0 kind: got %q want %q", rows[0].Kind, "image")
	}
	if rows[1].FileID != docID {
		t.Errorf("ordinal 1 file_id: got %v want %v", rows[1].FileID, docID)
	}
	if rows[1].Kind != "document" {
		t.Errorf("ordinal 1 kind: got %q want %q", rows[1].Kind, "document")
	}
	if rows[0].RoleHint != "user_supplied" || rows[1].RoleHint != "user_supplied" {
		t.Errorf("role_hint should default to user_supplied")
	}

	// Drain the stream so the test cleans up promptly.
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	_ = waitForTerminal(t, sup, runID)
}

// TestSendMessage_AttachmentNotOwned rejects attachment_file_ids that
// belong to a different user — a permissions-leak primitive we need
// to fail closed on.
func TestSendMessage_AttachmentNotOwned(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "send-attach-deny",
		[]providers.Chunk{doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	// File owned by some OTHER user.
	otherUser := uuid.New()
	if _, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: otherUser, Username: "other", PasswordHash: "x",
	}); err != nil {
		t.Fatalf("CreateUser(other): %v", err)
	}
	fid := uuid.New()
	if _, err := q.CreateFile(context.Background(), store.CreateFileParams{
		ID: fid, UserID: otherUser, Sha256: "sha-leak",
		MimeType: "image/png", SizeBytes: 1,
	}); err != nil {
		t.Fatalf("CreateFile: %v", err)
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&spaltv1.SendMessageRequest{
		ConversationId:    f.conv.ID.String(),
		Content:           "evil",
		ProviderId:        &pid,
		ModelId:           &mid,
		AttachmentFileIds: []string{fid.String()},
	}))
	if err == nil {
		t.Fatal("expected SendMessage to reject a cross-user attachment, got nil")
	}
	if got := connect.CodeOf(err); got != connect.CodeInvalidArgument {
		t.Errorf("expected InvalidArgument, got %v: %v", got, err)
	}
}
