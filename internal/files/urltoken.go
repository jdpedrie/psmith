package files

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// SignedURLTTL is the lifetime of a freshly-minted signed URL.
// 5 minutes is the working compromise: long enough that scrolling
// away from a conversation and back doesn't leave the cached URL
// expired (URLSession's image cache is content-keyed by the full
// URL, so the previously-fetched bytes stop hitting cache once the
// URL changes), short enough that a leaked URL stops working
// quickly. 30s — the original value — was too short: any
// re-render >30s after the first mint produced a 404 from the
// `/files/{id}` handler and the user saw a broken-image glyph.
const SignedURLTTL = 5 * time.Minute

// signedTokenSeparator separates the payload fields inside a token.
// Pipe is fine — UUID strings don't contain it, and we base64-encode
// the whole token at the boundary so URL-safety isn't a concern.
const signedTokenSeparator = "|"

// SignToken builds a tamper-evident token authenticating
// (fileID, userID, expiresAt). Layout (before base64):
//
//	{fileID}|{userID}|{unix_seconds}|{hex(hmac(prior bytes))}
//
// The HMAC covers everything before its delimiter so flipping any
// field invalidates the signature. Encoded with raw URL-safe base64
// (no padding) so the token round-trips cleanly through query
// strings.
func SignToken(key []byte, fileID, userID uuid.UUID, expiresAt time.Time) string {
	payload := strings.Join([]string{
		fileID.String(),
		userID.String(),
		strconv.FormatInt(expiresAt.Unix(), 10),
	}, signedTokenSeparator)
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(payload))
	sig := mac.Sum(nil)
	signed := payload + signedTokenSeparator + base64.RawURLEncoding.EncodeToString(sig)
	return base64.RawURLEncoding.EncodeToString([]byte(signed))
}

// VerifyToken parses + validates a token minted by SignToken. The
// returned fileID / userID are safe to use against the DB once
// VerifyToken returns nil. Expiry is checked against the passed
// `now` (caller supplies time.Now() — accepting it as a parameter
// keeps the function deterministic for tests).
//
// Errors are intentionally generic ("invalid token") — leaking
// "expired" vs "bad signature" to the caller would give attackers
// information about whether they guessed a valid token shape.
func VerifyToken(key []byte, token string, expectedFileID uuid.UUID, now time.Time) (uuid.UUID, error) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return uuid.Nil, errors.New("invalid token")
	}
	parts := strings.Split(string(raw), signedTokenSeparator)
	if len(parts) != 4 {
		return uuid.Nil, errors.New("invalid token")
	}
	fileIDStr, userIDStr, expiresStr, gotSigB64 := parts[0], parts[1], parts[2], parts[3]
	payload := strings.Join(parts[:3], signedTokenSeparator)

	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(payload))
	wantSig := mac.Sum(nil)
	gotSig, err := base64.RawURLEncoding.DecodeString(gotSigB64)
	if err != nil {
		return uuid.Nil, errors.New("invalid token")
	}
	if !hmac.Equal(wantSig, gotSig) {
		return uuid.Nil, errors.New("invalid token")
	}

	fileID, err := uuid.Parse(fileIDStr)
	if err != nil {
		return uuid.Nil, errors.New("invalid token")
	}
	if fileID != expectedFileID {
		return uuid.Nil, errors.New("invalid token")
	}
	userID, err := uuid.Parse(userIDStr)
	if err != nil {
		return uuid.Nil, errors.New("invalid token")
	}
	expiresUnix, err := strconv.ParseInt(expiresStr, 10, 64)
	if err != nil {
		return uuid.Nil, errors.New("invalid token")
	}
	if now.Unix() > expiresUnix {
		return uuid.Nil, errors.New("invalid token")
	}
	return userID, nil
}

// DeriveSigningKey turns the server's master key into a separate
// HMAC sub-key for URL signing. Same threat model — both keys live
// in process memory and rotate together via REEVE_MASTER_KEY — but
// using a derived sub-key keeps the master key out of the URL-
// signature pipeline so a key-pinning audit of either domain stays
// independent.
func DeriveSigningKey(masterKey []byte) []byte {
	mac := hmac.New(sha256.New, masterKey)
	_, _ = mac.Write([]byte("reeve.fileurl.v1"))
	return mac.Sum(nil)
}

