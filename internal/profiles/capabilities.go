package profiles

import (
	"context"
	"fmt"

	"github.com/google/uuid"

	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/plugins"
)

// ResolveRequiredModelCapabilities returns the union of model capability
// requirements declared by every plugin in the profile's effective
// pipeline (with parent-chain inheritance applied via the all-or-nothing
// rule used everywhere else: a profile's plugin list wholly replaces the
// parent's, or — when empty — wholly inherits it).
//
// Unknown plugin names in the pipeline are silently skipped; a stale row
// shouldn't fail the read path. The pipeline-build at SendMessage time
// surfaces unknowns as a hard error there.
//
// Cycles in the parent chain abort with an error so a misconfigured graph
// surfaces immediately rather than spinning.
func ResolveRequiredModelCapabilities(
	ctx context.Context,
	q *store.Queries,
	profileID uuid.UUID,
) (plugins.ModelCapabilityRequirements, error) {
	names, err := resolveEffectivePluginNames(ctx, q, profileID)
	if err != nil {
		return plugins.ModelCapabilityRequirements{}, err
	}
	var caps plugins.ModelCapabilityRequirements
	for _, name := range names {
		d, err := plugins.Describe(name)
		if err != nil {
			continue
		}
		caps = caps.Combine(d.RequiredModelCapabilities)
	}
	return caps, nil
}

// resolveEffectivePluginNames walks the parent chain looking for the first
// profile that has any plugins attached and returns their names in pipeline
// order. Mirrors the all-or-nothing inheritance rule used by
// `internal/conversations/service.go::resolvePluginPipeline`. Returns nil
// when nothing in the chain has plugins.
func resolveEffectivePluginNames(
	ctx context.Context,
	q *store.Queries,
	profileID uuid.UUID,
) ([]string, error) {
	cur := profileID
	seen := map[uuid.UUID]bool{}
	for {
		if seen[cur] {
			return nil, fmt.Errorf("plugin name resolve: parent-profile cycle at %s", cur)
		}
		seen[cur] = true
		prof, err := q.GetProfileByID(ctx, cur)
		if err != nil {
			return nil, fmt.Errorf("get profile %s: %w", cur, err)
		}
		rows, err := q.ListProfilePlugins(ctx, cur)
		if err != nil {
			return nil, fmt.Errorf("list profile plugins %s: %w", cur, err)
		}
		if len(rows) > 0 {
			names := make([]string, 0, len(rows))
			for _, r := range rows {
				names = append(names, r.PluginName)
			}
			return names, nil
		}
		if prof.ParentProfileID == nil {
			return nil, nil
		}
		cur = *prof.ParentProfileID
	}
}
