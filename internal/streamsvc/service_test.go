package streamsvc

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/gen/spalt/v1/spaltv1connect"
	"github.com/jdpedrie/spalt/internal/auth"
	"github.com/jdpedrie/spalt/internal/providers"
	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/internal/stream"
	"github.com/jdpedrie/spalt/internal/testutil"
)

// --- Fixture ---------------------------------------------------------------

// fixture wraps DB + supervisor + a started httptest server exposing the
// StreamsService. Tests use the returned client to drive RPCs over HTTP and
// inspect the supervisor's resulting state through q.
type fixture struct {
	q      *store.Queries
	sup    *stream.Supervisor
	user   store.User
	prov   store.UserModelProvider
	conv   store.Conversation
	cctx   store.Context
	parent uuid.UUID
	srv    *httptest.Server
	client spaltv1connect.StreamsServiceClient
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	sup := stream.New(q, logger)

	bg := context.Background()

	user := mustCreateUser(t, q, "u-"+mustUUID(t).String()[:8])
	provID := mustUUID(t)
	prov, err := q.CreateUserModelProvider(bg, store.CreateUserModelProviderParams{
		ID: provID, UserID: user.ID, Type: "openai-compatible",
		Label: "test", ConfigEncrypted: []byte(`{}`),
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	profID := mustUUID(t)
	prof, err := q.CreateProfile(bg, store.CreateProfileParams{
		ID: profID, UserID: user.ID, Name: "p",
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	convID := mustUUID(t)
	conv, err := q.CreateConversation(bg, store.CreateConversationParams{
		ID: convID, UserID: user.ID, ProfileID: prof.ID,
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	cctxID := mustUUID(t)
	cctx, err := q.CreateContext(bg, store.CreateContextParams{
		ID: cctxID, ConversationID: conv.ID, ContextActivationTime: time.Now().UTC(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}
	parentID := mustUUID(t)
	if _, err := q.CreateMessage(bg, store.CreateMessageParams{
		ID: parentID, ContextID: cctx.ID, Role: "user", Content: "hi",
	}); err != nil {
		t.Fatalf("CreateMessage(parent): %v", err)
	}

	mux := http.NewServeMux()
	svc := NewService(q, sup)
	mux.Handle(spaltv1connect.NewStreamsServiceHandler(svc))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	client := spaltv1connect.NewStreamsServiceClient(srv.Client(), srv.URL)

	return &fixture{
		q: q, sup: sup, user: user, prov: prov, conv: conv,
		cctx: cctx, parent: parentID, srv: srv, client: client,
	}
}

// startParams builds a StartParams targeting an assistant-response run.
func (f *fixture) startParams(src <-chan providers.Chunk, purpose stream.StreamPurpose) stream.StartParams {
	parent := f.parent
	return stream.StartParams{
		ConversationID:  f.conv.ID,
		ContextID:       f.cctx.ID,
		ParentMessageID: &parent,
		ProviderID:      f.prov.ID,
		ModelID:         "gpt-test",
		Purpose:         purpose,
		Source:          src,
	}
}

func mustUUID(t *testing.T) uuid.UUID {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	return id
}

func mustCreateUser(t *testing.T, q *store.Queries, username string) store.User {
	t.Helper()
	uid := mustUUID(t)
	u, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: uid, Username: username, PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	return u
}

func textChunk(s string) providers.Chunk {
	raw, _ := json.Marshal(map[string]string{"text": s})
	return providers.Chunk{Type: providers.ChunkText, Payload: raw}
}

func doneChunk() providers.Chunk {
	return providers.Chunk{Type: providers.ChunkDone, Payload: []byte(`{}`)}
}

// expectCode asserts err is a *connect.Error with the given code.
func expectCode(t *testing.T, err error, want connect.Code) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error with code %v, got nil", want)
	}
	var ce *connect.Error
	if !errors.As(err, &ce) {
		t.Fatalf("expected *connect.Error, got %T (%v)", err, err)
	}
	if ce.Code() != want {
		t.Errorf("got code %v want %v (%v)", ce.Code(), want, err)
	}
}

// --- SubscribeStream -------------------------------------------------------

func TestSubscribeStream_InvalidUUID(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	stream, err := f.client.SubscribeStream(context.Background(), connect.NewRequest(&spaltv1.SubscribeStreamRequest{
		StreamRunId: "not-a-uuid",
	}))
	if err == nil {
		// Connect server-streaming surfaces errors when you call Receive(),
		// not at the open. Pull one to surface the InvalidArgument.
		_ = stream.Receive()
		err = stream.Err()
		_ = stream.Close()
	}
	expectCode(t, err, connect.CodeInvalidArgument)
}

func TestSubscribeStream_NotFound(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	missing := mustUUID(t).String()
	stream, _ := f.client.SubscribeStream(context.Background(), connect.NewRequest(&spaltv1.SubscribeStreamRequest{
		StreamRunId: missing,
	}))
	_ = stream.Receive()
	err := stream.Err()
	_ = stream.Close()
	expectCode(t, err, connect.CodeNotFound)
}

func TestSubscribeStream_HappyPath(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	// Buffered source so we can push without blocking; close after pushing.
	// Include a usage chunk to confirm CHUNK_TYPE_USAGE flows on the wire
	// (the converter previously dropped ChunkUsage to UNSPECIFIED).
	src := make(chan providers.Chunk, 8)
	src <- textChunk("Hello")
	src <- textChunk(", ")
	src <- textChunk("world!")
	usageRaw, _ := json.Marshal(map[string]any{
		"input_tokens":  10,
		"output_tokens": 5,
	})
	src <- providers.Chunk{Type: providers.ChunkUsage, Payload: usageRaw}
	src <- doneChunk()
	close(src)

	runID, err := f.sup.Start(context.Background(), f.startParams(src, stream.PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	streamCli, err := f.client.SubscribeStream(ctx, connect.NewRequest(&spaltv1.SubscribeStreamRequest{
		StreamRunId: runID.String(),
	}))
	if err != nil {
		t.Fatalf("SubscribeStream open: %v", err)
	}
	defer streamCli.Close()

	var (
		text       string
		sawUsage   bool
		usageInput int32
		terminal   *spaltv1.StreamRun
	)
	for streamCli.Receive() {
		ev := streamCli.Msg().Event
		switch e := ev.(type) {
		case *spaltv1.SubscribeStreamResponse_Chunk:
			switch e.Chunk.Type {
			case spaltv1.ChunkType_CHUNK_TYPE_TEXT_DELTA:
				var p struct{ Text string }
				_ = json.Unmarshal(e.Chunk.Payload, &p)
				text += p.Text
			case spaltv1.ChunkType_CHUNK_TYPE_USAGE:
				sawUsage = true
				var p struct {
					InputTokens int32 `json:"input_tokens"`
				}
				_ = json.Unmarshal(e.Chunk.Payload, &p)
				usageInput = p.InputTokens
			}
		case *spaltv1.SubscribeStreamResponse_Terminal:
			terminal = e.Terminal
		}
	}
	if err := streamCli.Err(); err != nil {
		t.Fatalf("Receive err: %v", err)
	}
	if text != "Hello, world!" {
		t.Errorf("text=%q want %q", text, "Hello, world!")
	}
	if !sawUsage {
		t.Error("expected a CHUNK_TYPE_USAGE event on the wire (converter regression)")
	}
	if usageInput != 10 {
		t.Errorf("usage.input_tokens=%d want 10", usageInput)
	}
	if terminal == nil {
		t.Fatal("no terminal event received")
	}
	if terminal.Status != spaltv1.StreamRunStatus_STREAM_RUN_STATUS_COMPLETED {
		t.Errorf("terminal status=%v want COMPLETED", terminal.Status)
	}
	if terminal.Id != runID.String() {
		t.Errorf("terminal id=%q want %q", terminal.Id, runID.String())
	}
}

func TestSubscribeStream_FromSequenceSkipsPriorChunks(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	// Drive a complete run first so the chunks land in the DB.
	src := make(chan providers.Chunk, 8)
	for i, txt := range []string{"a", "b", "c", "d"} {
		_ = i
		src <- textChunk(txt)
	}
	src <- doneChunk()
	close(src)

	runID, err := f.sup.Start(context.Background(), f.startParams(src, stream.PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	// Wait for terminal so all chunks are persisted.
	deadline := time.Now().Add(3 * time.Second)
	for {
		row, _ := f.sup.Get(context.Background(), runID)
		if row.Status != "running" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("run did not finish in time")
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Subscribe from sequence 2 — should skip "a" (seq 0) and "b" (seq 1).
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	streamCli, err := f.client.SubscribeStream(ctx, connect.NewRequest(&spaltv1.SubscribeStreamRequest{
		StreamRunId:  runID.String(),
		FromSequence: 2,
	}))
	if err != nil {
		t.Fatalf("SubscribeStream open: %v", err)
	}
	defer streamCli.Close()

	var seqs []int64
	var sawTerminal bool
	for streamCli.Receive() {
		ev := streamCli.Msg().Event
		switch e := ev.(type) {
		case *spaltv1.SubscribeStreamResponse_Chunk:
			seqs = append(seqs, e.Chunk.Sequence)
		case *spaltv1.SubscribeStreamResponse_Terminal:
			sawTerminal = true
		}
	}
	if err := streamCli.Err(); err != nil {
		t.Fatalf("Receive err: %v", err)
	}
	if !sawTerminal {
		t.Error("expected terminal event")
	}
	for _, seq := range seqs {
		if seq < 2 {
			t.Errorf("got chunk with seq=%d, want >= 2 (FromSequence honored?)", seq)
		}
	}
	// Should have at least the two remaining text chunks ("c", "d") plus done = 3 chunks.
	if len(seqs) < 3 {
		t.Errorf("got %d chunks, expected at least 3 (chunks at seq 2,3 + done)", len(seqs))
	}
}

// (Note: a "client cancels mid-stream" test would be a useful addition but
// requires careful handling of the Connect server-stream + supervisor +
// open source-channel cleanup. The contracts under test there belong more
// to internal/stream than to streamsvc — leaving as a follow-up.)

func TestSubscribeStream_AlreadyTerminal(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	src := make(chan providers.Chunk, 4)
	src <- textChunk("only")
	src <- doneChunk()
	close(src)
	runID, err := f.sup.Start(context.Background(), f.startParams(src, stream.PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := waitTerminal(t, f.sup, runID, 3*time.Second); err != nil {
		t.Fatal(err)
	}

	// Subscribe AFTER the run has fully terminated. Should still get all
	// persisted chunks via DB replay + a terminal event.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	streamCli, err := f.client.SubscribeStream(ctx, connect.NewRequest(&spaltv1.SubscribeStreamRequest{
		StreamRunId: runID.String(),
	}))
	if err != nil {
		t.Fatalf("SubscribeStream open: %v", err)
	}
	defer streamCli.Close()
	var sawTerminal bool
	var chunkCount int
	for streamCli.Receive() {
		ev := streamCli.Msg().Event
		switch ev.(type) {
		case *spaltv1.SubscribeStreamResponse_Chunk:
			chunkCount++
		case *spaltv1.SubscribeStreamResponse_Terminal:
			sawTerminal = true
		}
	}
	if !sawTerminal {
		t.Error("expected terminal event")
	}
	if chunkCount == 0 {
		t.Error("expected at least one chunk via DB replay")
	}
}

// --- CancelStream ----------------------------------------------------------

func TestCancelStream_InvalidUUID(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := f.client.CancelStream(context.Background(), connect.NewRequest(&spaltv1.CancelStreamRequest{
		StreamRunId: "not-a-uuid",
	}))
	expectCode(t, err, connect.CodeInvalidArgument)
}

func TestCancelStream_NotFound(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := f.client.CancelStream(context.Background(), connect.NewRequest(&spaltv1.CancelStreamRequest{
		StreamRunId: mustUUID(t).String(),
	}))
	expectCode(t, err, connect.CodeNotFound)
}

func TestCancelStream_HappyPath(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	// Long-lived source so cancel actually has work to do.
	src := make(chan providers.Chunk, 4)
	runID, err := f.sup.Start(context.Background(), f.startParams(src, stream.PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	if _, err := f.client.CancelStream(context.Background(), connect.NewRequest(&spaltv1.CancelStreamRequest{
		StreamRunId: runID.String(),
	})); err != nil {
		t.Fatalf("CancelStream: %v", err)
	}

	// Source still needs to close so the supervisor goroutine exits.
	close(src)
	if err := waitTerminal(t, f.sup, runID, 3*time.Second); err != nil {
		t.Fatal(err)
	}
	row, _ := f.sup.Get(context.Background(), runID)
	if row.Status != "cancelled" {
		t.Errorf("status=%q want cancelled", row.Status)
	}
}

// --- GetStreamRun ----------------------------------------------------------

func TestGetStreamRun_InvalidUUID(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := f.client.GetStreamRun(context.Background(), connect.NewRequest(&spaltv1.GetStreamRunRequest{
		StreamRunId: "not-a-uuid",
	}))
	expectCode(t, err, connect.CodeInvalidArgument)
}

func TestGetStreamRun_NotFound(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := f.client.GetStreamRun(context.Background(), connect.NewRequest(&spaltv1.GetStreamRunRequest{
		StreamRunId: mustUUID(t).String(),
	}))
	expectCode(t, err, connect.CodeNotFound)
}

func TestGetStreamRun_HappyPath(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	src := make(chan providers.Chunk, 4)
	src <- textChunk("done")
	src <- doneChunk()
	close(src)
	runID, err := f.sup.Start(context.Background(), f.startParams(src, stream.PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	_ = waitTerminal(t, f.sup, runID, 3*time.Second)

	resp, err := f.client.GetStreamRun(context.Background(), connect.NewRequest(&spaltv1.GetStreamRunRequest{
		StreamRunId: runID.String(),
	}))
	if err != nil {
		t.Fatalf("GetStreamRun: %v", err)
	}
	if resp.Msg.StreamRun == nil {
		t.Fatal("nil StreamRun in response")
	}
	if resp.Msg.StreamRun.Id != runID.String() {
		t.Errorf("id=%q want %q", resp.Msg.StreamRun.Id, runID.String())
	}
	if resp.Msg.StreamRun.Status != spaltv1.StreamRunStatus_STREAM_RUN_STATUS_COMPLETED {
		t.Errorf("status=%v want COMPLETED", resp.Msg.StreamRun.Status)
	}
	if resp.Msg.StreamRun.Purpose != spaltv1.StreamRunPurpose_STREAM_RUN_PURPOSE_ASSISTANT_RESPONSE {
		t.Errorf("purpose=%v want ASSISTANT_RESPONSE", resp.Msg.StreamRun.Purpose)
	}
	if resp.Msg.StreamRun.ConversationId != f.conv.ID.String() {
		t.Errorf("conversation_id=%q want %q", resp.Msg.StreamRun.ConversationId, f.conv.ID.String())
	}
	if resp.Msg.StreamRun.ProviderId != f.prov.ID.String() {
		t.Errorf("provider_id=%q want %q", resp.Msg.StreamRun.ProviderId, f.prov.ID.String())
	}
	if resp.Msg.StreamRun.GetEndedAt() == nil {
		t.Error("ended_at should be set on a terminal run")
	}
	if resp.Msg.StreamRun.GetResultMessageId() == "" {
		t.Error("result_message_id should be set on a completed assistant run")
	}
}

// --- Conversion functions (pure unit tests) --------------------------------

func TestStatusToProto(t *testing.T) {
	t.Parallel()
	cases := map[string]spaltv1.StreamRunStatus{
		"running":     spaltv1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING,
		"completed":   spaltv1.StreamRunStatus_STREAM_RUN_STATUS_COMPLETED,
		"errored":     spaltv1.StreamRunStatus_STREAM_RUN_STATUS_ERRORED,
		"cancelled":   spaltv1.StreamRunStatus_STREAM_RUN_STATUS_CANCELLED,
		"interrupted": spaltv1.StreamRunStatus_STREAM_RUN_STATUS_INTERRUPTED,
		"":            spaltv1.StreamRunStatus_STREAM_RUN_STATUS_UNSPECIFIED,
		"garbage":     spaltv1.StreamRunStatus_STREAM_RUN_STATUS_UNSPECIFIED,
	}
	for in, want := range cases {
		if got := statusToProto(in); got != want {
			t.Errorf("statusToProto(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestPurposeToProto(t *testing.T) {
	t.Parallel()
	cases := map[string]spaltv1.StreamRunPurpose{
		"assistant_response": spaltv1.StreamRunPurpose_STREAM_RUN_PURPOSE_ASSISTANT_RESPONSE,
		"compression":        spaltv1.StreamRunPurpose_STREAM_RUN_PURPOSE_COMPRESSION,
		"":                   spaltv1.StreamRunPurpose_STREAM_RUN_PURPOSE_UNSPECIFIED,
		"garbage":            spaltv1.StreamRunPurpose_STREAM_RUN_PURPOSE_UNSPECIFIED,
	}
	for in, want := range cases {
		if got := purposeToProto(in); got != want {
			t.Errorf("purposeToProto(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestChunkTypeToProto(t *testing.T) {
	t.Parallel()
	cases := map[providers.ChunkType]spaltv1.ChunkType{
		providers.ChunkText:              spaltv1.ChunkType_CHUNK_TYPE_TEXT_DELTA,
		providers.ChunkThinking:          spaltv1.ChunkType_CHUNK_TYPE_THINKING_DELTA,
		providers.ChunkToolUseStart:      spaltv1.ChunkType_CHUNK_TYPE_TOOL_USE_START,
		providers.ChunkToolUseDelta:      spaltv1.ChunkType_CHUNK_TYPE_TOOL_USE_DELTA,
		providers.ChunkToolUseEnd:        spaltv1.ChunkType_CHUNK_TYPE_TOOL_USE_END,
		providers.ChunkUsage:             spaltv1.ChunkType_CHUNK_TYPE_USAGE,
		providers.ChunkError:             spaltv1.ChunkType_CHUNK_TYPE_ERROR,
		providers.ChunkDone:              spaltv1.ChunkType_CHUNK_TYPE_DONE,
		providers.ChunkToolResult:        spaltv1.ChunkType_CHUNK_TYPE_TOOL_RESULT,
		providers.ChunkThinkingSignature: spaltv1.ChunkType_CHUNK_TYPE_THINKING_SIGNATURE,
		providers.ChunkElicit:            spaltv1.ChunkType_CHUNK_TYPE_ELICIT,
		providers.ChunkDeviceToolUse:     spaltv1.ChunkType_CHUNK_TYPE_DEVICE_TOOL_USE,
		providers.ChunkType("???"):       spaltv1.ChunkType_CHUNK_TYPE_UNSPECIFIED,
	}
	for in, want := range cases {
		if got := chunkTypeToProto(in); got != want {
			t.Errorf("chunkTypeToProto(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestStreamRunToProto_OptionalFieldsRoundTrip(t *testing.T) {
	t.Parallel()
	// Minimal: only required fields set.
	provID := mustUUID(t)
	in := store.StreamRun{
		ID:             mustUUID(t),
		ConversationID: mustUUID(t),
		ContextID:      mustUUID(t),
		ProviderID:     &provID,
		ModelID:        "m",
		Status:         "running",
		Purpose:        "assistant_response",
		StartedAt:      time.Now().UTC(),
	}
	got := streamRunToProto(in)
	if got.GetParentMessageId() != "" {
		t.Errorf("ParentMessageId should be unset; got %q", got.GetParentMessageId())
	}
	if got.GetEndedAt() != nil {
		t.Errorf("EndedAt should be unset; got %v", got.GetEndedAt())
	}
	if got.GetResultMessageId() != "" {
		t.Errorf("ResultMessageId should be unset; got %q", got.GetResultMessageId())
	}
	if got.GetResultContextId() != "" {
		t.Errorf("ResultContextId should be unset; got %q", got.GetResultContextId())
	}

	// Full: every optional populated.
	parent := mustUUID(t)
	resultMsg := mustUUID(t)
	resultCtx := mustUUID(t)
	ended := time.Now().UTC().Add(time.Second)
	in.ParentMessageID = &parent
	in.ResultMessageID = &resultMsg
	in.ResultContextID = &resultCtx
	in.EndedAt = &ended
	in.ErrorPayload = []byte(`{"err":"x"}`)
	got = streamRunToProto(in)
	if got.GetParentMessageId() != parent.String() {
		t.Errorf("ParentMessageId=%q want %q", got.GetParentMessageId(), parent)
	}
	if got.GetResultMessageId() != resultMsg.String() {
		t.Errorf("ResultMessageId=%q want %q", got.GetResultMessageId(), resultMsg)
	}
	if got.GetResultContextId() != resultCtx.String() {
		t.Errorf("ResultContextId=%q want %q", got.GetResultContextId(), resultCtx)
	}
	if got.GetEndedAt() == nil {
		t.Error("EndedAt should be set")
	}
	if string(got.ErrorPayload) != `{"err":"x"}` {
		t.Errorf("ErrorPayload=%q want %q", got.ErrorPayload, `{"err":"x"}`)
	}
}

// --- ListActiveRuns --------------------------------------------------------

// ListActiveRuns is called directly (not through the HTTP client) so we
// can attach a user via `auth.ContextWithUser` — the test mux has no
// auth interceptor, so anything reaching the handler via the HTTP client
// would panic on `auth.MustFromContext`. Directly-invoked still uses
// the real Service struct, real queries, real supervisor.
func TestListActiveRuns_FiltersByConversationAndStatus(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	svc := NewService(f.q, f.sup)
	ctx := authContextForUser(f.user)

	// Conversation A: one running run.
	srcA := newFakeSource(0)
	runA, err := f.sup.Start(context.Background(), f.startParams(srcA.recv(), stream.PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start A: %v", err)
	}

	// Conversation B (separate convo, same user): one running run.
	convBID := mustUUID(t)
	convB, err := f.q.CreateConversation(context.Background(), store.CreateConversationParams{
		ID: convBID, UserID: f.user.ID, ProfileID: f.conv.ProfileID,
	})
	if err != nil {
		t.Fatalf("CreateConversation B: %v", err)
	}
	cctxBID := mustUUID(t)
	cctxB, err := f.q.CreateContext(context.Background(), store.CreateContextParams{
		ID: cctxBID, ConversationID: convB.ID, ContextActivationTime: time.Now().UTC(),
	})
	if err != nil {
		t.Fatalf("CreateContext B: %v", err)
	}
	parentBID := mustUUID(t)
	if _, err := f.q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID: parentBID, ContextID: cctxB.ID, Role: "user", Content: "hi b",
	}); err != nil {
		t.Fatalf("CreateMessage B: %v", err)
	}
	srcB := newFakeSource(0)
	runB, err := f.sup.Start(context.Background(), stream.StartParams{
		ConversationID: convB.ID, ContextID: cctxB.ID, ParentMessageID: &parentBID,
		ProviderID: f.prov.ID, ModelID: "gpt-test",
		Purpose: stream.PurposeAssistantResponse, Source: srcB.recv(),
	})
	if err != nil {
		t.Fatalf("Start B: %v", err)
	}

	// All-active: caller sees both A and B.
	resp, err := svc.ListActiveRuns(ctx, connect.NewRequest(&spaltv1.ListActiveRunsRequest{}))
	if err != nil {
		t.Fatalf("ListActiveRuns(all): %v", err)
	}
	if len(resp.Msg.Runs) != 2 {
		t.Errorf("all-active count = %d, want 2", len(resp.Msg.Runs))
	}

	// Filtered to conversation A: just runA.
	convAID := f.conv.ID.String()
	resp, err = svc.ListActiveRuns(ctx, connect.NewRequest(&spaltv1.ListActiveRunsRequest{
		ConversationId: &convAID,
	}))
	if err != nil {
		t.Fatalf("ListActiveRuns(A): %v", err)
	}
	if len(resp.Msg.Runs) != 1 || resp.Msg.Runs[0].Id != runA.String() {
		t.Errorf("convo-A filtered = %+v, want only %s", resp.Msg.Runs, runA)
	}

	// Terminate A: it should disappear from the all-active list.
	srcA.close()
	_ = waitTerminal(t, f.sup, runA, 2*time.Second)
	resp, err = svc.ListActiveRuns(ctx, connect.NewRequest(&spaltv1.ListActiveRunsRequest{}))
	if err != nil {
		t.Fatalf("ListActiveRuns(post-terminal): %v", err)
	}
	if len(resp.Msg.Runs) != 1 || resp.Msg.Runs[0].Id != runB.String() {
		t.Errorf("post-terminal = %+v, want only %s", resp.Msg.Runs, runB)
	}
	srcB.close()
	_ = waitTerminal(t, f.sup, runB, 2*time.Second)
}

func TestListActiveRuns_ScopedByCaller(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	svc := NewService(f.q, f.sup)

	// Start a run owned by f.user.
	srcA := newFakeSource(0)
	if _, err := f.sup.Start(context.Background(), f.startParams(srcA.recv(), stream.PurposeAssistantResponse)); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer srcA.close()

	// Different user must NOT see the run.
	other := mustCreateUser(t, f.q, "u-"+mustUUID(t).String())
	otherCtx := authContextForUser(other)
	resp, err := svc.ListActiveRuns(otherCtx, connect.NewRequest(&spaltv1.ListActiveRunsRequest{}))
	if err != nil {
		t.Fatalf("ListActiveRuns(other): %v", err)
	}
	if len(resp.Msg.Runs) != 0 {
		t.Errorf("other user saw %d runs, want 0", len(resp.Msg.Runs))
	}
}

func authContextForUser(u store.User) context.Context {
	return auth.ContextWithUser(context.Background(), auth.User{
		ID: u.ID, Username: u.Username, IsAdmin: u.IsAdmin,
		CreatedAt: u.CreatedAt, UpdatedAt: u.UpdatedAt,
	})
}

// fakeSource emits canned chunks on demand for the active-runs tests.
// Independent from the rest of the file's HTTP-client driven tests so we
// don't accidentally introduce a panic-on-no-auth fixture.
type fakeSource struct {
	ch chan providers.Chunk
}

func newFakeSource(buffer int) *fakeSource {
	return &fakeSource{ch: make(chan providers.Chunk, buffer)}
}
func (f *fakeSource) close()                       { close(f.ch) }
func (f *fakeSource) recv() <-chan providers.Chunk { return f.ch }

// --- helpers ---------------------------------------------------------------

// waitTerminal polls the supervisor until the run is in a terminal status or
// the deadline expires.
func waitTerminal(t *testing.T, sup *stream.Supervisor, runID uuid.UUID, timeout time.Duration) error {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		row, err := sup.Get(context.Background(), runID)
		if err != nil {
			return err
		}
		if row.Status != "running" {
			return nil
		}
		if time.Now().After(deadline) {
			return errors.New("timed out waiting for terminal")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
