// Package providerkit turns a stored provider row into a usable driver.
//
// The sequence — load the row, check it belongs to the caller, decrypt the
// config, build the driver, assert the interface it needs — was written out by
// hand in six places across the conversations and modelproviders services,
// with the decryption helper duplicated verbatim between them. Every copy was
// correct; the shape was simply missing, which is why the seventh appeared the
// moment a new feature (the council moderator) needed a model call.
//
// The ownership check is the reason this is worth centralizing rather than
// tolerating. It is one line, it is easy to leave out, and leaving it out lets
// a caller spend another user's credentials. Making it part of opening a
// provider means it cannot be forgotten by the next call site.
package providerkit

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

// ErrNotFound covers both "no such provider" and "not yours".
//
// Deliberately one error: distinguishing them tells an attacker which provider
// ids exist, and every caller maps both to the same response anyway.
var ErrNotFound = errors.New("providerkit: provider not found")

// ErrNotStateless is returned when a driver cannot serve a session-less send.
// Stateful harness drivers have no such surface yet; callers decide whether
// that is fatal or something to report inline.
var ErrNotStateless = errors.New("providerkit: driver is not a stateless provider")

// Queries is the slice of the store this package needs.
type Queries interface {
	GetUserModelProvider(ctx context.Context, id uuid.UUID) (store.UserModelProvider, error)
}

// Opener builds drivers from stored provider rows.
type Opener struct {
	Queries Queries
	Cipher  crypto.Cipher
	Deps    providers.Deps
}

// Config decrypts a provider row's config, tolerating the legacy plaintext
// column and normalizing empty to an empty object.
//
// Exported because a few callers need the bytes without a driver (config
// merges, export). It is the piece that was duplicated verbatim.
func (o Opener) Config(row store.UserModelProvider) ([]byte, error) {
	b, err := crypto.ResolveSecret(o.Cipher, row.ConfigEncrypted, row.Config)
	if err != nil {
		return nil, fmt.Errorf("decrypt provider config: %w", err)
	}
	if len(b) == 0 {
		return []byte("{}"), nil
	}
	return b, nil
}

// Load fetches a provider row and verifies ownership.
//
// Pass uuid.Nil for ownerID only where the caller has already established
// ownership by another route; every request-facing path should pass the
// authenticated user.
func (o Opener) Load(ctx context.Context, id, ownerID uuid.UUID) (store.UserModelProvider, error) {
	row, err := o.Queries.GetUserModelProvider(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return store.UserModelProvider{}, ErrNotFound
		}
		return store.UserModelProvider{}, err
	}
	if ownerID != uuid.Nil && row.UserID != ownerID {
		return store.UserModelProvider{}, ErrNotFound
	}
	return row, nil
}

// Open loads, checks ownership, decrypts and builds the driver.
func (o Opener) Open(ctx context.Context, id, ownerID uuid.UUID) (providers.Provider, store.UserModelProvider, error) {
	row, err := o.Load(ctx, id, ownerID)
	if err != nil {
		return nil, store.UserModelProvider{}, err
	}
	drv, err := o.Build(row)
	return drv, row, err
}

// Build constructs a driver from an already-loaded row, for callers that
// needed the row for something else first.
func (o Opener) Build(row store.UserModelProvider) (providers.Provider, error) {
	cfg, err := o.Config(row)
	if err != nil {
		return nil, err
	}
	drv, err := providers.Build(row.Type, o.Deps, cfg)
	if err != nil {
		return nil, fmt.Errorf("build driver: %w", err)
	}
	return drv, nil
}

// OpenStateless is Open plus the interface assertion almost every caller
// wants, since sending a turn is what a provider is mostly for.
func (o Opener) OpenStateless(ctx context.Context, id, ownerID uuid.UUID) (providers.StatelessProvider, store.UserModelProvider, error) {
	drv, row, err := o.Open(ctx, id, ownerID)
	if err != nil {
		return nil, row, err
	}
	sl, ok := drv.(providers.StatelessProvider)
	if !ok {
		return nil, row, fmt.Errorf("%w: %s", ErrNotStateless, row.Type)
	}
	return sl, row, nil
}
