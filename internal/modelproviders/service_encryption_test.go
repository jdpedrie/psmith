package modelproviders

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// realCipher mints an AES-256-GCM cipher with a per-test key so each
// run is independent. The key is discarded when the test exits — these
// are pgtestdb-backed and the database is too.
func realCipher(t *testing.T) crypto.Cipher {
	t.Helper()
	k := make([]byte, crypto.KeySize)
	if _, err := rand.Read(k); err != nil {
		t.Fatalf("rand: %v", err)
	}
	c, err := crypto.NewAESGCM(k)
	if err != nil {
		t.Fatalf("NewAESGCM: %v", err)
	}
	return c
}

// newEncryptedTestService wires the modelproviders Service with a real
// AES cipher so we can verify ciphertext lands in the DB and the read
// path successfully decrypts it.
func newEncryptedTestService(t *testing.T) (*Service, *store.Queries, crypto.Cipher) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cipher := realCipher(t)
	return NewService(q, modelmeta.NewLiveCatalog(nil), cipher, nil), q, cipher
}

// TestEncryption_CreateProviderRoundTripsThroughCiphertext is the
// load-bearing assertion for at-rest encryption: bytes in the
// `config_encrypted` column must NOT match the plaintext config the
// caller submitted, but the read path must return the original
// plaintext after decryption.
func TestEncryption_CreateProviderRoundTripsThroughCiphertext(t *testing.T) {
	svc, q, _ := newEncryptedTestService(t)
	user := mustUser(t, q, "alice", false)
	ctx := ctxAs(user)

	plaintext := []byte(`{"api_key":"sk-the-very-real-key","base_url":"https://api.example.com"}`)
	resp, err := svc.CreateUserModelProvider(ctx, connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:   "openai-compatible",
		Label:  "test",
		Config: plaintext,
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}

	// Read the row directly out of the DB (no service-layer
	// decryption) and prove the at-rest bytes are NOT the plaintext.
	row, err := q.ListUserModelProvidersByUser(ctx, user.ID)
	if err != nil {
		t.Fatalf("ListUserModelProvidersByUser: %v", err)
	}
	if len(row) != 1 {
		t.Fatalf("expected 1 row, got %d", len(row))
	}
	stored := row[0]
	if stored.Config != nil {
		t.Errorf("legacy plaintext column should be NULL on create, got %d bytes", len(stored.Config))
	}
	if stored.ConfigEncrypted == nil {
		t.Fatal("config_encrypted column is NULL — encryption didn't happen")
	}
	if bytes.Contains(stored.ConfigEncrypted, []byte("sk-the-very-real-key")) {
		t.Error("plaintext api_key visible in config_encrypted bytes — cipher not actually encrypting")
	}
	if bytes.Equal(stored.ConfigEncrypted, plaintext) {
		t.Error("config_encrypted bytes equal plaintext — cipher is a passthrough?")
	}

	// Read back through the service — should round-trip to the
	// original plaintext (api_key included; the proto Config field
	// surfaces the decrypted blob).
	got, err := svc.GetUserModelProvider(ctx, connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: resp.Msg.Provider.Id,
	}))
	if err != nil {
		t.Fatalf("GetUserModelProvider: %v", err)
	}
	if !bytesIsJSONEqual(t, got.Msg.Provider.Config, plaintext) {
		t.Errorf("round-tripped config differs from input:\n  in  = %s\n  out = %s", plaintext, got.Msg.Provider.Config)
	}
}

