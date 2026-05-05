// Package crypto wraps the (deliberately small) set of symmetric
// primitives Reeve uses to encrypt secrets at rest — provider API
// keys, plugin credentials, anything that lives in a `*.config` JSONB
// column today. The package is intentionally narrow: AES-256-GCM with
// a single master key, no per-row key derivation, no envelope wrapping.
// Tier B (per-user keys derived from the password) is sketched in
// docs/architecture.md and is the next step if the threat model grows
// past "operator with logical DB access shouldn't see plaintext".
//
// See docs/architecture.md "Encryption" for the full threat-model
// rationale and the decision to defer encrypting message bodies.
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
)

// KeySize is the AES-256-GCM key length. The master key MUST be exactly
// this many bytes; LoadKey enforces it.
const KeySize = 32

// EnvKeyVar names the environment variable that must hold the
// base64-encoded 32-byte master key in production. Naming kept short
// so deploy configs read cleanly.
const EnvKeyVar = "REEVE_MASTER_KEY"

// EnvDevAutoKey names the environment variable that, when set to "1",
// allows LoadKey to mint a one-shot ephemeral key on the fly. ONLY for
// local dev — every restart generates a fresh key, so any data
// encrypted under the previous key becomes unreadable. The server logs
// a loud warning when this branch fires.
const EnvDevAutoKey = "REEVE_DEV_AUTOKEY"

// Cipher is the abstraction services depend on for "give me back the
// encrypted form / give me back the plaintext form". Two production
// implementations exist:
//
//   - AESGCM: real encryption keyed by a 32-byte master key.
//   - Nop: passthrough (Encrypt and Decrypt return their input unchanged).
//     Used in tests and as the fallback when no master key is configured
//     and the deployment opts into running without encryption.
type Cipher interface {
	Encrypt(plaintext []byte) ([]byte, error)
	Decrypt(ciphertext []byte) ([]byte, error)
}

// AESGCM is the production cipher — AES-256-GCM with a randomly
// generated 12-byte nonce prepended to the ciphertext. Layout:
//
//	[ nonce 12B ][ ciphertext + tag (variable) ]
//
// GCM's 16-byte authentication tag is appended by the Seal call and
// included in the ciphertext segment. Decrypt slices off the nonce
// and lets Open authenticate the rest.
type AESGCM struct {
	aead cipher.AEAD
}

