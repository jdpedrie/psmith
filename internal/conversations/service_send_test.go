package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/profiles"
	"github.com/jdpedrie/psmith/internal/providers"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/stream"
	"github.com/jdpedrie/psmith/internal/testutil"
)

// --- fake driver setup ---

type fakeStatelessDriver struct {
	typeName string
	chunks   []providers.Chunk
	sendErr  error
	// Last request received by Send. Captured under mu for tests that want
	// to inspect what the driver was handed (settings, conversation_id,
	// wire prefix). Per-instance, fine for the single-Send tests we run.
	mu          sync.Mutex
	lastRequest *providers.SendRequest
}

func (f *fakeStatelessDriver) Type() string   { return f.typeName }
func (f *fakeStatelessDriver) Stateful() bool { return false }
func (f *fakeStatelessDriver) DiscoverModels(_ context.Context) ([]providers.Model, error) {
	return nil, nil
}
func (f *fakeStatelessDriver) RenderThinkingToText(_ json.RawMessage) string { return "" }

func (f *fakeStatelessDriver) Send(_ context.Context, req providers.SendRequest) (<-chan providers.Chunk, error) {
	f.mu.Lock()
	cp := req
	f.lastRequest = &cp
	f.mu.Unlock()
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

// uniqueDriverName produces a registry-unique driver type per test (the
// providers.Register registry is process-global and panics on duplicates).
func uniqueDriverName(t *testing.T, prefix string) string {
	t.Helper()
	n := strings.ReplaceAll(t.Name(), "/", "_")
	return prefix + "-" + n
}

// driverByType lets tests recover the fake driver instance that was built
// from a registered type. Indexed at registration so we can fetch the
// captured request after SendMessage runs.
var driverByType sync.Map

func registerFakeDriver(t *testing.T, prefix string, chunks []providers.Chunk, sendErr error) string {
	t.Helper()
	typeName := uniqueDriverName(t, prefix)
	providers.Register(typeName, func(_ providers.Deps, _ json.RawMessage) (providers.Provider, error) {
		// One driver instance per Build so each test gets a fresh
		// lastRequest; we cache *the latest one* in the global map.
		d := &fakeStatelessDriver{typeName: typeName, chunks: chunks, sendErr: sendErr}
		driverByType.Store(typeName, d)
		return d, nil
	})
	return typeName
}

// fetchDriver pulls the last-built fake driver for a type. Test must call
// after SendMessage so the driver has actually been instantiated.
func fetchDriver(t *testing.T, typeName string) *fakeStatelessDriver {
	t.Helper()
	v, ok := driverByType.Load(typeName)
	if !ok {
		t.Fatalf("no driver registered for type %q", typeName)
	}
	return v.(*fakeStatelessDriver)
}

// --- test scaffolding ---

func newFullSvc(t *testing.T) (*Service, *store.Queries, *stream.Supervisor) {
	t.Helper()
	svc, q, sup, _ := newFullSvcWithPool(t)
	return svc, q, sup
}

// newFullSvcWithPool is like newFullSvc but also returns the underlying pgx
// pool for tests that need raw SQL access (e.g., to verify ON DELETE
// constraint behavior the store layer doesn't expose).
func newFullSvcWithPool(t *testing.T) (*Service, *store.Queries, *stream.Supervisor, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	return NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default()), q, sup, pool
}

func textChunk(s string) providers.Chunk {
	raw, _ := json.Marshal(map[string]string{"text": s})
	return providers.Chunk{Type: providers.ChunkText, Payload: raw}
}

func doneChunk() providers.Chunk {
	return providers.Chunk{Type: providers.ChunkDone, Payload: []byte(`{}`)}
}

// seedSendable builds a full stack ready for SendMessage: user, profile,
// conversation with one active context (plus the system seed message), a
// user_model_provider with the registered fake driver, and an enabled model.
type sendFixture struct {
	user        store.User
	profile     store.Profile
	conv        store.Conversation
	contextID   uuid.UUID
	systemMsgID uuid.UUID
	provider    store.UserModelProvider
	modelID     string
}

