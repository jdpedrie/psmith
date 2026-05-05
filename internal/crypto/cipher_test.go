package crypto

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func mustKey(t *testing.T) []byte {
	t.Helper()
	k := make([]byte, KeySize)
	if _, err := rand.Read(k); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return k
}

func mustCipher(t *testing.T) *AESGCM {
	t.Helper()
	c, err := NewAESGCM(mustKey(t))
	if err != nil {
		t.Fatalf("NewAESGCM: %v", err)
	}
	return c
}

func TestAESGCM_Roundtrip(t *testing.T) {
	c := mustCipher(t)
	for _, tc := range []struct {
		name string
		in   []byte
	}{
		{"empty bytes", []byte{}},
		{"short", []byte("hi")},
		{"json blob", []byte(`{"api_key":"sk-abc-123","base_url":"https://api.example.com"}`)},
		{"large", bytes.Repeat([]byte("x"), 64*1024)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ct, err := c.Encrypt(tc.in)
			if err != nil {
				t.Fatalf("Encrypt: %v", err)
			}
			pt, err := c.Decrypt(ct)
			if err != nil {
				t.Fatalf("Decrypt: %v", err)
			}
			if !bytes.Equal(pt, tc.in) {
				t.Fatalf("roundtrip mismatch:\n  in  = %q\n  out = %q", tc.in, pt)
			}
		})
	}
}

func TestAESGCM_NilPassthrough(t *testing.T) {
	c := mustCipher(t)
	ct, err := c.Encrypt(nil)
	if err != nil || ct != nil {
		t.Fatalf("nil Encrypt: got (%v, %v), want (nil, nil)", ct, err)
	}
	pt, err := c.Decrypt(nil)
	if err != nil || pt != nil {
		t.Fatalf("nil Decrypt: got (%v, %v), want (nil, nil)", pt, err)
	}
}

func TestAESGCM_NonceVariesPerCall(t *testing.T) {
	c := mustCipher(t)
	a, err := c.Encrypt([]byte("same plaintext"))
	if err != nil {
		t.Fatalf("Encrypt a: %v", err)
	}
	b, err := c.Encrypt([]byte("same plaintext"))
	if err != nil {
		t.Fatalf("Encrypt b: %v", err)
	}
	if bytes.Equal(a, b) {
		t.Fatal("two encryptions of same plaintext produced identical ciphertext — nonce isn't varying")
	}
}

func TestAESGCM_RejectsTampered(t *testing.T) {
	c := mustCipher(t)
	ct, err := c.Encrypt([]byte("authentic"))
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	// Flip a byte in the auth-tag region (last byte) — Open must fail.
	ct[len(ct)-1] ^= 0xff
	if _, err := c.Decrypt(ct); err == nil {
		t.Fatal("Decrypt accepted tampered ciphertext")
	}
}

func TestAESGCM_RejectsWrongKey(t *testing.T) {
	c1 := mustCipher(t)
	c2 := mustCipher(t)
	ct, err := c1.Encrypt([]byte("for c1 only"))
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if _, err := c2.Decrypt(ct); err == nil {
		t.Fatal("Decrypt with wrong key succeeded — auth tag isn't gating")
	}
}

func TestAESGCM_RejectsTooShort(t *testing.T) {
	c := mustCipher(t)
	_, err := c.Decrypt([]byte{0x00, 0x01, 0x02})
	if !errors.Is(err, ErrInvalidCiphertext) {
		t.Fatalf("Decrypt(short) err = %v, want ErrInvalidCiphertext", err)
	}
}

func TestAESGCM_KeyLengthValidated(t *testing.T) {
	if _, err := NewAESGCM(make([]byte, 16)); err == nil {
		t.Fatal("NewAESGCM accepted 16-byte key")
	}
	if _, err := NewAESGCM(nil); err == nil {
		t.Fatal("NewAESGCM accepted nil key")
	}
}

func TestNop_Passthrough(t *testing.T) {
	in := []byte("anything")
	ct, _ := Nop{}.Encrypt(in)
	pt, _ := Nop{}.Decrypt(ct)
	if !bytes.Equal(pt, in) {
		t.Fatalf("Nop roundtrip lost data: got %q, want %q", pt, in)
	}
}

func TestLoadKey_FromEnv(t *testing.T) {
	t.Setenv(EnvKeyVar, base64.StdEncoding.EncodeToString(mustKey(t)))
	t.Setenv(EnvDevAutoKey, "")
	k, ephem, err := LoadKey()
	if err != nil {
		t.Fatalf("LoadKey: %v", err)
	}
	if len(k) != KeySize {
		t.Fatalf("len(k) = %d, want %d", len(k), KeySize)
	}
	if ephem {
		t.Fatal("env-key path returned ephemeral=true")
	}
}

