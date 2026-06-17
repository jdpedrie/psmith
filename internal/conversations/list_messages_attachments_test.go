package conversations

import (
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/providers"
	"github.com/jdpedrie/spalt/internal/store"
)

// Regression: confirms ListMessages (BOTH chain mode and full-tree)
// returns attachments on user messages, end-to-end. Catches a regression
// where attachments get dropped during the proto round-trip on the
// history reload path that iOS uses to render chat history.
func TestService_ListMessages_PopulatesAttachments(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "list-attach",
		[]providers.Chunk{textChunk("ok"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	ctx := ctxAsUser(f.user)
	imgID := uuid.New()
	if _, err := q.CreateFile(ctx, store.CreateFileParams{
		ID: imgID, UserID: f.user.ID, Sha256: "sha-img-list",
		MimeType: "image/png", SizeBytes: 64,
	}); err != nil {
		t.Fatalf("CreateFile: %v", err)
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctx, connect.NewRequest(&spaltv1.SendMessageRequest{
		ConversationId:    f.conv.ID.String(),
		Content:           "look",
		ProviderId:        &pid,
		ModelId:           &mid,
		AttachmentFileIds: []string{imgID.String()},
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	_ = waitForTerminal(t, sup, runID)

	// 1. SendMessage response itself MUST carry attachments on the
	// optimistic user-message echo.
	if got := len(resp.Msg.UserMessage.Attachments); got != 1 {
		t.Fatalf("SendMessage response missing attachments: got %d", got)
	}
	if resp.Msg.UserMessage.Attachments[0].Kind != "image" {
		t.Errorf("SendMessage attachment kind: got %q want %q",
			resp.Msg.UserMessage.Attachments[0].Kind, "image")
	}

	// 2. ListMessages chain mode (the path iOS uses for history) MUST
	// also carry attachments.
	listResp, err := svc.ListMessages(ctx, connect.NewRequest(&spaltv1.ListMessagesRequest{
		ContextId: f.contextID.String(),
	}))
	if err != nil {
		t.Fatalf("ListMessages chain: %v", err)
	}
	var userMsg *spaltv1.Message
	for _, m := range listResp.Msg.Messages {
		if m.Role == spaltv1.MessageRole_MESSAGE_ROLE_USER && m.Content == "look" {
			userMsg = m
			break
		}
	}
	if userMsg == nil {
		t.Fatalf("ListMessages chain: user message 'look' not found in %d messages",
			len(listResp.Msg.Messages))
	}
	if len(userMsg.Attachments) != 1 {
		t.Errorf("ListMessages chain user message: got %d attachments, want 1",
			len(userMsg.Attachments))
	}
	if len(userMsg.Attachments) > 0 && userMsg.Attachments[0].Kind != "image" {
		t.Errorf("ListMessages chain attachment kind: got %q want %q",
			userMsg.Attachments[0].Kind, "image")
	}

	// 3. ListMessages full_tree mode (used by the branch switcher).
	listResp, err = svc.ListMessages(ctx, connect.NewRequest(&spaltv1.ListMessagesRequest{
		ContextId: f.contextID.String(),
		FullTree:  true,
	}))
	if err != nil {
		t.Fatalf("ListMessages full_tree: %v", err)
	}
	userMsg = nil
	for _, m := range listResp.Msg.Messages {
		if m.Role == spaltv1.MessageRole_MESSAGE_ROLE_USER && m.Content == "look" {
			userMsg = m
			break
		}
	}
	if userMsg == nil {
		t.Fatalf("ListMessages full_tree: user message 'look' not found in %d messages",
			len(listResp.Msg.Messages))
	}
	if len(userMsg.Attachments) != 1 {
		t.Errorf("ListMessages full_tree user message: got %d attachments, want 1",
			len(userMsg.Attachments))
	}
}
