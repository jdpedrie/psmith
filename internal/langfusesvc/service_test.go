package langfusesvc

import (
	"context"
	"crypto/rand"
	"log/slog"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/encoding/protojson"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/langfuse"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// TestUpdate_StoresSecretEncryptedInDB is the load-bearing one. Confirms
// that an Update which sets secret_key writes the AES-GCM ciphertext
// (not the plaintext) into user_langfuse_config.secret_key_encrypted.
// Anyone reading the row directly with psql must see opaque bytes.
func TestUpdate_StoresSecretEncryptedInDB(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)

	// Real cipher (not Nop) so encryption is genuine.
	key := make([]byte, crypto.KeySize)
	if _, err := rand.Read(key); err != nil {
		t.Fatalf("rand: %v", err)
	}
	cipher, err := crypto.NewAESGCM(key)
	if err != nil {
		t.Fatalf("NewAESGCM: %v", err)
	}

	emitter := langfuse.NewEmitter(slog.Default(), langfuse.EmitterConfig{})
	defer emitter.Stop(context.Background())

	svc := NewService(q, cipher, emitter, slog.Default())
	user := mustUser(t, q)

	plaintextSecret := "lf-sk-totally-secret-12345"
	host := "https://my.langfuse.example"
	pubKey := "lf-pk-public"
	enabled := true

	_, err = svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&reevev1.UpdateLangfuseConfigRequest{
		Host:      &host,
		PublicKey: &pubKey,
		SecretKey: &plaintextSecret,
		Enabled:   &enabled,
	}))
	if err != nil {
		t.Fatalf("UpdateLangfuseConfig: %v", err)
	}

	// Read the row back via a direct DB query and confirm:
	//   - secret_key_encrypted is non-nil and NOT the literal plaintext
	//   - decrypting it through the cipher yields the original plaintext
	row, err := q.GetUserLangfuseConfig(context.Background(), user.ID)
	if err != nil {
		t.Fatalf("GetUserLangfuseConfig: %v", err)
	}
	if row.SecretKeyEncrypted == nil {
		t.Fatal("secret_key_encrypted is nil; expected ciphertext bytes")
	}
	if string(row.SecretKeyEncrypted) == plaintextSecret {
		t.Fatalf("secret_key_encrypted contains plaintext! bytes=%q", row.SecretKeyEncrypted)
	}
	if strings.Contains(string(row.SecretKeyEncrypted), plaintextSecret) {
		t.Fatalf("secret_key_encrypted contains the plaintext string substring! bytes=%q", row.SecretKeyEncrypted)
	}
	plain, err := cipher.Decrypt(row.SecretKeyEncrypted)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if string(plain) != plaintextSecret {
		t.Errorf("round-trip secret = %q, want %q", plain, plaintextSecret)
	}
}

// TestGet_NeverEchoesSecret asserts the response wire shape contains
// no plaintext secret material. Defends the shape of LangfuseConfig
// against future drift (e.g. someone adding a `secret_key` field
// because "the user might want to see it").
func TestGet_NeverEchoesSecret(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cipher := crypto.Nop{}
	svc := NewService(q, cipher, nil, slog.Default())
	user := mustUser(t, q)

	plaintext := "extremely-secret-key"
	host := "https://x"
	pub := "pk"
	enabled := true
	if _, err := svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&reevev1.UpdateLangfuseConfigRequest{
		Host: &host, PublicKey: &pub, SecretKey: &plaintext, Enabled: &enabled,
	})); err != nil {
		t.Fatalf("Update: %v", err)
	}

	resp, err := svc.GetLangfuseConfig(ctxAsUser(user), connect.NewRequest(&reevev1.GetLangfuseConfigRequest{}))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	cfg := resp.Msg.Config
	if !cfg.HasSecretKey {
		t.Error("HasSecretKey = false after setting a secret")
	}
	// Hard guard: serialise the response and grep the bytes for any
	// trace of the plaintext.
	body, err := protojson.Marshal(resp.Msg)
	if err != nil {
		t.Fatalf("protojson.Marshal: %v", err)
	}
	if strings.Contains(string(body), plaintext) {
		t.Errorf("Get response body leaked plaintext secret: %s", body)
	}
}

