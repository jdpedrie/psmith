// Package profiles implements the ProfilesService and the parent-chain
// inheritance resolver for Profile records.
package profiles

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/jdpedrie/clark/internal/store"
)

// MaxParentDepth caps the parent-chain walk to prevent runaway resolution on
// pathologically deep configurations.
const MaxParentDepth = 16

// ErrCycle is returned by Resolve when the parent chain contains a cycle.
var ErrCycle = errors.New("profile parent chain contains a cycle")

// ErrTooDeep is returned by Resolve when the parent chain exceeds MaxParentDepth.
var ErrTooDeep = fmt.Errorf("profile parent chain exceeds %d levels", MaxParentDepth)

// parentLoader fetches a parent profile by ID. Abstracted so the resolver can
// be tested without a database.
type parentLoader interface {
	GetProfileByID(ctx context.Context, id uuid.UUID) (store.Profile, error)
}

// Resolve walks the parent chain of `start` and returns a profile where each
// nullable field is the first non-null value encountered (start wins, then
// parent, then grandparent, etc.). Non-null identity fields (id, user_id,
// name, parent_profile_id, created_at, updated_at) are taken from `start`.
//
// Returns ErrCycle if a cycle is detected, ErrTooDeep if the chain exceeds
// MaxParentDepth.
func Resolve(ctx context.Context, q parentLoader, start store.Profile) (store.Profile, error) {
	resolved := start
	visited := map[uuid.UUID]struct{}{start.ID: {}}

	current := start
	for depth := 0; current.ParentProfileID != nil; depth++ {
		if depth >= MaxParentDepth {
			return store.Profile{}, ErrTooDeep
		}
		parentID := *current.ParentProfileID
		if _, seen := visited[parentID]; seen {
			return store.Profile{}, ErrCycle
		}
		visited[parentID] = struct{}{}

		parent, err := q.GetProfileByID(ctx, parentID)
		if err != nil {
			return store.Profile{}, fmt.Errorf("load parent %s: %w", parentID, err)
		}

		mergeFromParent(&resolved, parent)
		current = parent
	}

	return resolved, nil
}

// mergeFromParent fills any nil/absent nullable field on `resolved` with the
// corresponding value from `parent`. Non-null identity fields are left alone.
func mergeFromParent(resolved *store.Profile, parent store.Profile) {
	if resolved.SystemMessage == nil && parent.SystemMessage != nil {
		resolved.SystemMessage = parent.SystemMessage
	}
	if resolved.DefaultUserMessage == nil && parent.DefaultUserMessage != nil {
		resolved.DefaultUserMessage = parent.DefaultUserMessage
	}
	if resolved.CompressionGuide == nil && parent.CompressionGuide != nil {
		resolved.CompressionGuide = parent.CompressionGuide
	}
	if resolved.CompressionMode == nil && parent.CompressionMode != nil {
		resolved.CompressionMode = parent.CompressionMode
	}
	if resolved.CompressionProviderID == nil && parent.CompressionProviderID != nil {
		resolved.CompressionProviderID = parent.CompressionProviderID
	}
	if resolved.CompressionModelID == nil && parent.CompressionModelID != nil {
		resolved.CompressionModelID = parent.CompressionModelID
	}
	if len(resolved.DefaultSettings) == 0 && len(parent.DefaultSettings) > 0 {
		resolved.DefaultSettings = parent.DefaultSettings
	}
	if resolved.TitleProviderID == nil && parent.TitleProviderID != nil {
		resolved.TitleProviderID = parent.TitleProviderID
	}
	if resolved.TitleModelID == nil && parent.TitleModelID != nil {
		resolved.TitleModelID = parent.TitleModelID
	}
	if resolved.TitleGuide == nil && parent.TitleGuide != nil {
		resolved.TitleGuide = parent.TitleGuide
	}
}
