package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"

	"github.com/jdpedrie/clark/internal/store"
)

// Bootstrap creates an admin user on first run if none exists.
// If users already exist, no-op. If no users and the credentials are empty,
// returns an error so the caller can refuse to start.
func Bootstrap(ctx context.Context, q *store.Queries, username, password string) error {
	n, err := q.CountUsers(ctx)
	if err != nil {
		return fmt.Errorf("count users: %w", err)
	}
	if n > 0 {
		return nil
	}

	if username == "" || password == "" {
		return errors.New("no users exist and no bootstrap admin credentials provided")
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
