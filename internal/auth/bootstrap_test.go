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

func TestBootstrap_NoUsersNoCreds_AllowsStart(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)

	// Empty creds + empty DB now returns nil (with a logged warning)
	// so the operator can bring reeved up first and create users via
	// `reeve useradd`. Verify no admin was silently created.
	if err := auth.Bootstrap(context.Background(), q, "", ""); err != nil {
		t.Fatalf("expected nil; got %v", err)
	}
	n, err := q.CountUsers(context.Background())
	if err != nil {
		t.Fatalf("CountUsers: %v", err)
	}
	if n != 0 {
		t.Errorf("CountUsers = %d; want 0 (Bootstrap should not have created anyone)", n)
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
