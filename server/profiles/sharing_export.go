package profiles

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/mcpreg"
	"github.com/jdpedrie/psmith/server/store"
)

// bundleMagic prefixes every exported payload. A bundle that arrives without
// it is a paste of the wrong thing or a truncated file, and saying so beats
// letting proto.Unmarshal succeed on partial input and import nonsense.
var bundleMagic = []byte("PSMITHPROFILE\x00")

// bundleVersion is the payload's format version. Bumped only for changes an
// older importer would misread; additive proto fields do not need it.
const bundleVersion = 1

// ExportProfile serializes a profile into a portable bundle.
//
// The security property this function exists to hold: a bundle never carries
// a credential. Two independent paths could leak one, and both are closed
// here rather than at the boundary, because a caller who forgets is a caller
// who ships someone's API key.
//
//  1. Plugin config keys whose ConfigField declares Global or Secret. Global
//     values belong to user_plugin_settings and are not the profile's to give
//     away; Secret values are credentials wherever they live. The set is read
//     from the plugin's own declaration at runtime, so a new plugin with a new
//     credential field is covered without touching this file.
//  2. Registered MCP servers. Their specs hold env vars and auth headers,
//     encrypted at rest precisely because they are secret, so the reference is
//     exported as the server's NAME and the spec is never read.
func (s *Service) ExportProfile(ctx context.Context, req *connect.Request[psmithv1.ExportProfileRequest]) (*connect.Response[psmithv1.ExportProfileResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.ProfileId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid profile_id: %w", err))
	}
	leaf, err := s.fetchOwned(ctx, id, caller.ID)
	if err != nil {
		return nil, err
	}

	chain, err := s.ownedChain(ctx, leaf, caller.ID)
	if err != nil {
		return nil, err
	}

	var (
		bundled []*psmithv1.BundledProfile
		notices []string
	)
	if req.Msg.PreserveChain {
		// Root-to-leaf, so an importer can create in order and rewire each
		// parent as it goes.
		for i := len(chain) - 1; i >= 0; i-- {
			bp, ns, err := s.bundleOne(ctx, chain[i], caller.ID, false)
			if err != nil {
				return nil, err
			}
			bp.Ref = chain[i].ID.String()
			if p := chain[i].ParentProfileID; p != nil && i+1 < len(chain) {
				bp.ParentRef = p.String()
			}
			bundled = append(bundled, bp)
			notices = append(notices, ns...)
		}
	} else {
		// Flattened: one profile carrying the fully inherited values, so the
		// recipient gets something that behaves identically without four
		// parent_only rows cluttering their list.
		resolved, err := Resolve(ctx, s.queries, leaf)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("resolve chain: %w", err))
		}
		bp, ns, err := s.bundleOne(ctx, resolved, caller.ID, true)
		if err != nil {
			return nil, err
		}
		bp.Ref = resolved.ID.String()
		bundled = append(bundled, bp)
		notices = ns
	}

	payload, err := proto.Marshal(&psmithv1.ProfileBundle{
		Version:    bundleVersion,
		Profiles:   bundled,
		ExportedBy: caller.Username,
		ExportedAt: timestamppb.Now(),
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("marshal bundle: %w", err))
	}

	return connect.NewResponse(&psmithv1.ExportProfileResponse{
		Payload:           append(append([]byte{}, bundleMagic...), payload...),
		SuggestedFilename: bundleFilename(leaf.Name),
		Notices:           dedupe(notices),
	}), nil
}

// ownedChain walks leaf to root, checking ownership at every hop. A profile
// whose parent belongs to someone else is a bug elsewhere, but exporting it
// would turn that bug into a data leak, so the walk stops rather than
// including it.
func (s *Service) ownedChain(ctx context.Context, leaf store.Profile, userID uuid.UUID) ([]store.Profile, error) {
	chain := []store.Profile{leaf}
	seen := map[uuid.UUID]bool{leaf.ID: true}
	cur := leaf
	for cur.ParentProfileID != nil {
		if len(chain) > MaxParentDepth {
			return nil, connect.NewError(connect.CodeFailedPrecondition, ErrTooDeep)
		}
		if seen[*cur.ParentProfileID] {
			return nil, connect.NewError(connect.CodeFailedPrecondition, ErrCycle)
		}
		parent, err := s.queries.GetProfileByID(ctx, *cur.ParentProfileID)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load parent: %w", err))
		}
		if parent.UserID != userID {
			break
		}
		seen[parent.ID] = true
		chain = append(chain, parent)
		cur = parent
	}
	return chain, nil
}

