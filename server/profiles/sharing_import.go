package profiles

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/events"
	"github.com/jdpedrie/psmith/server/mcpreg"
	"github.com/jdpedrie/psmith/server/store"
)

// ImportProfile creates profiles from a bundle.
//
// Never overwrites. Every profile in the bundle becomes a new row owned by
// the caller, so importing can add clutter but can never destroy anything the
// user already had.
//
// Everything the bundle referenced is resolved against the importer's own
// account, and anything that does not resolve becomes null rather than an
// error. A profile that arrives with an unset default model still works (the
// schema already reads null as "inherit"), whereas a failed import over one
// missing provider would be useless. What did not resolve comes back in
// `warnings` so the user can go fix it.
func (s *Service) ImportProfile(ctx context.Context, req *connect.Request[psmithv1.ImportProfileRequest]) (*connect.Response[psmithv1.ImportProfileResponse], error) {
	caller := auth.MustFromContext(ctx)

	bundle, err := decodeBundle(req.Msg.Payload)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}
	if len(bundle.Profiles) == 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("bundle contains no profiles"))
	}

	res, err := s.newImportResolver(ctx, caller.ID)
	if err != nil {
		return nil, err
	}

	if req.Msg.DryRun {
		// Same resolution, no writes, so a client can show exactly what will
		// happen before the user commits.
		var warnings []*psmithv1.ImportWarning
		for _, bp := range bundle.Profiles {
			warnings = append(warnings, res.warningsFor(bp)...)
		}
		return connect.NewResponse(&psmithv1.ImportProfileResponse{
			Warnings: dedupeWarnings(warnings),
			Renamed:  res.renamesFor(bundle.Profiles),
		}), nil
	}

	if s.pool == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("ImportProfile requires pool dependency"))
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	qtx := s.queries.WithTx(tx)

	var (
		created  []*psmithv1.Profile
		warnings []*psmithv1.ImportWarning
		renamed  []string
		// Bundle-local ref to the id we just created for it, so a child's
		// parent_ref rewires onto a real row.
		byRef = map[string]uuid.UUID{}
	)

	for _, bp := range bundle.Profiles {
		name, didRename := res.uniqueName(bp.Name)
		if didRename {
			renamed = append(renamed, name)
			warnings = append(warnings, &psmithv1.ImportWarning{
				Kind:    psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_RENAMED,
				Subject: bp.Name,
				Message: fmt.Sprintf("You already have a profile named %q, so this one was imported as %q.", bp.Name, name),
			})
		}

		var parentID *uuid.UUID
		if bp.ParentRef != "" {
			if pid, ok := byRef[bp.ParentRef]; ok {
				parentID = &pid
			}
		}

		params := store.CreateProfileParams{
			ID:                 uuid.New(),
			UserID:             caller.ID,
			ParentProfileID:    parentID,
			Name:               name,
			SystemMessage:      bp.SystemMessage,
			DefaultUserMessage: bp.DefaultUserMessage,
			CompressionGuide:   bp.CompressionGuide,
			TitleGuide:         bp.TitleGuide,
			TitleProviderKind:  bp.TitleProviderKind,
			Description:        bp.Description,
			ParentOnly:         bp.ParentOnly,
			WelcomeMessage:     bp.WelcomeMessage,
		}
		if bp.CompressionMode != nil {
			m, err := compressionModeToString(*bp.CompressionMode)
			if err != nil {
				return nil, connect.NewError(connect.CodeInvalidArgument, err)
			}
			params.CompressionMode = &m
		}

		// Model references. Each resolves independently, so a bundle whose
		// title model is missing still keeps its default model.
		if pid, ok := res.resolveModel(bp.CompressionModel); ok {
			params.CompressionProviderID = &pid
			params.CompressionModelID = &bp.CompressionModel.ModelId
		}
		if pid, ok := res.resolveModel(bp.TitleModel); ok {
			params.TitleProviderID = &pid
			params.TitleModelID = &bp.TitleModel.ModelId
		}

		defaults := &psmithv1.ProfileDefaults{
			CallSettings:             bp.CallSettings,
			IncludeThinkingInHistory: bp.IncludeThinkingInHistory,
		}
		if pid, ok := res.resolveModel(bp.DefaultModel); ok {
			ps, ms := pid.String(), bp.DefaultModel.ModelId
			defaults.DefaultProviderId = &ps
			defaults.DefaultModelId = &ms
		}
		blob, err := defaultsToJSON(defaults)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encode defaults: %w", err))
		}
		params.DefaultSettings = blob

		row, err := qtx.CreateProfile(ctx, params)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("create profile: %w", err))
		}
		byRef[bp.Ref] = row.ID
		res.claimName(name)

		for _, bpl := range bp.Plugins {
			pluginName, ok := res.resolvePlugin(bpl)
			if !ok {
				continue
			}
			// Seal on the way in, matching SetProfilePlugins. The bundle
			// carries plaintext (it crossed a machine boundary already);
			// what lands in the database is encrypted like every other row.
			var sealed []byte
			if len(bpl.Config) > 0 {
				sealed, err = s.cipher.Encrypt(bpl.Config)
				if err != nil {
					return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("seal plugin config: %w", err))
				}
			}
			if _, err := qtx.InsertProfilePlugin(ctx, store.InsertProfilePluginParams{
				ProfileID:       row.ID,
				Ordinal:         bpl.Ordinal,
				PluginName:      pluginName,
				ConfigEncrypted: sealed,
				Disabled:        bpl.Disabled,
			}); err != nil {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("attach plugin %s: %w", pluginName, err))
			}
		}

		warnings = append(warnings, res.warningsFor(bp)...)

		proto, err := profileToProto(row)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		created = append(created, proto)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	for _, p := range created {
		if id, err := uuid.Parse(p.Id); err == nil {
			s.publishProfileEvent(ctx, caller.ID, id, events.ProfileChangeCreated)
		}
	}

	return connect.NewResponse(&psmithv1.ImportProfileResponse{
		Profiles: created,
		Warnings: dedupeWarnings(warnings),
		Renamed:  renamed,
	}), nil
}

