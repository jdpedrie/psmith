package auth

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/testutil"
)

// TouchSession runs on every authenticated request, so it is guarded by an
// interval: without that, a read becomes a write on a hot row at request rate.
func TestTouchSession_IsAnIntervalNotEveryRequest(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	ctx := context.Background()

	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(ctx, store.CreateUserParams{
		ID: uid, Username: "touch-" + uid.String()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	if err := q.CreateSession(ctx, store.CreateSessionParams{
		TokenHash: "hash-" + uid.String(),
		UserID:    user.ID,
		ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	read := func() time.Time {
		row, err := q.GetSessionWithUser(ctx, "hash-"+uid.String())
		if err != nil {
			t.Fatalf("GetSessionWithUser: %v", err)
		}
		return row.LastUsedAt
	}

	first := read()
	// A freshly created session is inside the interval, so a touch right after
	// it must be a no-op. This is the case that runs on nearly every request.
	if err := q.TouchSession(ctx, "hash-"+uid.String()); err != nil {
		t.Fatalf("TouchSession: %v", err)
	}
	if got := read(); !got.Equal(first) {
		t.Errorf("a touch inside the interval must not write: %v -> %v", first, got)
	}

	// Age the row past the interval; the next touch should land.
	if _, err := pool.Exec(ctx,
		`UPDATE sessions SET last_used_at = NOW() - INTERVAL '1 hour' WHERE token_hash = $1`,
		"hash-"+uid.String()); err != nil {
		t.Fatalf("age session: %v", err)
	}
	aged := read()
	if err := q.TouchSession(ctx, "hash-"+uid.String()); err != nil {
		t.Fatalf("TouchSession: %v", err)
	}
	if got := read(); !got.After(aged) {
		t.Errorf("a touch past the interval must write: %v -> %v", aged, got)
	}
}