func seedSendable(t *testing.T, q *store.Queries, driverType string) sendFixture {
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
	prov, err := q.CreateUserModelProvider(ctx, store.CreateUserModelProviderParams{
		ID: prid, UserID: user.ID, Type: driverType, Label: "test", ConfigEncrypted: []byte("{}"),
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}

	modelID := "fake-model"
	if _, err := q.UpsertUserModel(ctx, store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             modelID,
		DisplayName:         "Fake Model",
		MetadataSource:      "manual",
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}

	return sendFixture{
		user: user, profile: profile, conv: conv,
		contextID: ctxRow.ID, systemMsgID: sysMsg.ID,
		provider: prov, modelID: modelID,
	}
}

func ctxAsUser(u store.User) context.Context {
	return auth.ContextWithUser(context.Background(), auth.User{
		ID: u.ID, Username: u.Username, IsAdmin: u.IsAdmin,
		CreatedAt: u.CreatedAt, UpdatedAt: u.UpdatedAt,
	})
}

// waitForTerminal polls supervisor.Get until the run reaches a terminal status
// or the timeout expires.
func waitForTerminal(t *testing.T, sup *stream.Supervisor, runID uuid.UUID) store.StreamRun {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		row, err := sup.Get(context.Background(), runID)
		if err != nil {
			t.Fatalf("supervisor.Get: %v", err)
		}
		if row.Status != "running" {
			return row
		}
		if time.Now().After(deadline) {
			t.Fatalf("stream did not reach terminal in time; status=%s", row.Status)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// --- happy path ---

func TestSendMessage_Success_MaterializesAssistant(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "send-ok",
		[]providers.Chunk{textChunk("Hello"), textChunk(", world!"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	if resp.Msg.UserMessage == nil || resp.Msg.UserMessage.Content != "hi" {
		t.Errorf("user message wrong: %+v", resp.Msg.UserMessage)
	}
	if resp.Msg.UserMessage.GetParentId() != f.systemMsgID.String() {
		t.Errorf("user message parent should be system msg, got %q", resp.Msg.UserMessage.GetParentId())
	}
	if resp.Msg.StreamRun == nil || resp.Msg.StreamRun.Status != psmithv1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING {
		t.Errorf("stream_run not in running state: %+v", resp.Msg.StreamRun)
	}

	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Errorf("final status %q want completed; error_payload=%s", final.Status, string(final.ErrorPayload))
	}
	if final.ResultMessageID == nil {
		t.Fatal("expected result_message_id set")
	}
	asst, err := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID: %v", err)
	}
	if asst.Role != "assistant" || asst.Content != "Hello, world!" {
		t.Errorf("assistant message wrong: role=%q content=%q", asst.Role, asst.Content)
	}
	parentID, _ := uuid.Parse(resp.Msg.UserMessage.Id)
	if asst.ParentID == nil || *asst.ParentID != parentID {
		t.Errorf("assistant parent mismatch: %+v vs %v", asst.ParentID, parentID)
	}
}

// --- request validation ---

func TestSendMessage_MissingContent(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "no-content", nil, nil)
	f := seedSendable(t, q, driverType)
	pid := f.provider.ID.String()
	mid := f.modelID
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestSendMessage_InvalidConversationID(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "bad-cid", nil, nil)
	f := seedSendable(t, q, driverType)
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: "not-a-uuid", Content: "hi",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestSendMessage_CrossUserConversation(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "cross-user", nil, nil)
	f := seedSendable(t, q, driverType)

	bid, _ := uuid.NewV7()
	bob, _ := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: bid, Username: "bob-" + t.Name(), PasswordHash: "x",
	})

	pid := f.provider.ID.String()
	mid := f.modelID
	_, err := svc.SendMessage(ctxAsUser(bob), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestSendMessage_ProviderNotOwned(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "prov-foreign", nil, nil)
	f := seedSendable(t, q, driverType)

	// Make a second user + their own provider; try to send using their provider on Alice's conversation.
	bid, _ := uuid.NewV7()
	bob, _ := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: bid, Username: "bob-" + t.Name(), PasswordHash: "x",
	})
	bpid, _ := uuid.NewV7()
	bobProv, _ := q.CreateUserModelProvider(context.Background(), store.CreateUserModelProviderParams{
		ID: bpid, UserID: bob.ID, Type: driverType, Label: "bob-prov", ConfigEncrypted: []byte("{}"),
	})
	pid := bobProv.ID.String()
	mid := "anything"
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestSendMessage_ModelNotEnabled(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "model-missing", nil, nil)
	f := seedSendable(t, q, driverType)
	pid := f.provider.ID.String()
	mid := "not-enabled"
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestSendMessage_ProviderIDWithoutModelID(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "half-override", nil, nil)
	f := seedSendable(t, q, driverType)
	pid := f.provider.ID.String()
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestSendMessage_NoProviderResolved(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "no-resolve", nil, nil)
	f := seedSendable(t, q, driverType)
	// No per-turn override, no conversation defaults, no profile defaults → InvalidArgument.
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- resolution chain ---

