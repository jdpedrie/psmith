package conversations

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/testutil"
)

// seedChain builds parent -> child -> grandchild and returns the leaf.
func seedChain(t *testing.T, q *store.Queries, depth int) (store.User, uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(ctx, store.CreateUserParams{
		ID: uid, Username: "chain-" + uid.String()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	var parent *uuid.UUID
	var leaf uuid.UUID
	for i := 0; i < depth; i++ {
		pid, _ := uuid.NewV7()
		p, err := q.CreateProfile(ctx, store.CreateProfileParams{
			ID: pid, UserID: user.ID, Name: "level", ParentProfileID: parent,
		})
		if err != nil {
			t.Fatalf("CreateProfile: %v", err)
		}
		leaf = p.ID
		id := p.ID
		parent = &id
	}
	return user, leaf
}

// Repeated resolution of one profile inside a request costs one chain walk.
func TestProfileCache_ResolvesOncePerRequest(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	_, leaf := seedChain(t, q, 3)

	cache := newProfileCache(q)
	ctx := context.Background()
	first, err := cache.resolve(ctx, leaf)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	// Four more resolutions, the number SendMessage used to perform.
	for i := 0; i < 4; i++ {
		got, err := cache.resolve(ctx, leaf)
		if err != nil {
			t.Fatalf("resolve %d: %v", i, err)
		}
		if got.ID != first.ID {
			t.Fatalf("resolve %d returned a different profile", i)
		}
	}
	if len(cache.resolved) != 1 {
		t.Errorf("expected one cached resolution, got %d", len(cache.resolved))
	}
}

// The ownership check runs before any chain walk, so `load` must not populate
// the resolved cache or resolve anything.
func TestProfileCache_LoadDoesNotResolve(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	_, leaf := seedChain(t, q, 3)

	cache := newProfileCache(q)
	if _, err := cache.load(context.Background(), leaf); err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(cache.resolved) != 0 {
		t.Error("load must not trigger or cache a chain walk")
	}
	if len(cache.raw) != 1 {
		t.Errorf("load should cache the raw row, got %d", len(cache.raw))
	}
}

// Two children of one parent must not collide: the cache is keyed by the
// STARTING profile, and keying by any ancestor would serve one child the
// other's resolved values.
func TestProfileCache_SiblingsDoNotCollide(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	ctx := context.Background()

	user, parent := seedChain(t, q, 1)
	mk := func(name string) uuid.UUID {
		id, _ := uuid.NewV7()
		sys := name
		p, err := q.CreateProfile(ctx, store.CreateProfileParams{
			ID: id, UserID: user.ID, Name: name,
			ParentProfileID: &parent, SystemMessage: &sys,
		})
		if err != nil {
			t.Fatalf("CreateProfile: %v", err)
		}
		return p.ID
	}
	a, b := mk("alpha"), mk("beta")

	cache := newProfileCache(q)
	ra, err := cache.resolve(ctx, a)
	if err != nil {
		t.Fatalf("resolve a: %v", err)
	}
	rb, err := cache.resolve(ctx, b)
	if err != nil {
		t.Fatalf("resolve b: %v", err)
	}
	if ra.ID == rb.ID {
		t.Fatal("siblings resolved to the same profile")
	}
	if ra.SystemMessage == nil || rb.SystemMessage == nil ||
		*ra.SystemMessage == *rb.SystemMessage {
		t.Errorf("siblings should keep their own values: %v vs %v",
			ra.SystemMessage, rb.SystemMessage)
	}
}

// A context without a cache must behave exactly as before, so every caller
// outside the send path keeps working untouched.
func TestResolveProfile_WorksWithoutACache(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	_, leaf := seedChain(t, q, 2)

	svc := &Service{queries: q}
	got, err := svc.resolveProfile(context.Background(), leaf)
	if err != nil {
		t.Fatalf("resolveProfile: %v", err)
	}
	if got.ID != leaf {
		t.Errorf("resolved the wrong profile: %v", got.ID)
	}
}
