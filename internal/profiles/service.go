package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/types/known/timestamppb"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/gen/clark/v1/clarkv1connect"
	"github.com/jdpedrie/clark/internal/auth"
	"github.com/jdpedrie/clark/internal/store"
	"github.com/jdpedrie/clark/plugins"
)

// Compression mode wire/storage constants. The DB CHECK constraint enforces
// these literal strings; the proto enum carries them on the wire.
const (
	compressionModeReplace = "REPLACE"
	compressionModeAppend  = "APPEND"
)

// Field names valid in UpdateProfileRequest.clear_fields. These match the
// proto field names so clients can use the same vocabulary they see in the
// request schema.
const (
	fieldSystemMessage       = "system_message"
	fieldDefaultUserMessage  = "default_user_message"
	fieldCompressionGuide    = "compression_guide"
	fieldCompressionMode     = "compression_mode"
	fieldCompressionProvider = "compression_provider_id"
	fieldCompressionModelID  = "compression_model_id"
	fieldDefaultSettings     = "default_settings"
	fieldTitleProvider       = "title_provider_id"
	fieldTitleModelID        = "title_model_id"
	fieldTitleGuide          = "title_guide"
	fieldTitleProviderKind   = "title_provider_kind"
	fieldDescription         = "description"
)

// TitleProviderKindAppleFoundation is the sentinel value of
// `profiles.title_provider_kind` that delegates title generation to the Mac
// client's on-device Apple FoundationModels framework. When a resolved
// profile carries this kind, the server's auto-title hook skips its cloud
// roundtrip — see internal/conversations/titles.go.
const TitleProviderKindAppleFoundation = "apple_foundation"

// validTitleProviderKinds enumerates the sentinel values the server is
// willing to accept on Create / Update. Other values are rejected with
// InvalidArgument so a typo doesn't silently disable auto-titling.
var validTitleProviderKinds = map[string]struct{}{
	TitleProviderKindAppleFoundation: {},
}

// Service implements clarkv1connect.ProfilesServiceHandler.
//
// pool is required for the SetProfilePlugins atomic-replace transaction.
// Older callers / tests that only exercise CRUD may pass nil.
type Service struct {
	clarkv1connect.UnimplementedProfilesServiceHandler
	queries *store.Queries
	pool    *pgxpool.Pool
}

// NewService builds a Service backed by the given query set. pool may be
// nil for tests that don't exercise SetProfilePlugins; production must
// pass a real pool so the atomic-replace TX has something to begin from.
func NewService(queries *store.Queries, pool *pgxpool.Pool) *Service {
	return &Service{queries: queries, pool: pool}
}

// --- CreateProfile ---