func TestSendMessage_ResolvesFromConversationSettings(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "conv-default", []providers.Chunk{textChunk("ok"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	// Set conversation settings to point at the provider/model.
	pidStr := f.provider.ID.String()
	settings := psmithv1.ConversationSettings{
		DefaultProviderId: &pidStr,
		DefaultModelId:    &f.modelID,
	}
	settingsJSON, _ := json.Marshal(&settings)
	if err := q.UpdateConversationSettings(context.Background(), store.UpdateConversationSettingsParams{
		ID: f.conv.ID, Settings: settingsJSON,
	}); err != nil {
		t.Fatalf("UpdateConversationSettings: %v", err)
	}

	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		// no per-turn provider/model — should resolve from conversation settings
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Errorf("final status %q want completed", final.Status)
	}
}

// --- driver errors ---

// TestSendMessage_DriverSendFails: when driver.Send fails repeatedly, the
// SendMessage RPC still succeeds — the user-message row is inserted, the
// stream_run is created, and the supervisor materialises an errored
// assistant message with the failure inline (`messages.error_payload`).
// This is the "never lose the user's typed text to a transient blip"
// contract; Reload becomes the natural retry surface.
//
// `withFastSendRetry` shrinks the backoff/timeout vars to keep this test
// in the millisecond range despite the 3-attempt loop in the helper.
func TestSendMessage_DriverSendFails(t *testing.T) {
	t.Parallel()
	withFastSendRetry(t)
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "send-err", nil, errors.New("upstream broken"))
	f := seedSendable(t, q, driverType)
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage should succeed even when driver fails; got %v", err)
	}
	if resp.Msg.UserMessage == nil {
		t.Fatal("user_message must be populated")
	}
	if resp.Msg.StreamRun == nil {
		t.Fatal("stream_run must be populated")
	}
	// Wait for the supervisor to finalise the run, then assert the
	// materialised assistant row carries the upstream error inline.
	runID, err := uuid.Parse(resp.Msg.StreamRun.Id)
	if err != nil {
		t.Fatalf("parse run id: %v", err)
	}
	final := waitForTerminal(t, sup, runID)
	if final.Status != "errored" {
		t.Errorf("stream_run status %q want errored", final.Status)
	}
	if final.ResultMessageID == nil {
		t.Fatal("expected materialised assistant message id on errored run")
	}
	got, err := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if err != nil {
		t.Fatalf("load result message: %v", err)
	}
	if len(got.ErrorPayload) == 0 {
		t.Fatal("expected errored assistant message to carry error_payload")
	}
	if !strings.Contains(string(got.ErrorPayload), "upstream broken") {
		t.Errorf("error_payload should mention driver error; got %s", string(got.ErrorPayload))
	}
}

// withFastSendRetry shrinks the supervisor's send-retry policy
// (`internal/stream`) to milliseconds so tests exercising the retry
// loop don't spend real seconds sleeping between attempts. Cleanup
// restores the production values via t.Cleanup.
func withFastSendRetry(t *testing.T) {
	t.Helper()
	prevAttempts := stream.MaxSendAttempts
	prevTimeout := stream.PerAttemptTimeout
	prevBackoff := stream.InitialBackoff
	stream.MaxSendAttempts = 3
	stream.PerAttemptTimeout = 200 * time.Millisecond
	stream.InitialBackoff = 1 * time.Millisecond
	t.Cleanup(func() {
		stream.MaxSendAttempts = prevAttempts
		stream.PerAttemptTimeout = prevTimeout
		stream.InitialBackoff = prevBackoff
	})
}

// --- nil deps ---

