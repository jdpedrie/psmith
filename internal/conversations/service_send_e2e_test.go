package conversations

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/spalt/fakellm"
	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	_ "github.com/jdpedrie/spalt/internal/providers/anthropic" // registers the real driver
	"github.com/jdpedrie/spalt/internal/store"
)

// TestSendMessage_E2E_AnthropicViaFakeLLM exercises the full happy path
// through the real anthropic driver (HTTP, SSE parsing, usage, materialization)
// against a fakellm.Server. The fake-driver-based TestSendMessage_Success_*
// covers the same service-layer mechanics; this one additionally proves the
// wire-format codepath is intact.
func TestSendMessage_E2E_AnthropicViaFakeLLM(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{
			{Type: fakellm.EventText, Text: "Hello, "},
			{Type: fakellm.EventText, Text: "world!"},
		},
		Usage: &fakellm.Usage{InputTokens: 12, OutputTokens: 4},
	})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&spaltv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}

	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status=%q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}
	if final.ResultMessageID == nil {
		t.Fatal("no result_message_id")
	}

	asst, err := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID: %v", err)
	}
	if asst.Content != "Hello, world!" {
		t.Errorf("content=%q want %q", asst.Content, "Hello, world!")
	}
	// Usage should have flowed driver → supervisor → DB columns.
	if asst.InputTokens == nil || *asst.InputTokens != 12 {
		t.Errorf("input_tokens=%+v want 12", asst.InputTokens)
	}
	if asst.OutputTokens == nil || *asst.OutputTokens != 4 {
		t.Errorf("output_tokens=%+v want 4", asst.OutputTokens)
	}

	// And the request body sent over the wire should reflect what we asked.
	reqs := fake.Requests()
	if len(reqs) != 1 {
		t.Fatalf("requests=%d want 1", len(reqs))
	}
	var body map[string]any
	if err := json.Unmarshal(reqs[0].Body, &body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body["model"] != f.modelID {
		t.Errorf("body.model=%v want %q", body["model"], f.modelID)
	}

	// Regression: every chunk emitted by the driver — including the terminal
	// ChunkDone — must persist. The schema's NOT NULL constraint on payload
	// previously dropped Done chunks silently when the anthropic driver
	// emitted them with nil payload.
	chunks, err := q.ListStreamChunks(context.Background(), store.ListStreamChunksParams{
		StreamRunID: runID,
		Sequence:    0,
	})
	if err != nil {
		t.Fatalf("ListStreamChunks: %v", err)
	}
	var sawDoneChunk bool
	for _, c := range chunks {
		if c.Payload == nil {
			t.Errorf("chunk seq=%d type=%s persisted with nil payload", c.Sequence, c.ChunkType)
		}
		if c.ChunkType == "done" {
			sawDoneChunk = true
		}
	}
	if !sawDoneChunk {
		t.Error("done chunk missing from stream_chunks (driver emitted nil payload?)")
	}
}

// seedAnthropicSendable is a sibling of seedSendable that wires the real
// anthropic driver pointed at the given fake-server URL.
func seedAnthropicSendable(t *testing.T, q *store.Queries, baseURL string) sendFixture {
	t.Helper()
	ctx := context.Background()

	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(ctx, store.CreateUserParams{
		ID: uid, Username: t.Name(), PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	pid, _ := uuid.NewV7()
	sys := "You are concise."
	profile, err := q.CreateProfile(ctx, store.CreateProfileParams{
		ID: pid, UserID: user.ID, Name: "test", SystemMessage: &sys,
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	cvid, _ := uuid.NewV7()
	conv, err := q.CreateConversation(ctx, store.CreateConversationParams{
		ID: cvid, UserID: user.ID, ProfileID: profile.ID,
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}

	cxid, _ := uuid.NewV7()
	ctxRow, err := q.CreateContext(ctx, store.CreateContextParams{
		ID:                    cxid,
		ConversationID:        conv.ID,
		ContextActivationTime: time.Now().UTC(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}

	smid, _ := uuid.NewV7()
	sysMsg, err := q.CreateMessage(ctx, store.CreateMessageParams{
		ID: smid, ContextID: ctxRow.ID, Role: "system", Content: sys,
	})
	if err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}

	prid, _ := uuid.NewV7()
	cfg := []byte(fmt.Sprintf(`{"api_key":"x","base_url":%q}`, baseURL))
	prov, err := q.CreateUserModelProvider(ctx, store.CreateUserModelProviderParams{
		ID: prid, UserID: user.ID, Type: "anthropic", Label: "test", ConfigEncrypted: cfg,
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}

	modelID := "claude-fake"
	// Per-million pricing so cost columns get populated end-to-end too.
	inPrice, outPrice := 3.0, 15.0
	if _, err := q.UpsertUserModel(ctx, store.UpsertUserModelParams{
		UserModelProviderID:   prov.ID,
		ModelID:               modelID,
		DisplayName:           "Claude Fake",
		InputPricePerMillion:  &inPrice,
		OutputPricePerMillion: &outPrice,
		MetadataSource:        "manual",
		MetadataSnapshotAt:    time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}

	return sendFixture{
		user: user, profile: profile, conv: conv,
		contextID: ctxRow.ID, systemMsgID: sysMsg.ID,
		provider: prov, modelID: modelID,
	}
}
