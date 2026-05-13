package storage

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"

	"github.com/google/uuid"
)

func TestFS_PutGet_Roundtrip(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	fs, err := NewFS(root)
	if err != nil {
		t.Fatalf("NewFS: %v", err)
	}
	uid := uuid.New()
	payload := []byte("hello world")
	const sha = "deadbeefcafe"
	ctx := context.Background()

	if err := fs.Put(ctx, uid, sha, "text/plain", bytes.NewReader(payload)); err != nil {
		t.Fatalf("Put: %v", err)
	}

	rc, err := fs.Get(ctx, uid, sha)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	defer rc.Close()
	got, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("payload mismatch: got %q want %q", got, payload)
	}
}

func TestFS_Put_IsIdempotent(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	fs, _ := NewFS(root)
	uid := uuid.New()
	const sha = "abc123"
	ctx := context.Background()
	if err := fs.Put(ctx, uid, sha, "text/plain", bytes.NewReader([]byte("v1"))); err != nil {
		t.Fatalf("first Put: %v", err)
	}
	// Second Put with identical sha is a no-op — the existing bytes
	// are preserved (content-addressed storage trusts the addressing).
	if err := fs.Put(ctx, uid, sha, "text/plain", bytes.NewReader([]byte("v2"))); err != nil {
		t.Fatalf("second Put: %v", err)
	}
	rc, _ := fs.Get(ctx, uid, sha)
	defer rc.Close()
	got, _ := io.ReadAll(rc)
	if string(got) != "v1" {
		t.Errorf("expected v1 (idempotent skip), got %q", got)
	}
}

func TestFS_Get_NotFound(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	fs, _ := NewFS(root)
	_, err := fs.Get(context.Background(), uuid.New(), "nope")
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestFS_Delete_IdempotentOnMissing(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	fs, _ := NewFS(root)
	if err := fs.Delete(context.Background(), uuid.New(), "missing"); err != nil {
		t.Errorf("expected nil on missing object, got %v", err)
	}
}

func TestFS_PutGet_PerUserIsolation(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	fs, _ := NewFS(root)
	u1, u2 := uuid.New(), uuid.New()
	const sha = "shared"
	ctx := context.Background()
	if err := fs.Put(ctx, u1, sha, "text/plain", bytes.NewReader([]byte("u1-bytes"))); err != nil {
		t.Fatalf("Put u1: %v", err)
	}
	// u2's Get must NOT see u1's bytes, even with the same sha.
	if _, err := fs.Get(ctx, u2, sha); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound for u2/sha owned by u1, got %v", err)
	}
}
