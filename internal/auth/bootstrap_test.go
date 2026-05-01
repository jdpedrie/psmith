package auth_test

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

func TestBootstrap_NoUsersWithCreds_CreatesAdmin(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)

	if err := auth.Bootstrap(context.Background(), q, "bootadmin", "bootpass"); err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}

	u, err := q.GetUserByUsername(context.Background(), "bootadmin")
	if err != nil {
		t.Fatalf("GetUserByUsername: %v", err)
	}
	if !u.IsAdmin {
		t.Error("bootstrapped user should be admin")
	}
}

func TestBootstrap_NoUsersNoCreds_Errors(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)

	if err := auth.Bootstrap(context.Background(), q, "", ""); err == nil {
		t.Fatal("expected error when no users and no credentials")
	}
}

func TestBootstrap_UsersExist_Noop(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)

	id, _ := uuid.NewV7()
	if _, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID:           id,
		Username:     "existing",
		PasswordHash: "x",
		IsAdmin:      false,
	}); err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	// Even with creds provided, Bootstrap should be a no-op since users exist.
	if err := auth.Bootstrap(context.Background(), q, "wouldbe", "x"); err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}

	users, err := q.ListUsers(context.Background())
	if err != nil {
		t.Fatalf("ListUsers: %v", err)
	}
	if len(users) != 1 {
		t.Errorf("expected 1 user after no-op bootstrap, got %d", len(users))
	}
	if users[0].Username != "existing" {
		t.Errorf("expected only 'existing', got %q", users[0].Username)
	}
}
