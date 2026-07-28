package profiles

import (
	"context"
	"fmt"
	"sort"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/store"
)

// ResolveRequiredModelCapabilities returns the union of model capability
// requirements declared by every plugin in the profile's effective
// pipeline, with parent-chain inheritance applied the same LAYERED way
// the pipeline builder applies it (see
// `internal/conversations/service.go::layeredProfileChain`): every profile
// in the chain contributes its plugins, and a `disabled` row subtracts one
// that an ancestor contributed.
//
// This must mirror the builder exactly or the gate lies. It previously
// used an all-or-nothing rule — the first profile in the chain with any
// rows won outright — which meant a child profile that attached any plugin
// of its own hid every requirement declared by its parent. A base profile
// carrying a tool plugin plus a child that merely adds a display plugin
// would silently drop the tool_use requirement, and the send would be
// allowed against a model that cannot call tools.
//
// Unknown plugin names in the pipeline are silently skipped; a stale row
// shouldn't fail the read path. The pipeline-build at SendMessage time
// surfaces unknowns as a hard error there.
//
// Not covered: `conversation_plugins`. A plugin attached only at the
// conversation level still escapes this gate, because the caller resolves
// from a profile id. Send-time validation happens before the pipeline is
// built, so closing that gap means threading the conversation through.
//
// Cycles in the parent chain abort with an error so a misconfigured graph
// surfaces immediately rather than spinning.
func ResolveRequiredModelCapabilities(
	ctx context.Context,
	q *store.Queries,
	profileID uuid.UUID,
) (pluginapi.ModelCapabilityRequirements, error) {
	names, err := resolveEffectivePluginNames(ctx, q, profileID)
	if err != nil {
		return pluginapi.ModelCapabilityRequirements{}, err
	}
	var caps pluginapi.ModelCapabilityRequirements
	for _, name := range names {
		d, err := pluginapi.Describe(name)
		if err != nil {
			continue
		}
		caps = caps.Combine(d.RequiredModelCapabilities)
	}
	return caps, nil
}

// resolveEffectivePluginNames walks the parent chain leaf → root and
// returns every active plugin name in pipeline order. Deliberately a
// name-only mirror of `layeredProfileChain` in the conversations service:
// same walk, same drop semantics, minus the config decryption this caller
// has no use for. The two must not diverge — see the note on
// ResolveRequiredModelCapabilities about what happens when they do.
//
// Leaf-most wins: the first sighting of a name fixes its ordinal, and a
// `disabled` row drops the name for good so an ancestor cannot resurrect
// it. Returns nil when nothing in the chain has plugins.
func resolveEffectivePluginNames(
	ctx context.Context,
	q *store.Queries,
	profileID uuid.UUID,
) ([]string, error) {
	type entry struct {
		name    string
		ordinal int32
	}
	cur := profileID
	seen := map[uuid.UUID]bool{}
	byName := map[string]*entry{}
	dropped := map[string]bool{}
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
		for _, r := range rows {
			if dropped[r.PluginName] {
				continue
			}
			if r.Disabled {
				dropped[r.PluginName] = true
				delete(byName, r.PluginName)
				continue
			}
			if _, ok := byName[r.PluginName]; !ok {
				byName[r.PluginName] = &entry{name: r.PluginName, ordinal: r.Ordinal}
			}
		}
		if prof.ParentProfileID == nil {
			break
		}
		cur = *prof.ParentProfileID
	}
	if len(byName) == 0 {
		return nil, nil
	}
	// Order is irrelevant to the caller (it unions the requirements), but
	// keeping it deterministic — ordinal then name, as the pipeline sorts —
	// makes the function honest about returning "pipeline order" and keeps
	// tests stable.
	out := make([]*entry, 0, len(byName))
	for _, e := range byName {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].ordinal != out[j].ordinal {
			return out[i].ordinal < out[j].ordinal
		}
		return out[i].name < out[j].name
	})
	names := make([]string, 0, len(out))
	for _, e := range out {
		names = append(names, e.name)
	}
	return names, nil
}
