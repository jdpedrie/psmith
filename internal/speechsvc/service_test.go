package speechsvc

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/crypto"
	_ "github.com/jdpedrie/psmith/internal/speech/grok"
	_ "github.com/jdpedrie/psmith/internal/speech/openaicompat"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"
)

func newTestSvc(t *testing.T) (*Service, *store.Queries, crypto.Cipher) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	// A real cipher so the encrypt/decrypt round-trip is exercised.
	key := make([]byte, 32)
	for i := range key {
		key[i] = byte(i)
	}
	cipher, err := crypto.NewAESGCM(key)
	if err != nil {
		t.Fatalf("cipher: %v", err)
	}
	return NewService(q, cipher, nil), q, cipher
}

// mustCreateProvider inserts a chat-provider row with an encrypted
// config blob, the shape production writes.
func mustCreateProvider(t *testing.T, q *store.Queries, cipher crypto.Cipher, userID uuid.UUID, config string) store.UserModelProvider {
	t.Helper()
	enc, err := cipher.Encrypt([]byte(config))
	if err != nil {
		t.Fatalf("encrypt provider config: %v", err)
	}
	pid, _ := uuid.NewV7()
	prov, err := q.CreateUserModelProvider(context.Background(), store.CreateUserModelProviderParams{
		ID: pid, UserID: userID, Type: "openai-compatible", Label: "prov",
		ConfigEncrypted: enc,
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	return prov
}

func mustCreateUser(t *testing.T, q *store.Queries, username string) store.User {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	u, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: id, Username: username, PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	return u
}

func ctxAs(u store.User) context.Context {
	return auth.ContextWithUser(context.Background(), auth.User{
		ID: u.ID, Username: u.Username, IsAdmin: u.IsAdmin,
		CreatedAt: u.CreatedAt, UpdatedAt: u.UpdatedAt,
	})
}

func strPtr(s string) *string   { return &s }
func f64Ptr(v float64) *float64 { return &v }

func TestGetSpeechConfig_DefaultsToAppleLocal(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher
	user := mustCreateUser(t, q, "alice")

	resp, err := svc.GetSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.GetSpeechConfigRequest{}))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	cfg := resp.Msg.Config
	if cfg.Kind != KindAppleLocal || !cfg.Enabled || cfg.ApiKeySet {
		t.Errorf("default config: %+v", cfg)
	}
	if cfg.NormalizerVersion < 1 {
		t.Errorf("normalizer version should be exposed, got %d", cfg.NormalizerVersion)
	}
}

func TestUpdateSpeechConfig_RoundTripAndSparse(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher
	user := mustCreateUser(t, q, "alice")

	// First write: full grok config with a key.
	up, err := svc.UpdateSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Kind: strPtr("grok"), Voice: strPtr("ara"), Speed: f64Ptr(1.1), ApiKey: strPtr("xai-secret"),
	}))
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	cfg := up.Msg.Config
	if cfg.Kind != "grok" || cfg.Voice != "ara" || cfg.Speed != 1.1 || !cfg.ApiKeySet {
		t.Errorf("after first write: %+v", cfg)
	}

	// The key must not be readable from the row.
	row, err := q.GetUserTTSConfig(context.Background(), user.ID)
	if err != nil {
		t.Fatalf("row: %v", err)
	}
	if strings.Contains(string(row.ApiKeyEncrypted), "xai-secret") {
		t.Error("api key stored in plaintext")
	}

	// Sparse update: change voice only; kind and key survive.
	up, err = svc.UpdateSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Voice: strPtr("rex"),
	}))
	if err != nil {
		t.Fatalf("sparse update: %v", err)
	}
	if up.Msg.Config.Kind != "grok" || up.Msg.Config.Voice != "rex" || !up.Msg.Config.ApiKeySet {
		t.Errorf("sparse update lost fields: %+v", up.Msg.Config)
	}

	// Clear the key with "".
	up, _ = svc.UpdateSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		ApiKey: strPtr(""),
	}))
	if up.Msg.Config.ApiKeySet {
		t.Error("empty api_key should clear")
	}

	// Unknown kind refused.
	_, err = svc.UpdateSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Kind: strPtr("shouting-into-the-void"),
	}))
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Errorf("unknown kind: want InvalidArgument, got %v", err)
	}
}

