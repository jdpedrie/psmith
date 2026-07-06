// Package profiles implements the ProfilesService and the parent-chain
// inheritance resolver for Profile records.
package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
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
// For the `default_settings` JSONB column the merge is field-aware:
// non-call_settings fields use the existing all-or-nothing fall-through
// (child's blob wins if present), while the embedded `call_settings` block
// is sparse-merged across every layer in the chain via MergeCallSettings —
// child wins per-field, parent fills in the unset fields, recursively up to
// MaxParentDepth.
//
// Returns ErrCycle if a cycle is detected, ErrTooDeep if the chain exceeds
// MaxParentDepth.
func Resolve(ctx context.Context, q parentLoader, start store.Profile) (store.Profile, error) {
	resolved := start
	visited := map[uuid.UUID]struct{}{start.ID: {}}

	// Pull the start layer's call_settings first; subsequent parents merge
	// into this as the lower layer (child wins).
	mergedCS, err := decodeProfileCallSettings(start)
	if err != nil {
		return store.Profile{}, err
	}

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

		parentCS, err := decodeProfileCallSettings(parent)
		if err != nil {
			return store.Profile{}, err
		}
		// mergedCS is the higher layer (closer to start); parentCS is lower.
		mergedCS = MergeCallSettings(mergedCS, parentCS)

		current = parent
	}

	// Re-encode merged call_settings into resolved.DefaultSettings so callers
	// reading the resolved profile observe the inherited block.
	if mergedCS != nil {
		updated, err := overlayCallSettings(resolved.DefaultSettings, mergedCS)
		if err != nil {
			return store.Profile{}, err
		}
		resolved.DefaultSettings = updated
	}

	return resolved, nil
}

// decodeProfileCallSettings extracts the `call_settings` sub-object from a
// profile's `default_settings` JSONB blob. Returns (nil, nil) when the blob
// is empty or the field is missing — those layers contribute nothing.
func decodeProfileCallSettings(p store.Profile) (*psmithv1.CallSettings, error) {
	if len(p.DefaultSettings) == 0 {
		return nil, nil
	}
	var s struct {
		CallSettings json.RawMessage `json:"call_settings,omitempty"`
	}
	if err := json.Unmarshal(p.DefaultSettings, &s); err != nil {
		return nil, fmt.Errorf("decode profile %s default_settings: %w", p.ID, err)
	}
	if len(s.CallSettings) == 0 {
		return nil, nil
	}
	return UnmarshalCallSettings(s.CallSettings)
}

// overlayCallSettings writes `cs` into the `call_settings` field of an
// existing default_settings JSONB blob, preserving any sibling fields
// (`default_provider_id`, etc). When the input blob is empty/nil we synthesize
// a minimal one carrying just call_settings.
func overlayCallSettings(blob []byte, cs *psmithv1.CallSettings) ([]byte, error) {
	encoded, err := MarshalCallSettings(cs)
	if err != nil {
		return nil, fmt.Errorf("encode merged call_settings: %w", err)
	}

	// Fast path: no existing blob → write a struct with only call_settings.
	if len(blob) == 0 {
		out := struct {
			CallSettings json.RawMessage `json:"call_settings"`
		}{CallSettings: encoded}
		return json.Marshal(out)
	}

	// Otherwise round-trip through a generic map so we don't lose unknown
	// keys. The defaultsStorage struct in service.go knows the typed shape;
	// here we preserve everything.
	var m map[string]json.RawMessage
	if err := json.Unmarshal(blob, &m); err != nil {
		return nil, fmt.Errorf("decode default_settings: %w", err)
	}
	if m == nil {
		m = map[string]json.RawMessage{}
	}
	if encoded != nil {
		m["call_settings"] = encoded
	} else {
		delete(m, "call_settings")
	}
	return json.Marshal(m)
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
	if resolved.TitleProviderKind == nil && parent.TitleProviderKind != nil {
		resolved.TitleProviderKind = parent.TitleProviderKind
	}
}
