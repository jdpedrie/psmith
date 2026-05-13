// Package storage abstracts blob storage for user-uploaded files
// (and, later, model-generated files like image-gen outputs and
// audio attachments).
//
// v1 ships a filesystem backend (`fs.Storage`) that writes to
// `$REEVE_DATA_DIR/files/{user_id}/{sha256}` with restrictive
// permissions (0700 dir / 0600 file). S3 / GCS / R2 backends slot
// in later behind the same `Storage` interface without touching
// callers. The interface is content-addressed by `(user_id, sha256)`
// because that's the natural dedup key — re-uploading the same
// content by the same user is a no-op.
//
// Signed URLs are a separate concern living above the interface:
// the conversations / files service mints them with an HMAC over
// (file_id, user_id, expires_at) and serves the bytes through
// `Get` on the verified path.
package storage

import (
	"context"
	"errors"
	"io"

	"github.com/google/uuid"
)

// ErrNotFound is returned by Get / Delete when the requested object
// is missing. Callers can `errors.Is` against this rather than the
// backend-specific error.
var ErrNotFound = errors.New("storage: object not found")

// Storage is the minimal surface every backend implements. Callers
// supply user_id + sha256 (the content-address pair). Backends MAY
// store additional metadata server-side; callers should not depend
// on it.
type Storage interface {
	// Put writes bytes for (userID, sha256). Idempotent: a second Put
	// with identical inputs is a no-op (filesystem backend short-
	// circuits when the file already exists; future backends should
	// match the semantic). Mime is stored alongside in DB rows (not
	// in the blob itself) so the backend doesn't need to track it.
	Put(ctx context.Context, userID uuid.UUID, sha256 string, mime string, data io.Reader) error

	// Get returns a reader over the bytes for (userID, sha256). The
	// caller MUST close it. Returns ErrNotFound when the object isn't
	// present.
	Get(ctx context.Context, userID uuid.UUID, sha256 string) (io.ReadCloser, error)

	// Delete removes (userID, sha256). Idempotent — a missing object
	// is not an error. The caller is responsible for cascading
	// `files` rows ahead of the blob delete; the FK on
	// message_attachments → files protects against dangling
	// references within the DB.
	Delete(ctx context.Context, userID uuid.UUID, sha256 string) error
}