func TestUpdateSpeechConfig_ProviderRefOwnership(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")

	prov := mustCreateProvider(t, q, cipher, bob.ID, `{"api_key":"bob-key"}`)

	// Alice referencing Bob's provider: NotFound (no existence leak).
	_, err := svc.UpdateSpeechConfig(ctxAs(alice), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Kind: strPtr("grok"), ProviderRef: strPtr(prov.ID.String()),
	}))
	if connect.CodeOf(err) != connect.CodeNotFound {
		t.Errorf("cross-user provider_ref: want NotFound, got %v", err)
	}

	// Bob referencing his own works and echoes back.
	up, err := svc.UpdateSpeechConfig(ctxAs(bob), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Kind: strPtr("grok"), ProviderRef: strPtr(prov.ID.String()),
	}))
	if err != nil {
		t.Fatalf("own provider_ref: %v", err)
	}
	if up.Msg.Config.ProviderRef != prov.ID.String() {
		t.Errorf("provider_ref echo: %+v", up.Msg.Config)
	}
}

func TestBuildForUser_CredentialPathsAndTest(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher
	user := mustCreateUser(t, q, "alice")

	// A fake provider endpoint asserting the key arrived.
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_, _ = w.Write(make([]byte, 4800)) // 100ms of "audio"
	}))
	defer srv.Close()

	// Credential reuse: key lives on the chat provider row only.
	prov := mustCreateProvider(t, q, cipher, user.ID, `{"api_key":"shared-xai-key"}`)
	if _, err := svc.UpdateSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Kind: strPtr("grok"), BaseUrl: strPtr(srv.URL), ProviderRef: strPtr(prov.ID.String()),
	})); err != nil {
		t.Fatalf("update: %v", err)
	}

	// End-to-end through TestSpeechConfig: BuildForUser resolves the
	// referenced provider's key into the driver, which must present it
	// to the (fake) endpoint.
	resp, err := svc.TestSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.TestSpeechConfigRequest{}))
	if err != nil {
		t.Fatalf("TestSpeechConfig: %v", err)
	}
	if !resp.Msg.Ok {
		t.Fatalf("test should pass against fake endpoint: %s", resp.Msg.ErrorMessage)
	}
	if resp.Msg.AudioBytes != 4800 {
		t.Errorf("audio bytes: %d want 4800", resp.Msg.AudioBytes)
	}
	if gotAuth != "Bearer shared-xai-key" {
		t.Errorf("credential reuse failed: auth %q", gotAuth)
	}
}

func TestTestSpeechConfig_AppleLocalNoNetwork(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher
	user := mustCreateUser(t, q, "alice")
	resp, err := svc.TestSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.TestSpeechConfigRequest{}))
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if !resp.Msg.Ok || resp.Msg.AudioBytes != 0 {
		t.Errorf("apple_local test should be a no-op ok: %+v", resp.Msg)
	}
}

func TestListSpeechKinds(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher
	user := mustCreateUser(t, q, "alice")
	resp, err := svc.ListSpeechKinds(ctxAs(user), connect.NewRequest(&psmithv1.ListSpeechKindsRequest{}))
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	joined := strings.Join(resp.Msg.Kinds, ",")
	for _, want := range []string{KindAppleLocal, "grok", "openai-compatible"} {
		if !strings.Contains(joined, want) {
			t.Errorf("kinds missing %q: %v", want, resp.Msg.Kinds)
		}
	}
}

func TestDeleteSpeechConfig_BackToDefault(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher
	user := mustCreateUser(t, q, "alice")
	if _, err := svc.UpdateSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Kind: strPtr("openai-compatible"), Voice: strPtr("alloy"),
	})); err != nil {
		t.Fatalf("update: %v", err)
	}
	if _, err := svc.DeleteSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.DeleteSpeechConfigRequest{})); err != nil {
		t.Fatalf("delete: %v", err)
	}
	resp, _ := svc.GetSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.GetSpeechConfigRequest{}))
	if resp.Msg.Config.Kind != KindAppleLocal {
		t.Errorf("delete should restore the apple_local default, got %q", resp.Msg.Config.Kind)
	}
}

// Silence unused warnings for helpers used conditionally.
var _ = json.Marshal