// decodeBundle checks the magic prefix and version before unmarshaling.
//
// proto.Unmarshal is happy to succeed on arbitrary bytes, so without the
// prefix a user who picks the wrong file gets an empty-looking import rather
// than an error. The version check refuses a future format outright: guessing
// at a shape we do not understand is how you silently drop half a profile.
func decodeBundle(payload []byte) (*psmithv1.ProfileBundle, error) {
	if !bytes.HasPrefix(payload, bundleMagic) {
		return nil, errors.New("not a Psmith profile bundle (bad header). Check you picked the right file")
	}
	var b psmithv1.ProfileBundle
	if err := proto.Unmarshal(payload[len(bundleMagic):], &b); err != nil {
		return nil, fmt.Errorf("bundle is corrupt or truncated: %w", err)
	}
	if b.Version > bundleVersion {
		return nil, fmt.Errorf("bundle format version %d is newer than this server understands (%d). Upgrade psmithd", b.Version, bundleVersion)
	}
	return &b, nil
}

// importResolver holds the importer's own rows, loaded once, so resolution
// does not re-query per reference.
type importResolver struct {
	// Driver type to provider ids, so "anthropic" finds whichever Anthropic
	// provider this user configured. Sorted for determinism when a user has
	// several of one type.
	providersByType map[string][]uuid.UUID
	mcpByName       map[string]uuid.UUID
	takenNames      map[string]bool
}

func (s *Service) newImportResolver(ctx context.Context, userID uuid.UUID) (*importResolver, error) {
	r := &importResolver{
		providersByType: map[string][]uuid.UUID{},
		mcpByName:       map[string]uuid.UUID{},
		takenNames:      map[string]bool{},
	}

	provs, err := s.queries.ListUserModelProvidersByUser(ctx, userID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("list providers: %w", err))
	}
	for _, p := range provs {
		r.providersByType[p.Type] = append(r.providersByType[p.Type], p.ID)
	}
	for t := range r.providersByType {
		ids := r.providersByType[t]
		sort.Slice(ids, func(i, j int) bool { return ids[i].String() < ids[j].String() })
	}

	servers, err := s.queries.ListUserMCPServers(ctx, userID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("list mcp servers: %w", err))
	}
	for _, m := range servers {
		r.mcpByName[strings.ToLower(m.Name)] = m.ID
	}

	existing, err := s.queries.ListProfilesByUser(ctx, userID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("list profiles: %w", err))
	}
	for _, p := range existing {
		r.takenNames[strings.ToLower(p.Name)] = true
	}
	return r, nil
}

