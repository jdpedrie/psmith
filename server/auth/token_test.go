package auth

import (
	"encoding/base64"
	"testing"
)

func TestGenerateToken_Length(t *testing.T) {
	raw, hash, err := generateToken()
	if err != nil {
		t.Fatalf("generateToken: %v", err)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("decode raw: %v", err)
	}
	if len(decoded) != tokenBytes {
		t.Errorf("decoded length %d want %d", len(decoded), tokenBytes)
	}
	if len(hash) != 64 {
		t.Errorf("hash length %d want 64 (sha256 hex)", len(hash))
	}
}

func TestGenerateToken_HashMatchesRaw(t *testing.T) {
	raw, hash, err := generateToken()
	if err != nil {
		t.Fatalf("generateToken: %v", err)
	}
	if hash != hashToken(raw) {
		t.Errorf("hash mismatch: returned %q, hashToken(raw) = %q", hash, hashToken(raw))
	}
}

func TestGenerateToken_Unique(t *testing.T) {
	seen := make(map[string]struct{}, 100)
	for i := range 100 {
		raw, _, err := generateToken()
		if err != nil {
			t.Fatalf("generateToken: %v", err)
		}
		if _, dup := seen[raw]; dup {
			t.Fatalf("collision at iter %d: %s", i, raw)
		}
		seen[raw] = struct{}{}
	}
}

func TestHashToken_Deterministic(t *testing.T) {
	if a, b := hashToken("abc"), hashToken("abc"); a != b {
		t.Errorf("not deterministic: %q vs %q", a, b)
	}
}

func TestHashToken_DifferentInputs(t *testing.T) {
	if a, b := hashToken("a"), hashToken("b"); a == b {
		t.Errorf("expected different hashes for different inputs, both %q", a)
	}
}