// TestUpdate_NilSecretKeyKeepsExisting covers the "edit other fields
// without touching the secret" flow — clients send secret_key=nil and
// the encrypted column must survive untouched. This is the path the
// settings UI takes when toggling enabled or changing the host.
func TestUpdate_NilSecretKeyKeepsExisting(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	key := make([]byte, crypto.KeySize)
	_, _ = rand.Read(key)
	cipher, _ := crypto.NewAESGCM(key)
	svc := NewService(q, cipher, nil, slog.Default())
	user := mustUser(t, q)

	original := "my-original-secret"
	host := "https://h"
	pub := "pk"
	enabled := true
	if _, err := svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&reevev1.UpdateLangfuseConfigRequest{
		Host: &host, PublicKey: &pub, SecretKey: &original, Enabled: &enabled,
	})); err != nil {
		t.Fatalf("Update(initial): %v", err)
	}
	row1, _ := q.GetUserLangfuseConfig(context.Background(), user.ID)
	enc1 := append([]byte(nil), row1.SecretKeyEncrypted...)

	// Second Update with secret_key=nil (just toggle enabled off).
	disabled := false
	if _, err := svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&reevev1.UpdateLangfuseConfigRequest{
		Enabled: &disabled,
	})); err != nil {
		t.Fatalf("Update(toggle): %v", err)
	}
	row2, _ := q.GetUserLangfuseConfig(context.Background(), user.ID)
	if string(row2.SecretKeyEncrypted) != string(enc1) {
		t.Errorf("secret_key_encrypted changed when nil was passed: was %q, now %q", enc1, row2.SecretKeyEncrypted)
	}
	plain, _ := cipher.Decrypt(row2.SecretKeyEncrypted)
	if string(plain) != original {
		t.Errorf("round-trip after nil-secret update = %q, want %q", plain, original)
	}
}

// TestUpdate_EmptySecretKeyClears confirms the third secret_key state:
// passing "" explicitly clears the column.
func TestUpdate_EmptySecretKeyClears(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	key := make([]byte, crypto.KeySize)
	_, _ = rand.Read(key)
	cipher, _ := crypto.NewAESGCM(key)
	svc := NewService(q, cipher, nil, slog.Default())
	user := mustUser(t, q)

	original := "to-be-cleared"
	host := "https://h"
	pub := "pk"
	yes := true
	if _, err := svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&reevev1.UpdateLangfuseConfigRequest{
		Host: &host, PublicKey: &pub, SecretKey: &original, Enabled: &yes,
	})); err != nil {
		t.Fatalf("Update(initial): %v", err)
	}

	// Clear via empty string + must also disable (server rejects
	// enabled=true without a key).
	empty := ""
	no := false
	if _, err := svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&reevev1.UpdateLangfuseConfigRequest{
		SecretKey: &empty, Enabled: &no,
	})); err != nil {
		t.Fatalf("Update(clear): %v", err)
	}
	row, _ := q.GetUserLangfuseConfig(context.Background(), user.ID)
	if row.SecretKeyEncrypted != nil {
		t.Errorf("secret_key_encrypted = %q, want nil after explicit clear", row.SecretKeyEncrypted)
	}
}

// TestUpdate_EnabledRequiresFullCredentials guards the UI-readable
// invariant: enabled=true is only allowed when both public_key and
// secret_key_encrypted are present. Without the guard, the toggle
// would save successfully but the emitter would silently drop every
// event — surprising "saved → nothing happens" UX.
func TestUpdate_EnabledRequiresFullCredentials(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cipher := crypto.Nop{}
	svc := NewService(q, cipher, nil, slog.Default())
	user := mustUser(t, q)

	// Try to enable with no credentials.
	host := "https://h"
	yes := true
	_, err := svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&reevev1.UpdateLangfuseConfigRequest{
		Host: &host, Enabled: &yes,
	}))
	if err == nil {
		t.Fatal("expected FailedPrecondition when enabling without credentials")
	}
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Errorf("got code %s, want FailedPrecondition", connect.CodeOf(err))
	}
}

// --- helpers ---

func mustUser(t *testing.T, q *store.Queries) store.User {
	t.Helper()
	id := uuid.New()
	u, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID:           id,
		Username:     "user-" + id.String()[:8],
		PasswordHash: "test-hash",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	return u
}

func ctxAsUser(u store.User) context.Context {
	return auth.ContextWithUser(context.Background(), auth.User{
		ID: u.ID, Username: u.Username, IsAdmin: u.IsAdmin,
		CreatedAt: u.CreatedAt, UpdatedAt: u.UpdatedAt,
	})
}
