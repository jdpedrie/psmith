package modelproviders

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/providers"
)

// fakeStatelessDriver is a minimal StatelessProvider with scripted Send output.
// It mirrors the conversations-package helper but lives here so the
// modelproviders test_actions tests don't depend on test-only types in another
// package.
type fakeStatelessDriver struct {
	typeName string
	models   []providers.Model
	discErr  error
	chunks   []providers.Chunk
	sendErr  error
}

func (f *fakeStatelessDriver) Type() string                                  { return f.typeName }
func (f *fakeStatelessDriver) Stateful() bool                                { return false }
func (f *fakeStatelessDriver) RenderThinkingToText(_ json.RawMessage) string { return "" }
func (f *fakeStatelessDriver) DiscoverModels(_ context.Context) ([]providers.Model, error) {
	if f.discErr != nil {
		return nil, f.discErr
	}
	return f.models, nil
}
func (f *fakeStatelessDriver) Send(_ context.Context, _ providers.SendRequest) (<-chan providers.Chunk, error) {
	if f.sendErr != nil {
		return nil, f.sendErr
	}
	ch := make(chan providers.Chunk, len(f.chunks)+1)
	for _, c := range f.chunks {
		ch <- c
	}
	close(ch)
	return ch, nil
}

func registerStatelessFakeDriver(t *testing.T, prefix string, models []providers.Model, discErr error, chunks []providers.Chunk, sendErr error) string {
	t.Helper()
	typeName := uniqueTypeName(t, prefix)
	providers.Register(typeName, func(_ providers.Deps, _ json.RawMessage) (providers.Provider, error) {
		return &fakeStatelessDriver{
			typeName: typeName, models: models, discErr: discErr,
			chunks: chunks, sendErr: sendErr,
		}, nil
	})
	return typeName
}

func textChunkP(s string) providers.Chunk {
	raw, _ := json.Marshal(map[string]string{"text": s})
	return providers.Chunk{Type: providers.ChunkText, Payload: raw}
}

func usageChunkP(input, output int) providers.Chunk {
	in, out := input, output
	raw, _ := json.Marshal(providers.Usage{InputTokens: &in, OutputTokens: &out})
	return providers.Chunk{Type: providers.ChunkUsage, Payload: raw}
}

func errorChunkP(msg string) providers.Chunk {
	raw, _ := json.Marshal(map[string]string{"message": msg})
	return providers.Chunk{Type: providers.ChunkError, Payload: raw}
}

func doneChunkP() providers.Chunk {
	return providers.Chunk{Type: providers.ChunkDone, Payload: []byte(`{}`)}
}

// --- TestUserModelProvider ---

func TestTestUserModelProvider_Success(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	models := []providers.Model{
		{ID: "m1", DisplayName: "Model 1"},
		{ID: "m2", DisplayName: "Model 2"},
	}
	typeName := registerStatelessFakeDriver(t, "test-prov-ok", models, nil, nil, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.TestUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelProviderRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("TestUserModelProvider: %v", err)
	}
	if !resp.Msg.Ok {
		t.Errorf("expected ok=true, got %+v", resp.Msg)
	}
	if resp.Msg.ModelCount != 2 {
		t.Errorf("expected model_count=2, got %d", resp.Msg.ModelCount)
	}
	if resp.Msg.LatencyMs < 0 {
		t.Errorf("latency_ms should be >= 0, got %d", resp.Msg.LatencyMs)
	}
	if resp.Msg.ErrorMessage != "" {
		t.Errorf("error_message should be empty on success, got %q", resp.Msg.ErrorMessage)
	}
}

func TestTestUserModelProvider_DriverError_PackedIntoResponse(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerStatelessFakeDriver(t, "test-prov-err", nil, errors.New("auth failed: 401"), nil, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.TestUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelProviderRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	if err != nil {
		// We DO NOT want an RPC error here — the failure should be in the body.
		t.Fatalf("expected no RPC error, got %v", err)
	}
	if resp.Msg.Ok {
		t.Error("expected ok=false")
	}
	if resp.Msg.ErrorMessage == "" {
		t.Error("expected error_message to be set")
	}
}

func TestTestUserModelProvider_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	typeName := registerStatelessFakeDriver(t, "test-prov-other", nil, nil, nil, nil)
	prov := makeProvider(t, q, alice.ID, typeName, "main", nil)

	_, err := svc.TestUserModelProvider(ctxAs(bob), connect.NewRequest(&psmithv1.TestUserModelProviderRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestTestUserModelProvider_UnknownDriverType_FailedPrecondition(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "no-such-driver-"+uuid.NewString(), "main", nil)

	_, err := svc.TestUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelProviderRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}

// --- TestUserModel ---

func TestTestUserModel_HappyPath(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	chunks := []providers.Chunk{
		textChunkP("OK"),
		usageChunkP(7, 1),
		doneChunkP(),
	}
	typeName := registerStatelessFakeDriver(t, "test-model-ok", nil, nil, chunks, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.TestUserModel(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "any-model-id",
	}))
	if err != nil {
		t.Fatalf("TestUserModel: %v", err)
	}
	if !resp.Msg.Ok {
		t.Errorf("expected ok=true, got %+v", resp.Msg)
	}
	if resp.Msg.SampleText != "OK" {
		t.Errorf("expected sample_text=OK, got %q", resp.Msg.SampleText)
	}
	if resp.Msg.InputTokens != 7 || resp.Msg.OutputTokens != 1 {
		t.Errorf("token counts: in=%d out=%d", resp.Msg.InputTokens, resp.Msg.OutputTokens)
	}
}

func TestTestUserModel_StreamErrorChunk_PackedIntoResponse(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	chunks := []providers.Chunk{
		errorChunkP("rate limited"),
		doneChunkP(),
	}
	typeName := registerStatelessFakeDriver(t, "test-model-err", nil, nil, chunks, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.TestUserModel(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "any-model-id",
	}))
	if err != nil {
		t.Fatalf("expected no RPC error, got %v", err)
	}
	if resp.Msg.Ok {
		t.Error("expected ok=false on stream error")
	}
	if resp.Msg.ErrorMessage != "rate limited" {
		t.Errorf("error_message: %q", resp.Msg.ErrorMessage)
	}
}

