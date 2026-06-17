package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/google/uuid"
)

// FS is the v1 filesystem-backed Storage. Layout:
//
//	$root/files/{user_id}/{sha256}
//
// Per-user dir at 0700 (only the spaltd process should list a user's
// uploads); files at 0600 (no peeking). Atomic writes via temp + rename
// so a crash mid-write never leaves a partial sha256-named file the
// next Put could mistake for "already present".
type FS struct {
	// root is the data directory under which `files/` is created on
	// first write. Resolved at construction time so callers see a
	// hard failure (rather than per-call surprises) if it's missing.
	root string
}

// NewFS builds a filesystem-backed Storage rooted at `dataDir`. The
// `files/` subdirectory is created at 0700 if missing. dataDir itself
// must already exist (the operator owns its provisioning); we don't
// MkdirAll the parent because doing so could write outside the
// intended root if dataDir is misconfigured.
func NewFS(dataDir string) (*FS, error) {
	if dataDir == "" {
		return nil, errors.New("storage/fs: dataDir is required")
	}
	info, err := os.Stat(dataDir)
	if err != nil {
		return nil, fmt.Errorf("storage/fs: stat dataDir %q: %w", dataDir, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("storage/fs: dataDir %q is not a directory", dataDir)
	}
	filesDir := filepath.Join(dataDir, "files")
	if err := os.MkdirAll(filesDir, 0o700); err != nil {
		return nil, fmt.Errorf("storage/fs: create files dir: %w", err)
	}
	return &FS{root: dataDir}, nil
}

// pathFor returns the on-disk path for (userID, sha256). Both
// components are validated at the type level (UUID, hex string)
// before they reach here, so no escaping is needed — but we still
// reject empty sha256 defensively because an empty path would
// resolve to the per-user directory itself.
func (f *FS) pathFor(userID uuid.UUID, sha256 string) (string, error) {
	if sha256 == "" {
		return "", errors.New("storage/fs: empty sha256")
	}
	return filepath.Join(f.root, "files", userID.String(), sha256), nil
}

// Put writes data to the content-addressed path. Atomic: bytes go to
// a temp file in the per-user dir, then rename(2) into place. A
// concurrent second Put for the same content can race the rename
// harmlessly — both temp files end up with the same bytes, the rename
// is idempotent. Idempotency: if the target already exists with
// the same bytes (presumably), we skip the rewrite to save IO.
func (f *FS) Put(ctx context.Context, userID uuid.UUID, sha256 string, _ string, data io.Reader) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	dst, err := f.pathFor(userID, sha256)
	if err != nil {
		return err
	}
	userDir := filepath.Dir(dst)
	if err := os.MkdirAll(userDir, 0o700); err != nil {
		return fmt.Errorf("storage/fs: mkdir user dir: %w", err)
	}
	// Skip if the final file is already present. Content-addressed
	// storage means same sha → same bytes; we trust the addressing.
	if _, err := os.Stat(dst); err == nil {
		// Drain the reader so the caller's stream isn't left partial —
		// upstream upload handlers expect to read-through to EOF.
		_, _ = io.Copy(io.Discard, data)
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("storage/fs: stat dst: %w", err)
	}
	tmp, err := os.CreateTemp(userDir, ".upload-*")
	if err != nil {
		return fmt.Errorf("storage/fs: create temp: %w", err)
	}
	// Best-effort cleanup of the tempfile on error paths. We only
	// reach the Remove line when the rename below didn't run.
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }
	if _, err := io.Copy(tmp, data); err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("storage/fs: write temp: %w", err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("storage/fs: chmod temp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return fmt.Errorf("storage/fs: close temp: %w", err)
	}
	if err := os.Rename(tmpName, dst); err != nil {
		cleanup()
		return fmt.Errorf("storage/fs: rename: %w", err)
	}
	return nil
}

// Get opens the file at the content-addressed path. The caller MUST
// close the returned reader.
func (f *FS) Get(ctx context.Context, userID uuid.UUID, sha256 string) (io.ReadCloser, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	path, err := f.pathFor(userID, sha256)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("storage/fs: open: %w", err)
	}
	return file, nil
}

// Delete removes the content-addressed path. Missing object is not
// an error (idempotent).
func (f *FS) Delete(ctx context.Context, userID uuid.UUID, sha256 string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	path, err := f.pathFor(userID, sha256)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("storage/fs: remove: %w", err)
	}
	return nil
}