// resolveModel maps a portable (driver type, model id) onto one of the
// importer's providers of that type. Model ids are not validated against the
// provider's catalog: a model the user has not enabled yet is a recoverable
// situation, and refusing the import over it would be worse than importing a
// profile they then adjust.
func (r *importResolver) resolveModel(ref *psmithv1.ModelRef) (uuid.UUID, bool) {
	if ref == nil || ref.ProviderType == "" || ref.ModelId == "" {
		return uuid.Nil, false
	}
	ids := r.providersByType[ref.ProviderType]
	if len(ids) == 0 {
		return uuid.Nil, false
	}
	return ids[0], true
}

// resolvePlugin returns the plugin name to store, or false to skip the row.
func (r *importResolver) resolvePlugin(p *psmithv1.BundledPlugin) (string, bool) {
	if p.McpServerName != nil {
		id, ok := r.mcpByName[strings.ToLower(*p.McpServerName)]
		if !ok {
			return "", false
		}
		return mcpreg.Prefix + id.String(), true
	}
	if !pluginapi.IsRegistered(p.PluginName) {
		return "", false
	}
	return p.PluginName, true
}

// warningsFor reports everything in one bundled profile that will not resolve.
func (r *importResolver) warningsFor(bp *psmithv1.BundledProfile) []*psmithv1.ImportWarning {
	var out []*psmithv1.ImportWarning

	for label, ref := range map[string]*psmithv1.ModelRef{
		"default model":     bp.DefaultModel,
		"compression model": bp.CompressionModel,
		"title model":       bp.TitleModel,
	} {
		if ref == nil {
			continue
		}
		if _, ok := r.resolveModel(ref); !ok {
			out = append(out, &psmithv1.ImportWarning{
				Kind:    psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_PROVIDER_MISSING,
				Subject: ref.ProviderType,
				Message: fmt.Sprintf("Model provider %q is not configured, so the %s was left unset.", ref.ProviderType, label),
			})
		}
	}

	for _, p := range bp.Plugins {
		if p.McpServerName != nil {
			if _, ok := r.mcpByName[strings.ToLower(*p.McpServerName)]; !ok {
				out = append(out, &psmithv1.ImportWarning{
					Kind:    psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_MCP_SERVER_MISSING,
					Subject: *p.McpServerName,
					Message: fmt.Sprintf("Missing MCP server %q, so it was not attached. Register a server with that name and add it to the profile.", *p.McpServerName),
				})
			}
			continue
		}
		if !pluginapi.IsRegistered(p.PluginName) {
			out = append(out, &psmithv1.ImportWarning{
				Kind:    psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_PLUGIN_UNKNOWN,
				Subject: p.PluginName,
				Message: fmt.Sprintf("This server has no plugin called %q, so it was skipped.", p.PluginName),
			})
		}
	}

	// Sorted so the same bundle always reports in the same order; map
	// iteration above is not.
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].Message < out[j].Message
	})
	return out
}

// uniqueName suffixes on collision. Reports whether it had to.
func (r *importResolver) uniqueName(name string) (string, bool) {
	if !r.takenNames[strings.ToLower(name)] {
		return name, false
	}
	for n := 2; ; n++ {
		candidate := fmt.Sprintf("%s (%d)", name, n)
		if !r.takenNames[strings.ToLower(candidate)] {
			return candidate, true
		}
	}
}

func (r *importResolver) claimName(name string) { r.takenNames[strings.ToLower(name)] = true }

// renamesFor previews the rename outcome without mutating resolver state, so
// a dry run reports the same names a real import would assign.
func (r *importResolver) renamesFor(profiles []*psmithv1.BundledProfile) []string {
	taken := make(map[string]bool, len(r.takenNames))
	for k, v := range r.takenNames {
		taken[k] = v
	}
	preview := &importResolver{takenNames: taken}
	var out []string
	for _, bp := range profiles {
		name, did := preview.uniqueName(bp.Name)
		preview.claimName(name)
		if did {
			out = append(out, name)
		}
	}
	return out
}

func dedupeWarnings(in []*psmithv1.ImportWarning) []*psmithv1.ImportWarning {
	if len(in) == 0 {
		return nil
	}
	seen := map[string]bool{}
	out := make([]*psmithv1.ImportWarning, 0, len(in))
	for _, w := range in {
		key := fmt.Sprintf("%d\x00%s", w.Kind, w.Message)
		if !seen[key] {
			seen[key] = true
			out = append(out, w)
		}
	}
	return out
}