// bundleOne converts one profile row. mergedPlugins selects between this
// profile's own plugin rows (chain-preserving export, where each profile
// carries its own layer) and the merged effective pipeline (flattened
// export, where one profile has to stand in for the whole chain).
func (s *Service) bundleOne(ctx context.Context, p store.Profile, userID uuid.UUID, mergedPlugins bool) (*psmithv1.BundledProfile, []string, error) {
	out := &psmithv1.BundledProfile{
		Name:               p.Name,
		SystemMessage:      p.SystemMessage,
		DefaultUserMessage: p.DefaultUserMessage,
		CompressionGuide:   p.CompressionGuide,
		TitleGuide:         p.TitleGuide,
		TitleProviderKind:  p.TitleProviderKind,
		Description:        p.Description,
		ParentOnly:         p.ParentOnly,
		WelcomeMessage:     p.WelcomeMessage,
	}
	if p.CompressionMode != nil {
		m := compressionModeFromString(*p.CompressionMode)
		out.CompressionMode = &m
	}

	defaults, err := defaultsFromJSON(p.DefaultSettings)
	if err != nil {
		return nil, nil, connect.NewError(connect.CodeInternal, err)
	}
	if defaults != nil {
		out.CallSettings = defaults.CallSettings
		out.IncludeThinkingInHistory = defaults.IncludeThinkingInHistory
		if defaults.DefaultProviderId != nil && defaults.DefaultModelId != nil {
			out.DefaultModel = s.modelRef(ctx, *defaults.DefaultProviderId, *defaults.DefaultModelId, userID)
		}
	}
	if p.CompressionProviderID != nil && p.CompressionModelID != nil {
		out.CompressionModel = s.modelRef(ctx, p.CompressionProviderID.String(), *p.CompressionModelID, userID)
	}
	if p.TitleProviderID != nil && p.TitleModelID != nil {
		out.TitleModel = s.modelRef(ctx, p.TitleProviderID.String(), *p.TitleModelID, userID)
	}

	rows, err := s.pluginRowsFor(ctx, p.ID, mergedPlugins)
	if err != nil {
		return nil, nil, err
	}

	var notices []string
	for _, r := range rows {
		bp, ns, err := s.bundlePlugin(ctx, r, userID)
		if err != nil {
			return nil, nil, err
		}
		notices = append(notices, ns...)
		if bp != nil {
			out.Plugins = append(out.Plugins, bp)
		}
	}
	return out, notices, nil
}

// bundlePlugin strips the credential-bearing keys and rewrites an MCP
// registry reference as a name. Returns nil when the row must not travel.
func (s *Service) bundlePlugin(ctx context.Context, r store.ProfilePlugin, userID uuid.UUID) (*psmithv1.BundledPlugin, []string, error) {
	out := &psmithv1.BundledPlugin{
		PluginName: r.PluginName,
		Ordinal:    r.Ordinal,
		Disabled:   r.Disabled,
	}

	if strings.HasPrefix(r.PluginName, mcpreg.Prefix) {
		// A registry reference. Export the name; never touch the spec.
		idStr := strings.TrimPrefix(r.PluginName, mcpreg.Prefix)
		sid, err := uuid.Parse(idStr)
		if err != nil {
			return nil, nil, nil
		}
		srv, err := s.queries.GetUserMCPServer(ctx, sid)
		if err != nil || srv.UserID != userID {
			// Dangling or foreign reference: drop it rather than exporting a
			// pointer the importer could never resolve.
			return nil, nil, nil
		}
		out.PluginName = "mcp"
		out.McpServerName = &srv.Name
		notice := fmt.Sprintf("The MCP server %q is referenced by name only. Its command, environment and headers stay on this server, so whoever imports this will need their own %q entry.", srv.Name, srv.Name)
		return out, []string{notice}, nil
	}

	// Plugin config is sealed at rest; the legacy plaintext column is empty
	// for anything written since encryption landed. Reading r.Config
	// directly would export blank configs for every modern row.
	plain, err := crypto.ResolveSecret(s.cipher, r.ConfigEncrypted, r.Config)
	if err != nil {
		return nil, nil, connect.NewError(connect.CodeInternal, fmt.Errorf("decrypt plugin config: %w", err))
	}

	cleaned, removed, err := stripNonExportableKeys(r.PluginName, plain)
	if err != nil {
		return nil, nil, connect.NewError(connect.CodeInternal, err)
	}
	out.Config = cleaned

	var notices []string
	if len(removed) > 0 {
		notices = append(notices, fmt.Sprintf(
			"%s: %s not included (credentials never leave this server). The recipient will need to supply their own.",
			displayNameOf(r.PluginName), humanList(removed)))
	}
	return out, notices, nil
}