func (s *Service) CreateProfile(ctx context.Context, req *connect.Request[clarkv1.CreateProfileRequest]) (*connect.Response[clarkv1.CreateProfileResponse], error) {
	caller := auth.MustFromContext(ctx)

	if req.Msg.Name == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("name is required"))
	}

	var parentID *uuid.UUID
	if req.Msg.ParentProfileId != nil {
		pid, err := uuid.Parse(*req.Msg.ParentProfileId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid parent_profile_id: %w", err))
		}
		// Parent must exist and be owned by the same user.
		parent, err := s.queries.GetProfileByID(ctx, pid)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("parent_profile_id not found"))
			}
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if parent.UserID != caller.ID {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("parent_profile_id not owned by caller"))
		}
		parentID = &pid
	}

	var compressionProviderID *uuid.UUID
	if req.Msg.CompressionProviderId != nil {
		cid, err := uuid.Parse(*req.Msg.CompressionProviderId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid compression_provider_id: %w", err))
		}
		if err := s.assertProviderOwned(ctx, cid, caller.ID); err != nil {
			return nil, err
		}
		compressionProviderID = &cid
	}

	var compressionMode *string
	if req.Msg.CompressionMode != nil {
		m, err := compressionModeToString(*req.Msg.CompressionMode)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, err)
		}
		compressionMode = &m
	}

	defaultsJSON, err := defaultsToJSON(req.Msg.DefaultSettings)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	id, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	var titleProviderID *uuid.UUID
	if req.Msg.TitleProviderId != nil {
		tid, err := uuid.Parse(*req.Msg.TitleProviderId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid title_provider_id: %w", err))
		}
		if err := s.assertProviderOwned(ctx, tid, caller.ID); err != nil {
			return nil, err
		}
		titleProviderID = &tid
	}

	var titleProviderKind *string
	if req.Msg.TitleProviderKind != nil && *req.Msg.TitleProviderKind != "" {
		k := *req.Msg.TitleProviderKind
		if _, ok := validTitleProviderKinds[k]; !ok {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("unknown title_provider_kind: %q", k))
		}
		titleProviderKind = &k
	}

	row, err := s.queries.CreateProfile(ctx, store.CreateProfileParams{
		ID:                    id,
		UserID:                caller.ID,
		ParentProfileID:       parentID,
		Name:                  req.Msg.Name,
		SystemMessage:         req.Msg.SystemMessage,
		DefaultUserMessage:    req.Msg.DefaultUserMessage,
		CompressionGuide:      req.Msg.CompressionGuide,
		CompressionMode:       compressionMode,
		CompressionProviderID: compressionProviderID,
		CompressionModelID:    req.Msg.CompressionModelId,
		DefaultSettings:       defaultsJSON,
		TitleProviderID:       titleProviderID,
		TitleModelID:          req.Msg.TitleModelId,
		TitleGuide:            req.Msg.TitleGuide,
		TitleProviderKind:     titleProviderKind,
		Description:           req.Msg.Description,
		ParentOnly:            req.Msg.ParentOnly,
		Favorite:              req.Msg.Favorite,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	proto, err := profileToProto(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.CreateProfileResponse{Profile: proto}), nil
}

// --- ListProfiles ---

func (s *Service) ListProfiles(ctx context.Context, req *connect.Request[clarkv1.ListProfilesRequest]) (*connect.Response[clarkv1.ListProfilesResponse], error) {
	caller := auth.MustFromContext(ctx)

	rows, err := s.queries.ListProfilesByUser(ctx, caller.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	out := make([]*clarkv1.Profile, 0, len(rows))
	for _, r := range rows {
		p, err := profileToProto(r)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		out = append(out, p)
	}
	return connect.NewResponse(&clarkv1.ListProfilesResponse{Profiles: out}), nil
}

// --- GetProfile ---

func (s *Service) GetProfile(ctx context.Context, req *connect.Request[clarkv1.GetProfileRequest]) (*connect.Response[clarkv1.GetProfileResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}

	row, err := s.fetchOwned(ctx, id, caller.ID)
	if err != nil {
		return nil, err
	}

	proto, err := profileToProto(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	resp := &clarkv1.GetProfileResponse{Profile: proto}

	if req.Msg.Resolve {
		resolved, err := Resolve(ctx, s.queries, row)
		if err != nil {
			return nil, connect.NewError(connect.CodeFailedPrecondition, err)
		}
		rproto, err := profileToProto(resolved)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		resp.Resolved = rproto
	}

	return connect.NewResponse(resp), nil
}

// --- UpdateProfile ---

func (s *Service) UpdateProfile(ctx context.Context, req *connect.Request[clarkv1.UpdateProfileRequest]) (*connect.Response[clarkv1.UpdateProfileResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}

	if _, err := s.fetchOwned(ctx, id, caller.ID); err != nil {
		return nil, err
	}

	clear := make(map[string]struct{}, len(req.Msg.ClearFields))
	for _, f := range req.Msg.ClearFields {
		clear[f] = struct{}{}
	}

	// name is non-optional in the proto but we treat empty as "leave alone"
	// and non-empty as "update". (Empty would violate NOT NULL anyway.)
	if req.Msg.Name != nil && *req.Msg.Name != "" {
		if err := s.queries.UpdateProfileName(ctx, store.UpdateProfileNameParams{ID: id, Name: *req.Msg.Name}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// system_message
	if _, ok := clear[fieldSystemMessage]; ok {
		if err := s.queries.UpdateProfileSystemMessage(ctx, store.UpdateProfileSystemMessageParams{ID: id, SystemMessage: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.SystemMessage != nil {
		if err := s.queries.UpdateProfileSystemMessage(ctx, store.UpdateProfileSystemMessageParams{ID: id, SystemMessage: req.Msg.SystemMessage}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// default_user_message
	if _, ok := clear[fieldDefaultUserMessage]; ok {
		if err := s.queries.UpdateProfileDefaultUserMessage(ctx, store.UpdateProfileDefaultUserMessageParams{ID: id, DefaultUserMessage: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.DefaultUserMessage != nil {
		if err := s.queries.UpdateProfileDefaultUserMessage(ctx, store.UpdateProfileDefaultUserMessageParams{ID: id, DefaultUserMessage: req.Msg.DefaultUserMessage}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// compression_guide
	if _, ok := clear[fieldCompressionGuide]; ok {
		if err := s.queries.UpdateProfileCompressionGuide(ctx, store.UpdateProfileCompressionGuideParams{ID: id, CompressionGuide: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.CompressionGuide != nil {
		if err := s.queries.UpdateProfileCompressionGuide(ctx, store.UpdateProfileCompressionGuideParams{ID: id, CompressionGuide: req.Msg.CompressionGuide}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// compression_mode
	if _, ok := clear[fieldCompressionMode]; ok {
		if err := s.queries.UpdateProfileCompressionMode(ctx, store.UpdateProfileCompressionModeParams{ID: id, CompressionMode: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.CompressionMode != nil {
		m, err := compressionModeToString(*req.Msg.CompressionMode)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, err)
		}
		if err := s.queries.UpdateProfileCompressionMode(ctx, store.UpdateProfileCompressionModeParams{ID: id, CompressionMode: &m}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// compression_provider_id
	if _, ok := clear[fieldCompressionProvider]; ok {
		if err := s.queries.UpdateProfileCompressionProviderID(ctx, store.UpdateProfileCompressionProviderIDParams{ID: id, CompressionProviderID: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.CompressionProviderId != nil {
		cid, err := uuid.Parse(*req.Msg.CompressionProviderId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid compression_provider_id: %w", err))
		}
		if err := s.assertProviderOwned(ctx, cid, caller.ID); err != nil {
			return nil, err
		}
		if err := s.queries.UpdateProfileCompressionProviderID(ctx, store.UpdateProfileCompressionProviderIDParams{ID: id, CompressionProviderID: &cid}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// compression_model_id
	if _, ok := clear[fieldCompressionModelID]; ok {
		if err := s.queries.UpdateProfileCompressionModelID(ctx, store.UpdateProfileCompressionModelIDParams{ID: id, CompressionModelID: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.CompressionModelId != nil {
		if err := s.queries.UpdateProfileCompressionModelID(ctx, store.UpdateProfileCompressionModelIDParams{ID: id, CompressionModelID: req.Msg.CompressionModelId}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// default_settings
	if _, ok := clear[fieldDefaultSettings]; ok {
		if err := s.queries.UpdateProfileDefaultSettings(ctx, store.UpdateProfileDefaultSettingsParams{ID: id, DefaultSettings: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.DefaultSettings != nil {
		blob, err := defaultsToJSON(req.Msg.DefaultSettings)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if err := s.queries.UpdateProfileDefaultSettings(ctx, store.UpdateProfileDefaultSettingsParams{ID: id, DefaultSettings: blob}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// title_provider_id
	if _, ok := clear[fieldTitleProvider]; ok {
		if err := s.queries.UpdateProfileTitleProviderID(ctx, store.UpdateProfileTitleProviderIDParams{ID: id, TitleProviderID: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.TitleProviderId != nil {
		tid, err := uuid.Parse(*req.Msg.TitleProviderId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid title_provider_id: %w", err))
		}
		if err := s.assertProviderOwned(ctx, tid, caller.ID); err != nil {
			return nil, err
		}
		if err := s.queries.UpdateProfileTitleProviderID(ctx, store.UpdateProfileTitleProviderIDParams{ID: id, TitleProviderID: &tid}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// title_model_id
	if _, ok := clear[fieldTitleModelID]; ok {
		if err := s.queries.UpdateProfileTitleModelID(ctx, store.UpdateProfileTitleModelIDParams{ID: id, TitleModelID: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.TitleModelId != nil {
		if err := s.queries.UpdateProfileTitleModelID(ctx, store.UpdateProfileTitleModelIDParams{ID: id, TitleModelID: req.Msg.TitleModelId}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// title_guide
	if _, ok := clear[fieldTitleGuide]; ok {
		if err := s.queries.UpdateProfileTitleGuide(ctx, store.UpdateProfileTitleGuideParams{ID: id, TitleGuide: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.TitleGuide != nil {
		if err := s.queries.UpdateProfileTitleGuide(ctx, store.UpdateProfileTitleGuideParams{ID: id, TitleGuide: req.Msg.TitleGuide}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// title_provider_kind — sentinel for non-server title generation (e.g.
	// "apple_foundation"). Validated against a known-values whitelist.
	if _, ok := clear[fieldTitleProviderKind]; ok {
		if err := s.queries.UpdateProfileTitleProviderKind(ctx, store.UpdateProfileTitleProviderKindParams{ID: id, TitleProviderKind: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.TitleProviderKind != nil {
		k := *req.Msg.TitleProviderKind
		if k == "" {
			// Empty-string convention: same as listing the field in clear_fields.
			if err := s.queries.UpdateProfileTitleProviderKind(ctx, store.UpdateProfileTitleProviderKindParams{ID: id, TitleProviderKind: nil}); err != nil {
				return nil, connect.NewError(connect.CodeInternal, err)
			}
		} else {
			if _, ok := validTitleProviderKinds[k]; !ok {
				return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("unknown title_provider_kind: %q", k))
			}
			if err := s.queries.UpdateProfileTitleProviderKind(ctx, store.UpdateProfileTitleProviderKindParams{ID: id, TitleProviderKind: &k}); err != nil {
				return nil, connect.NewError(connect.CodeInternal, err)
			}
		}
	}

	// description (non-nullable on the row, "clear" maps to empty string)
	if _, ok := clear[fieldDescription]; ok {
		if err := s.queries.UpdateProfileDescription(ctx, store.UpdateProfileDescriptionParams{ID: id, Description: ""}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.Description != nil {
		if err := s.queries.UpdateProfileDescription(ctx, store.UpdateProfileDescriptionParams{ID: id, Description: *req.Msg.Description}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// parent_only — has no "clear" semantic since it's a bool with a defined
	// default; missing in the request just means "leave unchanged."
	if req.Msg.ParentOnly != nil {
		if err := s.queries.UpdateProfileParentOnly(ctx, store.UpdateProfileParentOnlyParams{ID: id, ParentOnly: *req.Msg.ParentOnly}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// favorite — same shape as parent_only.
	if req.Msg.Favorite != nil {
		if err := s.queries.UpdateProfileFavorite(ctx, store.UpdateProfileFavoriteParams{ID: id, Favorite: *req.Msg.Favorite}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// Re-read.
	updated, err := s.queries.GetProfileByID(ctx, id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	proto, err := profileToProto(updated)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.UpdateProfileResponse{Profile: proto}), nil
}

// --- DeleteProfile ---

func (s *Service) DeleteProfile(ctx context.Context, req *connect.Request[clarkv1.DeleteProfileRequest]) (*connect.Response[clarkv1.DeleteProfileResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}

	if _, err := s.fetchOwned(ctx, id, caller.ID); err != nil {
		return nil, err
	}

	if err := s.queries.DeleteProfile(ctx, id); err != nil {
		// If FK enforcement (e.g. from child profiles or conversations)
		// blocks the delete, surface that as FailedPrecondition rather than
		// Internal so the client can reason about it.
		if isFKViolation(err) {
			return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("profile has dependent rows"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.DeleteProfileResponse{}), nil
}

// --- ListPluginTypes ---

// ListPluginTypes returns metadata for every plugin type compiled into the
// server. The set is fixed at build time (registered in init()); the proto
// shape mirrors plugins.TypeDescriptor with a flat capabilities sub-message.
func (s *Service) ListPluginTypes(ctx context.Context, _ *connect.Request[clarkv1.ListPluginTypesRequest]) (*connect.Response[clarkv1.ListPluginTypesResponse], error) {
	descs, err := plugins.DescribeAll()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("describe plugins: %w", err))
	}
	out := make([]*clarkv1.PluginType, 0, len(descs))
	for _, d := range descs {
		out = append(out, pluginTypeToProto(d))
	}
	return connect.NewResponse(&clarkv1.ListPluginTypesResponse{PluginTypes: out}), nil
}

// --- GetProfilePlugins ---

// GetProfilePlugins returns the plugin pipeline attached to ONE profile (no
// parent-chain walk). Empty list = "inherit from parent" per the
// architecture's all-or-nothing inheritance rule.
func (s *Service) GetProfilePlugins(ctx context.Context, req *connect.Request[clarkv1.GetProfilePluginsRequest]) (*connect.Response[clarkv1.GetProfilePluginsResponse], error) {
	caller := auth.MustFromContext(ctx)
	profileID, err := uuid.Parse(req.Msg.ProfileId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid profile_id: %w", err))
	}
	if _, err := s.fetchOwned(ctx, profileID, caller.ID); err != nil {
		return nil, err
	}
	rows, err := s.queries.ListProfilePlugins(ctx, profileID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*clarkv1.ProfilePlugin, 0, len(rows))
	for _, r := range rows {
		out = append(out, &clarkv1.ProfilePlugin{
			PluginName: r.PluginName,
			Ordinal:    r.Ordinal,
			Config:     r.Config,
		})
	}
	return connect.NewResponse(&clarkv1.GetProfilePluginsResponse{Plugins: out}), nil
}

// --- SetProfilePlugins ---

// SetProfilePlugins atomically replaces a profile's plugin pipeline with the
// supplied list. Each plugin's name + config is validated by attempting to
// construct it (via plugins.Build) BEFORE any DB write — an unknown plugin
// or malformed config aborts the request without touching the existing
// pipeline. The replace itself runs in a transaction (delete-then-insert)
// so concurrent reads either see the old or the new full pipeline.
func (s *Service) SetProfilePlugins(ctx context.Context, req *connect.Request[clarkv1.SetProfilePluginsRequest]) (*connect.Response[clarkv1.SetProfilePluginsResponse], error) {
	if s.pool == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("SetProfilePlugins requires pool dependency"))
	}
	caller := auth.MustFromContext(ctx)
	profileID, err := uuid.Parse(req.Msg.ProfileId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid profile_id: %w", err))
	}
	if _, err := s.fetchOwned(ctx, profileID, caller.ID); err != nil {
		return nil, err
	}

	// Pre-validate every entry before opening a transaction. We construct
	// each plugin with its proposed config so unknown-name and bad-config
	// errors surface as InvalidArgument instead of being silently persisted.
	for i, p := range req.Msg.Plugins {
		if p.PluginName == "" {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("plugins[%d]: empty plugin_name", i))
		}
		if _, err := plugins.Build(p.PluginName, p.Config); err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("plugins[%d] (%s): %w", i, p.PluginName, err))
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	qtx := s.queries.WithTx(tx)

	if err := qtx.ReplaceProfilePlugins(ctx, profileID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("clear existing plugins: %w", err))
	}
	out := make([]*clarkv1.ProfilePlugin, 0, len(req.Msg.Plugins))
	for i, p := range req.Msg.Plugins {
		row, err := qtx.InsertProfilePlugin(ctx, store.InsertProfilePluginParams{
			ProfileID:  profileID,
			Ordinal:    int32(i),
			PluginName: p.PluginName,
			Config:     p.Config,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("insert plugins[%d]: %w", i, err))
		}
		out = append(out, &clarkv1.ProfilePlugin{
			PluginName: row.PluginName,
			Ordinal:    row.Ordinal,
			Config:     row.Config,
		})
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}
	return connect.NewResponse(&clarkv1.SetProfilePluginsResponse{Plugins: out}), nil
}

// pluginTypeToProto converts a plugins.TypeDescriptor to its proto shape.
func pluginTypeToProto(d plugins.TypeDescriptor) *clarkv1.PluginType {
	fields := make([]*clarkv1.ConfigField, 0, len(d.ConfigFields))
	for _, f := range d.ConfigFields {
		fields = append(fields, configFieldToProto(f))
	}
	return &clarkv1.PluginType{
		Name:         d.Name,
		Description:  d.Description,
		ConfigFields: fields,
		Capabilities: &clarkv1.PluginCapabilities{
			Configurable:            d.Capabilities.Configurable,
			SystemPrompter:          d.Capabilities.SystemPrompter,
			OutgoingUserTransformer: d.Capabilities.OutgoingUserTransformer,
			HistoryTransformer:      d.Capabilities.HistoryTransformer,
			ChunkTransformer:        d.Capabilities.ChunkTransformer,
			DisplayTransformer:      d.Capabilities.DisplayTransformer,
			ToolProvider:            d.Capabilities.ToolProvider,
		},
	}
}

// configFieldToProto converts one plugins.ConfigField to its proto shape.
// The Default is JSON-marshaled into default_json; nil becomes the empty
// string (which the wire treats as "no default"). Unknown field types map
// to TYPE_UNSPECIFIED so a malformed plugin descriptor surfaces as an
// explicit zero-value rather than getting silently coerced.
func configFieldToProto(f plugins.ConfigField) *clarkv1.ConfigField {
	out := &clarkv1.ConfigField{
		Name:        f.Name,
		Display:     f.Display,
		Description: f.Description,
		Type:        configFieldTypeToProto(f.Type),
	}
	if f.Default != nil {
		// json.Marshal on a typed value (int, string, bool) is total — the
		// only way it errors is on unsupported kinds (channels, funcs), which
		// shouldn't appear in a config-field default. If somehow it does, we
		// fall back to empty so the UI gets "no default" instead of crashing.
		if raw, err := json.Marshal(f.Default); err == nil {
			out.DefaultJson = string(raw)
		}
	}
	if len(f.Options) > 0 {
		opts := make([]*clarkv1.ConfigOption, 0, len(f.Options))
		for _, o := range f.Options {
			opts = append(opts, &clarkv1.ConfigOption{Value: o.Value, Label: o.Label})
		}
		out.Options = opts
	}
	return out
}

func configFieldTypeToProto(t plugins.ConfigFieldType) clarkv1.ConfigField_Type {
	switch t {
	case plugins.ConfigFieldNumber:
		return clarkv1.ConfigField_NUMBER
	case plugins.ConfigFieldText:
		return clarkv1.ConfigField_TEXT
	case plugins.ConfigFieldTextarea:
		return clarkv1.ConfigField_TEXTAREA
	case plugins.ConfigFieldBoolean:
		return clarkv1.ConfigField_BOOLEAN
	case plugins.ConfigFieldSelect:
		return clarkv1.ConfigField_SELECT
	default:
		return clarkv1.ConfigField_TYPE_UNSPECIFIED
	}
}

// --- helpers ---

// fetchOwned loads a profile by id and asserts ownership by the caller.
// Returns NotFound if the row doesn't exist OR is owned by another user;
// indistinguishable from the caller's perspective is the desired behavior
// (don't leak existence of others' resources).
func (s *Service) fetchOwned(ctx context.Context, id, userID uuid.UUID) (store.Profile, error) {
	row, err := s.queries.GetProfileByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return store.Profile{}, connect.NewError(connect.CodeNotFound, errors.New("profile not found"))
		}
		return store.Profile{}, connect.NewError(connect.CodeInternal, err)
	}
	if row.UserID != userID {
		return store.Profile{}, connect.NewError(connect.CodeNotFound, errors.New("profile not found"))
	}
	return row, nil
}

// assertProviderOwned validates that the given provider exists and belongs to
// the caller. Returns InvalidArgument otherwise (this is called during
// Create/Update where the provider id is user-supplied input).
func (s *Service) assertProviderOwned(ctx context.Context, providerID, userID uuid.UUID) error {
	p, err := s.queries.GetUserModelProvider(ctx, providerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return connect.NewError(connect.CodeInvalidArgument, errors.New("compression_provider_id not found"))
		}
		return connect.NewError(connect.CodeInternal, err)
	}
	if p.UserID != userID {
		return connect.NewError(connect.CodeInvalidArgument, errors.New("compression_provider_id not owned by caller"))
	}
	return nil
}

func compressionModeToString(m clarkv1.CompressionMode) (string, error) {
	switch m {
	case clarkv1.CompressionMode_COMPRESSION_MODE_REPLACE:
		return compressionModeReplace, nil
	case clarkv1.CompressionMode_COMPRESSION_MODE_APPEND:
		return compressionModeAppend, nil
	case clarkv1.CompressionMode_COMPRESSION_MODE_UNSPECIFIED:
		return "", errors.New("compression_mode is unspecified")
	default:
		return "", fmt.Errorf("unknown compression_mode: %v", m)
	}
}

func compressionModeFromString(s string) clarkv1.CompressionMode {
	switch s {
	case compressionModeReplace:
		return clarkv1.CompressionMode_COMPRESSION_MODE_REPLACE
	case compressionModeAppend:
		return clarkv1.CompressionMode_COMPRESSION_MODE_APPEND
	default:
		return clarkv1.CompressionMode_COMPRESSION_MODE_UNSPECIFIED
	}
}

// defaultsToJSON marshals a ProfileDefaults message to a JSON blob suitable
// for the JSONB column. Returns nil for a nil input (so the column stays NULL).
func defaultsToJSON(d *clarkv1.ProfileDefaults) ([]byte, error) {
	if d == nil {
		return nil, nil
	}
	// Storage shape: a small struct with the same field names as the proto.
	// Round-trips through defaultsFromJSON.
	out := defaultsStorage{
		DefaultProviderID:        d.DefaultProviderId,
		DefaultModelID:           d.DefaultModelId,
		IncludeThinkingInHistory: d.IncludeThinkingInHistory,
	}
	if d.CallSettings != nil {
		raw, err := MarshalCallSettings(d.CallSettings)
		if err != nil {
			return nil, fmt.Errorf("encode call_settings: %w", err)
		}
		out.CallSettings = raw
	}
	return json.Marshal(out)
}

// defaultsFromJSON unmarshals a JSONB blob back into a ProfileDefaults message.
// Returns nil for empty input.
func defaultsFromJSON(b []byte) (*clarkv1.ProfileDefaults, error) {
	if len(b) == 0 {
		return nil, nil
	}
	var s defaultsStorage
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("decode default_settings: %w", err)
	}
	out := &clarkv1.ProfileDefaults{
		DefaultProviderId:        s.DefaultProviderID,
		DefaultModelId:           s.DefaultModelID,
		IncludeThinkingInHistory: s.IncludeThinkingInHistory,
	}
	if len(s.CallSettings) > 0 {
		cs, err := UnmarshalCallSettings(s.CallSettings)
		if err != nil {
			return nil, fmt.Errorf("decode call_settings: %w", err)
		}
		out.CallSettings = cs
	}
	return out, nil
}

type defaultsStorage struct {
	DefaultProviderID        *string         `json:"default_provider_id,omitempty"`
	DefaultModelID           *string         `json:"default_model_id,omitempty"`
	IncludeThinkingInHistory *bool           `json:"include_thinking_in_history,omitempty"`
	CallSettings             json.RawMessage `json:"call_settings,omitempty"`
}

func profileToProto(p store.Profile) (*clarkv1.Profile, error) {
	defaults, err := defaultsFromJSON(p.DefaultSettings)
	if err != nil {
		return nil, err
	}
	out := &clarkv1.Profile{
		Id:                 p.ID.String(),
		Name:               p.Name,
		SystemMessage:      p.SystemMessage,
		DefaultUserMessage: p.DefaultUserMessage,
		CompressionGuide:   p.CompressionGuide,
		CompressionModelId: p.CompressionModelID,
		DefaultSettings:    defaults,
		OwnerUserId:        p.UserID.String(),
		CreatedAt:          timestamppb.New(p.CreatedAt),
		UpdatedAt:          timestamppb.New(p.UpdatedAt),
		Description:        p.Description,
		ParentOnly:         p.ParentOnly,
		Favorite:           p.Favorite,
	}
	if p.ParentProfileID != nil {
		s := p.ParentProfileID.String()
		out.ParentProfileId = &s
	}
	if p.CompressionProviderID != nil {
		s := p.CompressionProviderID.String()
		out.CompressionProviderId = &s
	}
	if p.CompressionMode != nil {
		m := compressionModeFromString(*p.CompressionMode)
		out.CompressionMode = &m
	}
	if p.TitleProviderID != nil {
		s := p.TitleProviderID.String()
		out.TitleProviderId = &s
	}
	out.TitleModelId = p.TitleModelID
	out.TitleGuide = p.TitleGuide
	out.TitleProviderKind = p.TitleProviderKind
	return out, nil
}

// isFKViolation returns true if err is a Postgres foreign-key violation.
// We avoid pulling in a *pgconn.PgError dependency here by string-matching
// the SQLSTATE in the wrapped error chain.
func isFKViolation(err error) bool {
	if err == nil {
		return false
	}
	type sqlStater interface{ SQLState() string }
	var ss sqlStater
	if errors.As(err, &ss) {
		return ss.SQLState() == "23503"
	}
	return false
}