// NewAESGCM returns an AESGCM bound to key. Key MUST be exactly KeySize
// bytes; anything else is a programmer error and returns the underlying
// crypto/cipher error verbatim.
func NewAESGCM(key []byte) (*AESGCM, error) {
	if len(key) != KeySize {
		return nil, fmt.Errorf("crypto: key must be %d bytes, got %d", KeySize, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("crypto: aes.NewCipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("crypto: cipher.NewGCM: %w", err)
	}
	return &AESGCM{aead: aead}, nil
}

// Encrypt returns nonce ‖ Seal(plaintext). Nil plaintext maps to nil
// output so callers can safely encrypt "absent" values without
// special-casing.
func (c *AESGCM) Encrypt(plaintext []byte) ([]byte, error) {
	if plaintext == nil {
		return nil, nil
	}
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("crypto: read nonce: %w", err)
	}
	// Seal appends the ciphertext + auth tag to the destination slice.
	// Pass nonce as the destination so the output is laid out as
	// [nonce][ciphertext+tag] in one allocation.
	return c.aead.Seal(nonce, nonce, plaintext, nil), nil
}

// Decrypt reverses Encrypt. Nil input maps to nil output. Returns
// ErrInvalidCiphertext for anything shorter than nonce + tag (which is
// definitively not something we produced) and the verbatim Open error
// for authentication failures (wrong key, tampered payload).
func (c *AESGCM) Decrypt(ciphertext []byte) ([]byte, error) {
	if ciphertext == nil {
		return nil, nil
	}
	ns := c.aead.NonceSize()
	if len(ciphertext) < ns+c.aead.Overhead() {
		return nil, ErrInvalidCiphertext
	}
	nonce, payload := ciphertext[:ns], ciphertext[ns:]
	plain, err := c.aead.Open(nil, nonce, payload, nil)
	if err != nil {
		return nil, fmt.Errorf("crypto: decrypt: %w", err)
	}
	return plain, nil
}

// Nop is the passthrough Cipher used in tests and for deployments that
// opt out of encryption (no master key configured, no auto-key flag).
// Insert/Update flow writes the same bytes that come in, Read flow
// reads them back unchanged. Coexists with the AESGCM cipher via the
// dual-column read path: a row encrypted by AESGCM will fail to
// "decrypt" through Nop and the service falls back to the plaintext
// column.
type Nop struct{}

func (Nop) Encrypt(plaintext []byte) ([]byte, error)  { return plaintext, nil }
func (Nop) Decrypt(ciphertext []byte) ([]byte, error) { return ciphertext, nil }

// ErrInvalidCiphertext is returned for any byte slice the AESGCM
// cipher knows it didn't produce (too short to contain the
// nonce+tag). Callers that need to distinguish "I have no encrypted
// blob" from "I have a malformed one" can use errors.Is.
var ErrInvalidCiphertext = errors.New("crypto: ciphertext too short")

// LoadKey reads the master key from the environment per the policy
// described on EnvKeyVar / EnvDevAutoKey. Returns the raw 32-byte key
// (caller passes to NewAESGCM) plus an `ephemeral` flag — true when
// the key was minted by the dev-auto path so the server can log a
// loud warning that data won't survive a restart.
//
// Resolution order:
//
//  1. REEVE_MASTER_KEY set → base64-decode, validate length, return.
//  2. REEVE_DEV_AUTOKEY=1 → mint a fresh 32 bytes, return ephemeral=true.
//  3. Otherwise → return (nil, false, nil). Caller decides whether to
//     proceed with the Nop cipher or refuse to start.
func LoadKey() (key []byte, ephemeral bool, err error) {
	if v := os.Getenv(EnvKeyVar); v != "" {
		raw, err := base64.StdEncoding.DecodeString(v)
		if err != nil {
			return nil, false, fmt.Errorf("crypto: %s is not valid base64: %w", EnvKeyVar, err)
		}
		if len(raw) != KeySize {
			return nil, false, fmt.Errorf("crypto: %s decoded to %d bytes, want %d", EnvKeyVar, len(raw), KeySize)
		}
		return raw, false, nil
	}
	if os.Getenv(EnvDevAutoKey) == "1" {
		raw := make([]byte, KeySize)
		if _, err := rand.Read(raw); err != nil {
			return nil, false, fmt.Errorf("crypto: dev-auto key generation: %w", err)
		}
		return raw, true, nil
	}
	return nil, false, nil
}

// GenerateKeyB64 mints a fresh 32-byte master key and returns it as
// base64 — the format REEVE_MASTER_KEY expects. Used by `reeve genkey`
// and by tests that need a real key without going through env-var
// indirection.
func GenerateKeyB64() (string, error) {
	raw := make([]byte, KeySize)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}

// ResolveSecret returns the plaintext bytes for a row that may be in
// the middle of the encrypted-column rollover.
//
// If `encrypted` is non-nil, decrypt it through the cipher and return.
// If `encrypted` is nil, fall back to the `plaintext` column verbatim
// (a legacy row that hasn't been re-saved since the encryption
// rollout). When both are nil, returns nil — the caller decides what
// "no config" means.
//
// Callers: any service reading a `*.config` JSONB column. After every
// row in the relevant table has been touched at least once post-
// rollout, the plaintext fallback becomes dead code and a follow-up
// migration drops the legacy column.
func ResolveSecret(cipher Cipher, encrypted, plaintext []byte) ([]byte, error) {
	if encrypted != nil {
		return cipher.Decrypt(encrypted)
	}
	return plaintext, nil
}