// stripNonExportableKeys removes every config key the plugin declares Global
// or Secret, and returns the display labels of what it removed.
//
// Derived from the plugin's own ConfigFields rather than a blacklist here, so
// this stays correct as plugins gain fields. An unregistered plugin (a config
// row for something this build does not have) is the one case we cannot
// inspect: its whole config is dropped, because "I do not know which of these
// keys is an API key" has exactly one safe answer.
func stripNonExportableKeys(pluginName string, config []byte) ([]byte, []string, error) {
	if len(config) == 0 {
		return config, nil, nil
	}
	desc, err := pluginapi.Describe(pluginName)
	if err != nil {
		return nil, []string{"all settings"}, nil
	}

	blocked := map[string]string{}
	for _, f := range desc.ConfigFields {
		if f.Global || f.Secret {
			label := f.Display
			if label == "" {
				label = f.Name
			}
			blocked[f.Name] = label
		}
	}
	if len(blocked) == 0 {
		return config, nil, nil
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(config, &raw); err != nil {
		// Unparseable config we cannot inspect key-by-key. Drop it whole.
		return nil, []string{"all settings"}, nil
	}
	var removed []string
	for k, label := range blocked {
		if _, ok := raw[k]; ok {
			delete(raw, k)
			removed = append(removed, label)
		}
	}
	if len(removed) == 0 {
		return config, nil, nil
	}
	sort.Strings(removed)
	cleaned, err := json.Marshal(raw)
	if err != nil {
		return nil, nil, fmt.Errorf("re-marshal stripped config: %w", err)
	}
	return cleaned, removed, nil
}

// modelRef converts a (provider uuid, model id) pair into the portable
// (driver type, model id) form. Returns nil when the provider is gone or
// foreign, which leaves the field unset and lets the importer's own default
// apply.
func (s *Service) modelRef(ctx context.Context, providerID, modelID string, userID uuid.UUID) *psmithv1.ModelRef {
	pid, err := uuid.Parse(providerID)
	if err != nil {
		return nil
	}
	prov, err := s.queries.GetUserModelProvider(ctx, pid)
	if err != nil || prov.UserID != userID {
		return nil
	}
	return &psmithv1.ModelRef{ProviderType: prov.Type, ModelId: modelID}
}

var filenameUnsafe = regexp.MustCompile(`[^a-z0-9]+`)

func bundleFilename(name string) string {
	slug := strings.Trim(filenameUnsafe.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if slug == "" {
		slug = "profile"
	}
	return slug + ".psmithprofile"
}

func humanList(items []string) string {
	switch len(items) {
	case 0:
		return ""
	case 1:
		return items[0]
	case 2:
		return items[0] + " and " + items[1]
	}
	return strings.Join(items[:len(items)-1], ", ") + " and " + items[len(items)-1]
}

func displayNameOf(pluginName string) string {
	if d, err := pluginapi.Describe(pluginName); err == nil && d.DisplayName != "" {
		return d.DisplayName
	}
	return pluginName
}

func dedupe(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// pluginRowsFor returns the plugin rows an export should carry.
//
// A chain-preserving export gives each profile its own rows, because the
// chain is reconstructed on the other side and the merge happens there. A
// flattened export has one profile standing in for the whole chain, so it
// needs the merged effective pipeline instead: leaf-most row per plugin
// name wins, a disabled row subtracts, ordering by ordinal then name. Same
// rules the conversations-side resolver applies at build time.
func (s *Service) pluginRowsFor(ctx context.Context, profileID uuid.UUID, merged bool) ([]store.ProfilePlugin, error) {
	if !merged {
		rows, err := s.queries.ListProfilePlugins(ctx, profileID)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("list plugins: %w", err))
		}
		return rows, nil
	}

	byName := map[string]store.ProfilePlugin{}
	dropped := map[string]bool{}
	seen := map[uuid.UUID]bool{}
	cur := profileID
	for {
		if seen[cur] {
			return nil, connect.NewError(connect.CodeFailedPrecondition, ErrCycle)
		}
		seen[cur] = true
		prof, err := s.queries.GetProfileByID(ctx, cur)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("get profile %s: %w", cur, err))
		}
		rows, err := s.queries.ListProfilePlugins(ctx, cur)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("list plugins %s: %w", cur, err))
		}
		for _, r := range rows {
			if dropped[r.PluginName] {
				continue
			}
			if r.Disabled {
				// An explicit subtract anywhere in the chain wins over any
				// ancestor's enabled row, so record it and keep it dropped.
				dropped[r.PluginName] = true
				delete(byName, r.PluginName)
				continue
			}
			if _, ok := byName[r.PluginName]; !ok {
				byName[r.PluginName] = r
			}
		}
		if prof.ParentProfileID == nil {
			break
		}
		cur = *prof.ParentProfileID
	}

	out := make([]store.ProfilePlugin, 0, len(byName))
	for _, r := range byName {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Ordinal != out[j].Ordinal {
			return out[i].Ordinal < out[j].Ordinal
		}
		return out[i].PluginName < out[j].PluginName
	})
	return out, nil
}