// TestSendMessage_FourLayerCallSettingsMerge sets temperature on the
// provider, top_p on the model, max_tokens on the profile, and overrides
// temperature on the conversation. Asserts the driver receives:
//
//	temperature → 0.7  (conversation; overrides provider's 0.4)
//	top_p       → 0.9  (model)
//	max_tokens  → 4096 (profile)
//
// This exercises every layer of the resolution chain and the per-field
// sparse merge across them.
func TestSendMessage_FourLayerCallSettingsMerge(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "merge",
		[]providers.Chunk{textChunk("ok"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	ctx := context.Background()

	// Layer 4 (lowest): provider sets temperature=0.4.
	provCS := &psmithv1.CallSettings{Temperature: f64ptr(0.4)}
	provBlob, err := profiles.MarshalCallSettings(provCS)
	if err != nil {
		t.Fatalf("marshal provider cs: %v", err)
	}
	if err := q.UpdateUserModelProviderDefaultSettings(ctx, store.UpdateUserModelProviderDefaultSettingsParams{
		ID: f.provider.ID, DefaultSettings: provBlob,
	}); err != nil {
		t.Fatalf("update provider settings: %v", err)
	}

	// Layer 3: model sets top_p=0.9.
	modelCS := &psmithv1.CallSettings{TopP: f64ptr(0.9)}
	modelBlob, err := profiles.MarshalCallSettings(modelCS)
	if err != nil {
		t.Fatalf("marshal model cs: %v", err)
	}
	// Overwrite the user_model row with the new default_settings. The
	// fixture upserts with empty defaults; we re-upsert with the blob.
	if _, err := q.UpsertUserModel(ctx, store.UpsertUserModelParams{
		UserModelProviderID: f.provider.ID,
		ModelID:             f.modelID,
		DisplayName:         "Fake Model",
		MetadataSource:      "manual",
		MetadataSnapshotAt:  time.Now().UTC(),
		DefaultSettings:     modelBlob,
	}); err != nil {
		t.Fatalf("upsert model: %v", err)
	}

	// Layer 2: profile sets max_output_tokens=4096 inside default_settings.call_settings.
	profileCS := &psmithv1.CallSettings{MaxOutputTokens: i32ptr(4096)}
	profileCSBlob, err := profiles.MarshalCallSettings(profileCS)
	if err != nil {
		t.Fatalf("marshal profile cs: %v", err)
	}
	wrapper := struct {
		CallSettings json.RawMessage `json:"call_settings"`
	}{CallSettings: profileCSBlob}
	profileBlob, err := json.Marshal(wrapper)
	if err != nil {
		t.Fatalf("marshal profile wrapper: %v", err)
	}
	if err := q.UpdateProfileDefaultSettings(ctx, store.UpdateProfileDefaultSettingsParams{
		ID: f.profile.ID, DefaultSettings: profileBlob,
	}); err != nil {
		t.Fatalf("update profile defaults: %v", err)
	}

	// Layer 1 (highest): conversation overrides temperature=0.7.
	convCS := &psmithv1.ConversationSettings{
		CallSettings: &psmithv1.CallSettings{Temperature: f64ptr(0.7)},
	}
	convBlob, err := json.Marshal(convCS)
	if err != nil {
		t.Fatalf("marshal conv settings: %v", err)
	}
	if err := q.UpdateConversationSettings(ctx, store.UpdateConversationSettingsParams{
		ID: f.conv.ID, Settings: convBlob,
	}); err != nil {
		t.Fatalf("update conv settings: %v", err)
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	if _, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hello",
		ProviderId:     &pid,
		ModelId:        &mid,
	})); err != nil {
		t.Fatalf("SendMessage: %v", err)
	}

	d := fetchDriver(t, driverType)
	d.mu.Lock()
	got := d.lastRequest
	d.mu.Unlock()
	if got == nil {
		t.Fatal("driver never received a Send call")
	}
	cs := got.Settings
	if cs.Temperature == nil || *cs.Temperature != 0.7 {
		t.Errorf("temperature: %v want 0.7 (conversation override)", cs.Temperature)
	}
	if cs.TopP == nil || *cs.TopP != 0.9 {
		t.Errorf("top_p: %v want 0.9 (from model)", cs.TopP)
	}
	if cs.MaxOutputTokens == nil || *cs.MaxOutputTokens != 4096 {
		t.Errorf("max_output_tokens: %v want 4096 (from profile)", cs.MaxOutputTokens)
	}
	if got.ConversationID != f.conv.ID.String() {
		t.Errorf("conversation_id: %q want %q", got.ConversationID, f.conv.ID.String())
	}
}

func f64ptr(v float64) *float64 { return &v }
func i32ptr(v int32) *int32     { return &v }

func TestSendMessage_NoSupervisor_Unimplemented(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	svc := NewService(q, nil, nil, nil, crypto.Nop{}, nil, nil) // no pool, no catalog, no supervisor

	uid, _ := uuid.NewV7()
	user, _ := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: uid, Username: t.Name(), PasswordHash: "x",
	})
	// Conversation id need not exist — the nil-deps check fires before lookup.
	pid := uuid.New().String()
	mid := "x"
	_, err := svc.SendMessage(ctxAsUser(user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: uuid.New().String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	assertCode(t, err, connect.CodeUnimplemented)
}
