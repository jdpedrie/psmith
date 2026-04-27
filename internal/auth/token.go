package auth

import (
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
)

const tokenBytes = 32

// generateToken returns a fresh raw token and its sha256 hex hash.
// The raw token is shown to the user exactly once at login; only the hash is stored.
func generateToken() (raw string, hash string, err error) {
	b := make([]byte, tokenBytes)
	if _, err := crand.Read(b); err != nil {
		return "", "", err
	}
	raw = base64.RawURLEncoding.EncodeToString(b)
	hash = hashToken(raw)
	return raw, hash, nil
}

func hashToken(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}