// TestEncryption_LegacyPlaintextRowReadsBack covers the rollover
// fallback: a row whose config sits in the old plaintext column (no
// encrypted twin yet) must still be readable via the resolveProviderConfig
// path. Simulates a database that hasn't been touched by the new code
// since the encryption rollout.
func TestEncryption_LegacyPlaintextRowReadsBack(t *testing.T) {
	svc, q, _ := newEncryptedTestService(t)
	pool := testutil.Pool(t)
	user := mustUser(t, q, "alice", false)
	ctx := ctxAs(user)

	// Create through the service (lands encrypted), then move bytes
	// sideways into the legacy plaintext column so the fallback path
	// is what gets exercised on read.
	resp, err := svc.CreateUserModelProvider(ctx, connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:   "openai-compatible",
		Label:  "legacy",
		Config: []byte(`{"api_key":"sk-legacy","base_url":"https://legacy.example.com"}`),
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	provID, err := uuid.Parse(resp.Msg.Provider.Id)
	if err != nil {
		t.Fatalf("parse id: %v", err)
	}
	if _, err := pool.Exec(ctx, `UPDATE user_model_providers SET config = $1, config_encrypted = NULL WHERE id = $2`,
		[]byte(`{"api_key":"sk-legacy","base_url":"https://legacy.example.com"}`), provID); err != nil {
		t.Fatalf("rewire to legacy plaintext: %v", err)
	}

	got, err := svc.GetUserModelProvider(ctx, connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: resp.Msg.Provider.Id,
	}))
	if err != nil {
		t.Fatalf("GetUserModelProvider: %v", err)
	}
	if !bytesIsJSONEqual(t, got.Msg.Provider.Config, []byte(`{"api_key":"sk-legacy","base_url":"https://legacy.example.com"}`)) {
		t.Errorf("legacy plaintext fallback returned wrong bytes: %s", got.Msg.Provider.Config)
	}
}

// TestEncryption_UpdateMergesAndRotatesToEncrypted verifies the JSON
// merge happens in plaintext and the result is re-encrypted before
// landing in the DB. Catches the regression where a partial Update
// (only base_url) loses the existing api_key because the SQL-side
// JSONB merge isn't there anymore.
func TestEncryption_UpdateMergesAndRotatesToEncrypted(t *testing.T) {
	svc, q, _ := newEncryptedTestService(t)
	user := mustUser(t, q, "alice", false)
	ctx := ctxAs(user)

	// Create with both fields.
	resp, err := svc.CreateUserModelProvider(ctx, connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:   "openai-compatible",
		Label:  "test",
		Config: []byte(`{"api_key":"sk-original","base_url":"https://orig.example.com"}`),
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}

	// Update only base_url — api_key must survive the merge.
	if _, err := svc.UpdateUserModelProvider(ctx, connect.NewRequest(&reevev1.UpdateUserModelProviderRequest{
		Id:     resp.Msg.Provider.Id,
		Config: []byte(`{"base_url":"https://new.example.com"}`),
	})); err != nil {
		t.Fatalf("UpdateUserModelProvider: %v", err)
	}

	// Read back, prove both fields landed.
	got, err := svc.GetUserModelProvider(ctx, connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: resp.Msg.Provider.Id,
	}))
	if err != nil {
		t.Fatalf("GetUserModelProvider: %v", err)
	}
	var merged map[string]string
	if err := json.Unmarshal(got.Msg.Provider.Config, &merged); err != nil {
		t.Fatalf("unmarshal merged: %v", err)
	}
	if merged["api_key"] != "sk-original" {
		t.Errorf("api_key lost in merge: %q", merged["api_key"])
	}
	if merged["base_url"] != "https://new.example.com" {
		t.Errorf("base_url did not update: %q", merged["base_url"])
	}
}

// bytesIsJSONEqual treats two byte slices as equal when they decode
// to the same JSON object — order-insensitive. The merge re-marshal
// path doesn't preserve key order, and we don't care.
func bytesIsJSONEqual(t *testing.T, a, b []byte) bool {
	t.Helper()
	var ma, mb map[string]any
	if err := json.Unmarshal(a, &ma); err != nil {
		t.Fatalf("unmarshal a: %v", err)
	}
	if err := json.Unmarshal(b, &mb); err != nil {
		t.Fatalf("unmarshal b: %v", err)
	}
	if len(ma) != len(mb) {
		return false
	}
	for k, v := range ma {
		if mb[k] != v {
			return false
		}
	}
	return true
}
