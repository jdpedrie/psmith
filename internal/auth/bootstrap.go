package auth

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"

	"github.com/jdpedrie/psmith/internal/store"
)

// Bootstrap creates an admin user on first run if none exists. If
// users already exist, no-op. If no users and no bootstrap creds,
// log a loud warning and return nil — the server still starts, but
// every authenticated RPC will reject with Unauthenticated until
// somebody runs `psmith useradd`. This shape is friendlier to Docker
// deployments where the operator wants to bring the container up
// first, then `docker exec … psmith useradd alice`.
func Bootstrap(ctx context.Context, q *store.Queries, username, password string) error {
	n, err := q.CountUsers(ctx)
	if err != nil {
		return fmt.Errorf("count users: %w", err)
	}
	if n > 0 {
		return nil
	}

	if username == "" || password == "" {
		slog.Warn("psmithd: no users in database — every RPC will reject until one is created. Run `psmith useradd <name>` (in the container, that's `docker exec <name> psmith useradd <user>`) or set PSMITH_BOOTSTRAP_ADMIN_USERNAME + PSMITH_BOOTSTRAP_ADMIN_PASSWORD on next start.")
		return nil
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash bootstrap password: %w", err)
	}

	id, err := uuid.NewV7()
	if err != nil {
		return fmt.Errorf("generate uuid: %w", err)
	}

	if _, err := q.CreateUser(ctx, store.CreateUserParams{
		ID:           id,
		Username:     username,
		PasswordHash: string(hash),
		IsAdmin:      true,
	}); err != nil {
		return fmt.Errorf("create admin user: %w", err)
	}

	slog.Info("bootstrapped admin user", "username", username)
	return nil
}
