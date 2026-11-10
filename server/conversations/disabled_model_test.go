package conversations

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

// A hand-added model that is turned off keeps its user_models row. Sends
// and compaction must treat it as not enabled anyway.
func TestSendMessage_DisabledManualModelRefused(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "send-disabled-manual", []providers.Chunk{doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	if _, err := q.SetUserModelEnabled(context.Background(), store.SetUserModelEnabledParams{
		UserModelProviderID: f.provider.ID, ModelID: f.modelID, Enabled: false,
	}); err != nil {
		t.Fatalf("SetUserModelEnabled: %v", err)
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hello",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if got := connect.CodeOf(err); got != connect.CodeInvalidArgument {
		t.Fatalf("SendMessage to a disabled model: got %v (%v), want InvalidArgument", got, err)
	}
}

func TestCompact_DisabledManualModelRefused(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-disabled-manual", []providers.Chunk{doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "story please")
	if _, err := q.SetUserModelEnabled(context.Background(), store.SetUserModelEnabledParams{
		UserModelProviderID: f.provider.ID, ModelID: f.modelID, Enabled: false,
	}); err != nil {
		t.Fatalf("SetUserModelEnabled: %v", err)
	}

	guide := "Summarize."
	pid := f.provider.ID.String()
	mid := f.modelID
	_, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId:        f.conv.ID.String(),
		CompressionGuide:      &guide,
		CompressionProviderId: &pid,
		CompressionModelId:    &mid,
	}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}
