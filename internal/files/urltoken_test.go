package files

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSignVerify_Roundtrip(t *testing.T) {
	t.Parallel()
	key := []byte("test-key-bytes-1234567890abcdef0")
	fileID := uuid.New()
	userID := uuid.New()
	expires := time.Now().Add(30 * time.Second)
	tok := SignToken(key, fileID, userID, expires)
	gotUser, err := VerifyToken(key, tok, fileID, time.Now())
	if err != nil {
		t.Fatalf("VerifyToken: %v", err)
	}
	if gotUser != userID {
		t.Errorf("user mismatch: got %v want %v", gotUser, userID)
	}
}

func TestVerify_RejectsExpired(t *testing.T) {
	t.Parallel()
	key := []byte("k")
	fileID := uuid.New()
	expires := time.Now().Add(-1 * time.Second) // already expired
	tok := SignToken(key, fileID, uuid.New(), expires)
	_, err := VerifyToken(key, tok, fileID, time.Now())
	if err == nil {
		t.Fatal("expected expiry rejection, got nil")
	}
}

func TestVerify_RejectsWrongFileID(t *testing.T) {
	t.Parallel()
	key := []byte("k")
	signedFile := uuid.New()
	otherFile := uuid.New()
	tok := SignToken(key, signedFile, uuid.New(), time.Now().Add(30*time.Second))
	_, err := VerifyToken(key, tok, otherFile, time.Now())
	if err == nil {
		t.Fatal("expected mismatched fileID rejection, got nil")
	}
}

func TestVerify_RejectsTampered(t *testing.T) {
	t.Parallel()
	key := []byte("k")
	fileID := uuid.New()
	tok := SignToken(key, fileID, uuid.New(), time.Now().Add(30*time.Second))
	// Flip a character in the middle of the token. Any bit-flip
	// invalidates the HMAC.
	mid := len(tok) / 2
	tampered := tok[:mid] + flipOne(tok[mid:mid+1]) + tok[mid+1:]
	if tampered == tok {
		t.Fatal("flip produced identical token; pick a different index")
	}
	_, err := VerifyToken(key, tampered, fileID, time.Now())
	if err == nil {
		t.Fatal("expected tampered-token rejection, got nil")
	}
}

func TestVerify_RejectsWrongKey(t *testing.T) {
	t.Parallel()
	fileID := uuid.New()
	tok := SignToken([]byte("k1"), fileID, uuid.New(), time.Now().Add(30*time.Second))
	_, err := VerifyToken([]byte("k2"), tok, fileID, time.Now())
	if err == nil {
		t.Fatal("expected wrong-key rejection, got nil")
	}
}

func TestDeriveSigningKey_StableAndDistinct(t *testing.T) {
	t.Parallel()
	master := []byte("master-key-32-bytes-abcdef012345")
	a := DeriveSigningKey(master)
	b := DeriveSigningKey(master)
	if string(a) != string(b) {
		t.Errorf("derive isn't deterministic")
	}
	if string(a) == string(master) {
		t.Errorf("derived key should not equal master key")
	}
}

// flipOne flips a character to something else, preserving length.
// Used to test signature integrity — we want any single-char edit
// to invalidate the HMAC.
func flipOne(s string) string {
	if strings.HasPrefix(s, "A") {
		return "B"
	}
	return "A"
}