func TestLoadKey_RejectsBadLength(t *testing.T) {
	t.Setenv(EnvKeyVar, base64.StdEncoding.EncodeToString([]byte("too short")))
	_, _, err := LoadKey()
	if err == nil {
		t.Fatal("LoadKey accepted short key")
	}
}

func TestLoadKey_RejectsBadBase64(t *testing.T) {
	t.Setenv(EnvKeyVar, "not base64 !!!")
	_, _, err := LoadKey()
	if err == nil {
		t.Fatal("LoadKey accepted invalid base64")
	}
}

func TestLoadKey_DevAutoKey(t *testing.T) {
	t.Setenv(EnvKeyVar, "")
	t.Setenv(EnvDevAutoKey, "1")
	k, ephem, err := LoadKey()
	if err != nil {
		t.Fatalf("LoadKey: %v", err)
	}
	if !ephem {
		t.Fatal("dev-auto path did not flag ephemeral")
	}
	if len(k) != KeySize {
		t.Fatalf("len(k) = %d, want %d", len(k), KeySize)
	}
}

func TestLoadKey_NoConfigReturnsNil(t *testing.T) {
	t.Setenv(EnvKeyVar, "")
	t.Setenv(EnvDevAutoKey, "")
	k, ephem, err := LoadKey()
	if err != nil {
		t.Fatalf("LoadKey: %v", err)
	}
	if k != nil || ephem {
		t.Fatalf("expected (nil, false, nil); got (%v, %v)", k, ephem)
	}
}

func TestGenerateKeyB64(t *testing.T) {
	got, err := GenerateKeyB64()
	if err != nil {
		t.Fatalf("GenerateKeyB64: %v", err)
	}
	raw, err := base64.StdEncoding.DecodeString(got)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(raw) != KeySize {
		t.Fatalf("len = %d, want %d", len(raw), KeySize)
	}
}

func TestSecret_StringIsRedacted(t *testing.T) {
	s := Secret([]byte("sk-very-sensitive-token"))
	if got := s.String(); got != "[REDACTED]" {
		t.Fatalf("String() = %q, want [REDACTED]", got)
	}
}

func TestSecret_FmtVerbsAllRedact(t *testing.T) {
	s := Secret([]byte("sk-very-sensitive-token"))
	for _, verb := range []string{"%s", "%v", "%+v", "%#v", "%q"} {
		got := fmt.Sprintf(verb, s)
		if strings.Contains(got, "sensitive") {
			t.Errorf("%s leaked secret: %q", verb, got)
		}
	}
}

func TestSecret_JSONMarshalRedacts(t *testing.T) {
	s := Secret([]byte("sk-leaky"))
	b, err := s.MarshalJSON()
	if err != nil {
		t.Fatalf("MarshalJSON: %v", err)
	}
	if string(b) != `"[REDACTED]"` {
		t.Fatalf("MarshalJSON = %s, want \"[REDACTED]\"", b)
	}
}

func TestSecret_RevealReturnsActualValue(t *testing.T) {
	want := []byte("sk-actual-value")
	s := Secret(want)
	if !bytes.Equal(s.Reveal(), want) {
		t.Fatalf("Reveal() = %q, want %q", s.Reveal(), want)
	}
	if s.RevealString() != string(want) {
		t.Fatalf("RevealString() = %q, want %q", s.RevealString(), want)
	}
}

func TestSecret_IsZero(t *testing.T) {
	if !(Secret(nil)).IsZero() {
		t.Error("nil Secret should report IsZero")
	}
	if !(Secret([]byte{})).IsZero() {
		t.Error("empty Secret should report IsZero")
	}
	if (Secret([]byte("x"))).IsZero() {
		t.Error("non-empty Secret should not report IsZero")
	}
}

// TestSecret_StructEmbedDoesNotLeak guards against a regression where
// %+v on a struct embedding Secret leaks the underlying bytes by
// circumventing Format. The Format method must catch the printer
// before the default reflection-based path engages.
func TestSecret_StructEmbedDoesNotLeak(t *testing.T) {
	type cfg struct {
		APIKey Secret
		Host   string
	}
	c := cfg{APIKey: Secret([]byte("sk-leak-me-please")), Host: "example.com"}
	for _, verb := range []string{"%v", "%+v", "%#v"} {
		got := fmt.Sprintf(verb, c)
		if strings.Contains(got, "sk-leak-me-please") {
			t.Errorf("%s leaked secret in struct embed: %q", verb, got)
		}
	}
}