func TestTestUserModel_DriverSendError_PackedIntoResponse(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerStatelessFakeDriver(t, "test-model-send-err", nil, nil, nil, errors.New("connection refused"))
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.TestUserModel(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "any-model-id",
	}))
	if err != nil {
		t.Fatalf("expected no RPC error, got %v", err)
	}
	if resp.Msg.Ok {
		t.Error("expected ok=false")
	}
	if resp.Msg.ErrorMessage == "" {
		t.Error("expected error_message to be set")
	}
}

func TestTestUserModel_StatefulDriver_PackedFailure(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	// Register a non-stateless fake driver. The existing fakeDriver only
	// implements Provider, not StatelessProvider — exactly what we want.
	typeName := registerFakeDriver(t, "test-model-stateful", nil, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.TestUserModel(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "x",
	}))
	if err != nil {
		t.Fatalf("expected no RPC error for stateful driver, got %v", err)
	}
	if resp.Msg.Ok {
		t.Error("expected ok=false for non-stateless driver")
	}
	if resp.Msg.ErrorMessage == "" {
		t.Error("expected error_message explaining the limitation")
	}
}

func TestTestUserModel_EmptyModelID_InvalidArgument(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerStatelessFakeDriver(t, "test-model-noid", nil, nil, nil, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	_, err := svc.TestUserModel(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestTestUserModel_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	typeName := registerStatelessFakeDriver(t, "test-model-other", nil, nil, nil, nil)
	prov := makeProvider(t, q, alice.ID, typeName, "main", nil)

	_, err := svc.TestUserModel(ctxAs(bob), connect.NewRequest(&psmithv1.TestUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "x",
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestTestUserModel_NoOutput_PackedFailure(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	// Driver returns done with no text, no usage. We treat this as failure.
	chunks := []providers.Chunk{doneChunkP()}
	typeName := registerStatelessFakeDriver(t, "test-model-empty", nil, nil, chunks, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.TestUserModel(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "x",
	}))
	if err != nil {
		t.Fatalf("expected no RPC error, got %v", err)
	}
	if resp.Msg.Ok {
		t.Error("expected ok=false")
	}
	if resp.Msg.ErrorMessage == "" {
		t.Error("expected error_message to be set")
	}
}

func TestTestUserModel_SampleTextCappedAt80(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	long := ""
	for i := 0; i < 100; i++ {
		long += "x"
	}
	chunks := []providers.Chunk{textChunkP(long), doneChunkP()}
	typeName := registerStatelessFakeDriver(t, "test-model-long", nil, nil, chunks, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.TestUserModel(ctxAs(user), connect.NewRequest(&psmithv1.TestUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "x",
	}))
	if err != nil {
		t.Fatalf("TestUserModel: %v", err)
	}
	// 80 runes + ellipsis
	runes := []rune(resp.Msg.SampleText)
	if len(runes) != modelTestSampleCap+1 {
		t.Errorf("sample_text rune length = %d (text=%q), expected %d (cap + ellipsis)",
			len(runes), resp.Msg.SampleText, modelTestSampleCap+1)
	}
}

// --- helpers ---

func TestFirstLine(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"":                "",
		"single":          "single",
		"first\nsecond":   "first",
		"  spaced  ":      "spaced",
		"\nleading-blank": "leading-blank",
	}
	for in, want := range cases {
		if got := firstLine(in); got != want {
			t.Errorf("firstLine(%q)=%q want %q", in, got, want)
		}
	}
}

func TestCapSampleText(t *testing.T) {
	t.Parallel()
	if got := capSampleText("hello", 80); got != "hello" {
		t.Errorf("got %q", got)
	}
	if got := capSampleText("aaaaaa", 3); got != "aaa…" {
		t.Errorf("got %q", got)
	}
	// Multi-byte runes shouldn't get sliced.
	if got := capSampleText("日本語テスト", 3); got != "日本語…" {
		t.Errorf("multi-byte: got %q", got)
	}
}
