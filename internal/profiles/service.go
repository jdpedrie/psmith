package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/gen/psmith/v1/psmithv1connect"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/events"
	"github.com/jdpedrie/psmith/internal/pagetoken"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
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
	fieldWelcomeMessage      = "welcome_message"
	fieldParentProfileID     = "parent_profile_id"
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

// Service implements psmithv1connect.ProfilesServiceHandler.
//
// pool is required for the SetProfilePlugins atomic-replace transaction.
// Older callers / tests that only exercise CRUD may pass nil.
//
// cipher seals plugin config blobs (profile_plugins.config_encrypted,
// user_plugin_settings.config_encrypted) at write time and unseals
// them on the read paths that hand bytes to plugin constructors. Pass
// crypto.Nop{} to opt out of encryption (tests + deployments without
// PSMITH_MASTER_KEY).
type Service struct {
	psmithv1connect.UnimplementedProfilesServiceHandler
	queries *store.Queries
	pool    *pgxpool.Pool
	cipher  crypto.Cipher
	bus     *events.Bus
}

// NewService builds a Service backed by the given query set. pool may be
// nil for tests that don't exercise SetProfilePlugins; production must
// pass a real pool so the atomic-replace TX has something to begin from.
// cipher must be non-nil; pass crypto.Nop{} when running unencrypted.
// bus may be nil — when set, profile mutations publish ProfileChanged
// events for subscribed clients (cross-client live update).
func NewService(queries *store.Queries, pool *pgxpool.Pool, cipher crypto.Cipher) *Service {
	if cipher == nil {
		cipher = crypto.Nop{}
	}
	return &Service{queries: queries, pool: pool, cipher: cipher}
}

// WithBus returns the service with the event bus wired in. Optional
// — the bus is only used to publish profile-mutation events, and
// existing callers (tests, fixtures) keep working with no bus.
func (s *Service) WithBus(bus *events.Bus) *Service {
	s.bus = bus
	return s
}

// publishProfileEvent is the single point that fires profile events
// onto the bus. Centralised so the call sites stay one-liners and so
// adding new mutation paths doesn't risk forgetting to publish.
func (s *Service) publishProfileEvent(userID, profileID uuid.UUID, kind events.ProfileChangeKind) {
	if s.bus == nil {
		return
	}
	s.bus.Publish(events.Event{
		Type:   events.ProfileChanged,
		UserID: userID,
		Profile: events.ProfilePayload{
			ProfileID: profileID,
			Kind:      kind,
		},
	})
}

// --- CreateProfile ---

func (s *Service) CreateProfile(ctx context.Context, req *connect.Request[psmithv1.CreateProfileRequest]) (*connect.Response[psmithv1.CreateProfileResponse], error) {
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
		WelcomeMessage:        req.Msg.WelcomeMessage,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	proto, err := profileToProto(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	s.attachRequiredCaps(ctx, proto)
	s.publishProfileEvent(caller.ID, id, events.ProfileChangeCreated)
	return connect.NewResponse(&psmithv1.CreateProfileResponse{Profile: proto}), nil
}

// --- ListProfiles ---

// MaxProfilePageSize caps page_size in ListProfiles. page_size = 0 keeps
// the legacy return-everything behavior — existing clients treat the
// profile list as a complete lookup table (parent-chain resolution,
// pickers), so paging is strictly opt-in.
const MaxProfilePageSize = 100

func (s *Service) ListProfiles(ctx context.Context, req *connect.Request[psmithv1.ListProfilesRequest]) (*connect.Response[psmithv1.ListProfilesResponse], error) {
	caller := auth.MustFromContext(ctx)

	var rows []store.Profile
	nextPageToken := ""
	if req.Msg.GetPageSize() <= 0 {
		all, err := s.queries.ListProfilesByUser(ctx, caller.ID)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		rows = all
	} else {
		limit := int(req.Msg.GetPageSize())
		if limit > MaxProfilePageSize {
			limit = MaxProfilePageSize
		}
		var cursorKey *time.Time
		var cursorID *uuid.UUID
		if key, id, ok, err := pagetoken.Decode(req.Msg.GetPageToken()); err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid page_token: %w", err))
		} else if ok {
			cursorKey, cursorID = &key, &id
		}
		paged, err := s.queries.ListProfilesByUserPaged(ctx, store.ListProfilesByUserPagedParams{
			UserID:    caller.ID,
			CursorKey: cursorKey,
			CursorID:  cursorID,
			PageLimit: int32(limit + 1),
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if len(paged) > limit {
			paged = paged[:limit]
			last := paged[len(paged)-1]
			nextPageToken = pagetoken.Encode(last.CreatedAt, last.ID)
		}
		rows = paged
	}

	out := make([]*psmithv1.Profile, 0, len(rows))
	for _, r := range rows {
		p, err := profileToProto(r)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		s.attachRequiredCaps(ctx, p)
		out = append(out, p)
	}
	return connect.NewResponse(&psmithv1.ListProfilesResponse{
		Profiles:      out,
		NextPageToken: nextPageToken,
	}), nil
}

// --- GetProfile ---

func (s *Service) GetProfile(ctx context.Context, req *connect.Request[psmithv1.GetProfileRequest]) (*connect.Response[psmithv1.GetProfileResponse], error) {
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
	s.attachRequiredCaps(ctx, proto)

	resp := &psmithv1.GetProfileResponse{Profile: proto}

	if req.Msg.Resolve {
		resolved, err := Resolve(ctx, s.queries, row)
		if err != nil {
			return nil, connect.NewError(connect.CodeFailedPrecondition, err)
		}
		rproto, err := profileToProto(resolved)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		s.attachRequiredCaps(ctx, rproto)
		resp.Resolved = rproto
	}

	return connect.NewResponse(resp), nil
}

// --- UpdateProfile ---

func (s *Service) UpdateProfile(ctx context.Context, req *connect.Request[psmithv1.UpdateProfileRequest]) (*connect.Response[psmithv1.UpdateProfileResponse], error) {
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

	// welcome_message
	if _, ok := clear[fieldWelcomeMessage]; ok {
		if err := s.queries.UpdateProfileWelcomeMessage(ctx, store.UpdateProfileWelcomeMessageParams{ID: id, WelcomeMessage: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.WelcomeMessage != nil {
		if err := s.queries.UpdateProfileWelcomeMessage(ctx, store.UpdateProfileWelcomeMessageParams{ID: id, WelcomeMessage: req.Msg.WelcomeMessage}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	// parent_profile_id
	if _, ok := clear[fieldParentProfileID]; ok {
		if err := s.queries.UpdateProfileParentProfileID(ctx, store.UpdateProfileParentProfileIDParams{ID: id, ParentProfileID: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.ParentProfileId != nil {
		pid, err := uuid.Parse(*req.Msg.ParentProfileId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid parent_profile_id: %w", err))
		}
		if pid == id {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("parent_profile_id cannot reference self"))
		}
		// Parent must exist and be owned by the caller. Surface NotFound
		// for cross-user attempts so we don't leak existence; the form
		// only shows the user's own profiles anyway, so a parse-and-
		// resolve here is purely defensive.
		if _, err := s.fetchOwned(ctx, pid, caller.ID); err != nil {
			return nil, err
		}
		// Cycle check — walk up the prospective parent's chain and
		// reject if we'd loop back through this profile. The existing
		// resolvers all have runtime cycle guards, but accepting bad
		// data here would silently cap inherited fields on every
		// downstream lookup.
		if cycles, err := s.parentChainContains(ctx, pid, id); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		} else if cycles {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("parent_profile_id would create a cycle"))
		}
		if err := s.queries.UpdateProfileParentProfileID(ctx, store.UpdateProfileParentProfileIDParams{ID: id, ParentProfileID: &pid}); err != nil {
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
	s.attachRequiredCaps(ctx, proto)
	s.publishProfileEvent(caller.ID, id, events.ProfileChangeUpdated)
	return connect.NewResponse(&psmithv1.UpdateProfileResponse{Profile: proto}), nil
}

// --- DeleteProfile ---

func (s *Service) DeleteProfile(ctx context.Context, req *connect.Request[psmithv1.DeleteProfileRequest]) (*connect.Response[psmithv1.DeleteProfileResponse], error) {
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
	s.publishProfileEvent(caller.ID, id, events.ProfileChangeDeleted)
	return connect.NewResponse(&psmithv1.DeleteProfileResponse{}), nil
}

// SetDefaultProfile marks one profile as the caller's default (clearing
// any previous one atomically) or clears the default when profile_id is
// empty. The partial unique index on profiles(user_id) WHERE is_default
// backstops the single-statement update.
func (s *Service) SetDefaultProfile(ctx context.Context, req *connect.Request[psmithv1.SetDefaultProfileRequest]) (*connect.Response[psmithv1.SetDefaultProfileResponse], error) {
	caller := auth.MustFromContext(ctx)

	var target *uuid.UUID
	if req.Msg.GetProfileId() != "" {
		id, err := uuid.Parse(req.Msg.GetProfileId())
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid profile_id: %w", err))
		}
		row, err := s.queries.GetProfileByID(ctx, id)
		if err != nil || row.UserID != caller.ID {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("profile not found"))
		}
		// A parent-only profile is a template, not a chat persona; it
		// can't be the default target for new conversations.
		if row.ParentOnly {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("a parent-only profile cannot be the default"))
		}
		target = &id
	}
	// Clear-then-mark inside one transaction: the partial unique index
	// is checked per row, so the old default must be off before the new
	// one goes on, and the pair must be atomic so a crash between them
	// can't leave the user defaultless when they asked for a switch.
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	qtx := s.queries.WithTx(tx)
	if err := qtx.ClearDefaultProfile(ctx, caller.ID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if target != nil {
		if err := qtx.MarkDefaultProfile(ctx, *target); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.SetDefaultProfileResponse{}), nil
}

// --- ListPluginTypes ---

// ListPluginTypes returns metadata for every plugin type compiled into the
// server. The set is fixed at build time (registered in init()); the proto
// shape mirrors plugins.TypeDescriptor with a flat capabilities sub-message.
func (s *Service) ListPluginTypes(ctx context.Context, _ *connect.Request[psmithv1.ListPluginTypesRequest]) (*connect.Response[psmithv1.ListPluginTypesResponse], error) {
	descs, err := plugins.DescribeAll()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("describe plugins: %w", err))
	}
	out := make([]*psmithv1.PluginType, 0, len(descs))
	for _, d := range descs {
		out = append(out, pluginTypeToProto(d))
	}
	return connect.NewResponse(&psmithv1.ListPluginTypesResponse{PluginTypes: out}), nil
}

// --- GetProfilePlugins ---

// GetProfilePlugins returns the plugin pipeline attached to ONE profile (no
// parent-chain walk). Empty list = "inherit from parent" per the
// architecture's all-or-nothing inheritance rule.
func (s *Service) GetProfilePlugins(ctx context.Context, req *connect.Request[psmithv1.GetProfilePluginsRequest]) (*connect.Response[psmithv1.GetProfilePluginsResponse], error) {
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
	out := make([]*psmithv1.ProfilePlugin, 0, len(rows))
	for i, r := range rows {
		// Decrypt the encrypted column when present; fall back to the
		// legacy plaintext column for rows written before the
		// encryption rollover. Without this the response returned the
		// raw plaintext column unconditionally — which is NULL for
		// every row written after the rollover, so the iOS / Mac
		// settings form re-opened blank after every save.
		cfg, err := crypto.ResolveSecret(s.cipher, r.ConfigEncrypted, r.Config)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("decrypt plugins[%d] config: %w", i, err))
		}
		out = append(out, &psmithv1.ProfilePlugin{
			PluginName: r.PluginName,
			Ordinal:    r.Ordinal,
			Config:     cfg,
			Disabled:   r.Disabled,
		})
	}
	return connect.NewResponse(&psmithv1.GetProfilePluginsResponse{Plugins: out}), nil
}

// --- SetProfilePlugins ---

// SetProfilePlugins atomically replaces a profile's plugin pipeline with the
// supplied list. Each plugin's name + config is validated by attempting to
// construct it (via plugins.Build) BEFORE any DB write — an unknown plugin
// or malformed config aborts the request without touching the existing
// pipeline. The replace itself runs in a transaction (delete-then-insert)
// so concurrent reads either see the old or the new full pipeline.
func (s *Service) SetProfilePlugins(ctx context.Context, req *connect.Request[psmithv1.SetProfilePluginsRequest]) (*connect.Response[psmithv1.SetProfilePluginsResponse], error) {
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
	out := make([]*psmithv1.ProfilePlugin, 0, len(req.Msg.Plugins))
	for i, p := range req.Msg.Plugins {
		// Encrypt the per-profile plugin config blob before persisting.
		// Reads in conversations/service.go (plugin pipeline build) go
		// through resolvePluginConfig, which decrypts via the same
		// cipher and falls back to the legacy plaintext column for
		// rows that haven't been re-saved since the rollover.
		var encrypted []byte
		if p.Config != nil {
			encrypted, err = s.cipher.Encrypt(p.Config)
			if err != nil {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encrypt plugins[%d] config: %w", i, err))
			}
		}
		row, err := qtx.InsertProfilePlugin(ctx, store.InsertProfilePluginParams{
			ProfileID:       profileID,
			Ordinal:         int32(i),
			PluginName:      p.PluginName,
			ConfigEncrypted: encrypted,
			Disabled:        p.Disabled,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("insert plugins[%d]: %w", i, err))
		}
		// Echo the plaintext config the caller sent — the proto
		// response is informational and shouldn't make the client
		// re-issue a Get to see the current shape.
		out = append(out, &psmithv1.ProfilePlugin{
			PluginName: row.PluginName,
			Ordinal:    row.Ordinal,
			Config:     p.Config,
			Disabled:   row.Disabled,
		})
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}
	return connect.NewResponse(&psmithv1.SetProfilePluginsResponse{Plugins: out}), nil
}

// --- User-scoped plugin settings (`Global` config fields) -------------------

// GetUserPluginSettings returns the calling user's stored global config
// blob for one plugin. Missing row → empty config (`{}`); the UI seeds
// the form with field defaults from the plugin descriptor.
func (s *Service) GetUserPluginSettings(ctx context.Context, req *connect.Request[psmithv1.GetUserPluginSettingsRequest]) (*connect.Response[psmithv1.GetUserPluginSettingsResponse], error) {
	caller := auth.MustFromContext(ctx)
	name := req.Msg.PluginName
	if name == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("plugin_name is required"))
	}
	row, err := s.queries.GetUserPluginSettings(ctx, store.GetUserPluginSettingsParams{
		UserID:     caller.ID,
		PluginName: name,
	})
	settings := &psmithv1.UserPluginSettings{PluginName: name, Config: []byte("{}")}
	if err == nil {
		cfg, decryptErr := crypto.ResolveSecret(s.cipher, row.ConfigEncrypted, row.Config)
		if decryptErr != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("decrypt plugin settings: %w", decryptErr))
		}
		if len(cfg) > 0 {
			settings.Config = cfg
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.GetUserPluginSettingsResponse{Settings: settings}), nil
}

// ListUserPluginSettings returns every plugin the calling user has
// stored a global config for. Plugins not in the list are "not yet
// configured globally"; merging treats absence as an empty object.
func (s *Service) ListUserPluginSettings(ctx context.Context, req *connect.Request[psmithv1.ListUserPluginSettingsRequest]) (*connect.Response[psmithv1.ListUserPluginSettingsResponse], error) {
	caller := auth.MustFromContext(ctx)
	rows, err := s.queries.ListUserPluginSettings(ctx, caller.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*psmithv1.UserPluginSettings, 0, len(rows))
	for _, r := range rows {
		cfg, decryptErr := crypto.ResolveSecret(s.cipher, r.ConfigEncrypted, r.Config)
		if decryptErr != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("decrypt plugin settings %q: %w", r.PluginName, decryptErr))
		}
		out = append(out, &psmithv1.UserPluginSettings{
			PluginName: r.PluginName,
			Config:     cfg,
		})
	}
	return connect.NewResponse(&psmithv1.ListUserPluginSettingsResponse{Settings: out}), nil
}

// UpsertUserPluginSettings replaces the calling user's global config blob
// for one plugin. Validates by attempting to construct the plugin with the
// supplied (global-only) config — same pre-write check as
// SetProfilePlugins, so a malformed JSON or unknown plugin name surfaces
// as InvalidArgument before any DB write.
func (s *Service) UpsertUserPluginSettings(ctx context.Context, req *connect.Request[psmithv1.UpsertUserPluginSettingsRequest]) (*connect.Response[psmithv1.UpsertUserPluginSettingsResponse], error) {
	caller := auth.MustFromContext(ctx)
	name := req.Msg.PluginName
	if name == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("plugin_name is required"))
	}
	cfg := req.Msg.Config
	if len(cfg) == 0 {
		cfg = []byte("{}")
	}
	if _, err := plugins.Build(name, cfg); err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("plugin %q: %w", name, err))
	}
	encrypted, err := s.cipher.Encrypt(cfg)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encrypt plugin settings: %w", err))
	}
	row, err := s.queries.UpsertUserPluginSettings(ctx, store.UpsertUserPluginSettingsParams{
		UserID:          caller.ID,
		PluginName:      name,
		ConfigEncrypted: encrypted,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.UpsertUserPluginSettingsResponse{
		Settings: &psmithv1.UserPluginSettings{
			PluginName: row.PluginName,
			Config:     cfg, // echo plaintext (row.ConfigEncrypted is opaque bytes)
		},
	}), nil
}

// pluginTypeToProto converts a plugins.TypeDescriptor to its proto shape.
func pluginTypeToProto(d plugins.TypeDescriptor) *psmithv1.PluginType {
	fields := make([]*psmithv1.ConfigField, 0, len(d.ConfigFields))
	for _, f := range d.ConfigFields {
		fields = append(fields, configFieldToProto(f))
	}
	requestedFacts := make([]psmithv1.DeviceFactKey, 0, len(d.RequestedDeviceFacts))
	for _, k := range d.RequestedDeviceFacts {
		if proto := deviceFactKeyToProto(k); proto != psmithv1.DeviceFactKey_DEVICE_FACT_KEY_UNSPECIFIED {
			requestedFacts = append(requestedFacts, proto)
		}
	}
	return &psmithv1.PluginType{
		Name:         d.Name,
		DisplayName:  d.DisplayName,
		Description:  d.Description,
		ConfigFields: fields,
		Capabilities: &psmithv1.PluginCapabilities{
			Configurable:                d.Capabilities.Configurable,
			SystemPrompter:              d.Capabilities.SystemPrompter,
			OutgoingUserTransformer:     d.Capabilities.OutgoingUserTransformer,
			HistoryTransformer:          d.Capabilities.HistoryTransformer,
			ChunkTransformer:            d.Capabilities.ChunkTransformer,
			DisplayTransformer:          d.Capabilities.DisplayTransformer,
			ToolProvider:                d.Capabilities.ToolProvider,
			AssistantContentTransformer: d.Capabilities.AssistantContentTransformer,
			MessageLifecycleHook:        d.Capabilities.MessageLifecycleHook,
			DeviceFactRequester:         d.Capabilities.DeviceFactRequester,
			ContentRenderer:             d.Capabilities.ContentRenderer,
		},
		RequestedDeviceFacts:      requestedFacts,
		RequiredModelCapabilities: capabilityRequirementsToProto(d.RequiredModelCapabilities),
	}
}

// capabilityRequirementsToProto converts the plugins-package shape to its
// proto twin. Returns nil when the requirement set is empty so the proto
// field stays unset (mirroring the optional<ModelCapabilities> on the wire).
func capabilityRequirementsToProto(r plugins.ModelCapabilityRequirements) *psmithv1.ModelCapabilities {
	if r.Empty() {
		return nil
	}
	return &psmithv1.ModelCapabilities{
		Streaming:       r.Streaming,
		Thinking:        r.Thinking,
		ToolUse:         r.ToolUse,
		Vision:          r.Vision,
		PromptCaching:   r.PromptCaching,
		GeneratesImages: r.GeneratesImages,
	}
}

// deviceFactKeyToProto mirrors the same string ↔ enum mapping
// the conversations service uses on the inbound side. Defined
// here to avoid a cross-package dep from internal/profiles into
// internal/conversations; both pin to the plugins.DeviceFactKey*
// string constants as the source of truth.
func deviceFactKeyToProto(k string) psmithv1.DeviceFactKey {
	switch k {
	case plugins.DeviceFactKeyLocale:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCALE
	case plugins.DeviceFactKeyTimezone:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_TIMEZONE
	case plugins.DeviceFactKeyPlatform:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_PLATFORM
	case plugins.DeviceFactKeyLocationCity:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCATION_CITY
	case plugins.DeviceFactKeyLocationCoords:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCATION_COORDS
	default:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_UNSPECIFIED
	}
}

// configFieldToProto converts one plugins.ConfigField to its proto shape.
// The Default is JSON-marshaled into default_json; nil becomes the empty
// string (which the wire treats as "no default"). Unknown field types map
// to TYPE_UNSPECIFIED so a malformed plugin descriptor surfaces as an
// explicit zero-value rather than getting silently coerced.
func configFieldToProto(f plugins.ConfigField) *psmithv1.ConfigField {
	out := &psmithv1.ConfigField{
		Name:        f.Name,
		Display:     f.Display,
		Description: f.Description,
		Type:        configFieldTypeToProto(f.Type),
		Required:    f.Required,
		Global:      f.Global,
		Merge:       configFieldMergeToProto(f.Merge),
		Category:    f.Category,
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
		opts := make([]*psmithv1.ConfigOption, 0, len(f.Options))
		for _, o := range f.Options {
			opts = append(opts, &psmithv1.ConfigOption{Value: o.Value, Label: o.Label})
		}
		out.Options = opts
	}
	if f.Type == plugins.ConfigFieldModelPicker {
		out.ModelPickerFilter = &psmithv1.ModelPickerFilter{
			RequiresStreaming:       f.ModelPickerFilter.RequiresStreaming,
			RequiresThinking:        f.ModelPickerFilter.RequiresThinking,
			RequiresToolUse:         f.ModelPickerFilter.RequiresToolUse,
			RequiresVision:          f.ModelPickerFilter.RequiresVision,
			RequiresPromptCaching:   f.ModelPickerFilter.RequiresPromptCaching,
			RequiresGeneratesImages: f.ModelPickerFilter.RequiresGeneratesImages,
		}
	}
	return out
}

func configFieldMergeToProto(m plugins.ConfigFieldMerge) psmithv1.ConfigField_Merge {
	switch m {
	case plugins.MergeAppendString:
		return psmithv1.ConfigField_MERGE_APPEND_STRING
	default:
		return psmithv1.ConfigField_MERGE_REPLACE
	}
}

func configFieldTypeToProto(t plugins.ConfigFieldType) psmithv1.ConfigField_Type {
	switch t {
	case plugins.ConfigFieldNumber:
		return psmithv1.ConfigField_NUMBER
	case plugins.ConfigFieldText:
		return psmithv1.ConfigField_TEXT
	case plugins.ConfigFieldTextarea:
		return psmithv1.ConfigField_TEXTAREA
	case plugins.ConfigFieldBoolean:
		return psmithv1.ConfigField_BOOLEAN
	case plugins.ConfigFieldSelect:
		return psmithv1.ConfigField_SELECT
	case plugins.ConfigFieldModelPicker:
		return psmithv1.ConfigField_MODEL_PICKER
	default:
		return psmithv1.ConfigField_TYPE_UNSPECIFIED
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

// parentChainContains walks up from `startID` via parent_profile_id
// until it reaches a root, hits `needle`, or exceeds the cycle guard
// (8 hops — same as the runtime resolvers). Returns true when
// `needle` appears in the chain — i.e., setting `needle.parent_profile_id
// = startID` would create a cycle. Used at update time to reject
// circular parenting before it lands in the DB.
func (s *Service) parentChainContains(ctx context.Context, startID, needle uuid.UUID) (bool, error) {
	const maxHops = 8
	cur := startID
	seen := make(map[uuid.UUID]bool, maxHops)
	for hops := 0; hops < maxHops; hops++ {
		if cur == needle {
			return true, nil
		}
		if seen[cur] {
			// Pre-existing cycle in stored data — not our problem here.
			// Returning false avoids spuriously rejecting a clean
			// re-parent just because the EXISTING chain is already
			// corrupt; the user can untangle that separately.
			return false, nil
		}
		seen[cur] = true
		row, err := s.queries.GetProfileByID(ctx, cur)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return false, nil
			}
			return false, err
		}
		if row.ParentProfileID == nil {
			return false, nil
		}
		cur = *row.ParentProfileID
	}
	return false, nil
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

func compressionModeToString(m psmithv1.CompressionMode) (string, error) {
	switch m {
	case psmithv1.CompressionMode_COMPRESSION_MODE_REPLACE:
		return compressionModeReplace, nil
	case psmithv1.CompressionMode_COMPRESSION_MODE_APPEND:
		return compressionModeAppend, nil
	case psmithv1.CompressionMode_COMPRESSION_MODE_UNSPECIFIED:
		return "", errors.New("compression_mode is unspecified")
	default:
		return "", fmt.Errorf("unknown compression_mode: %v", m)
	}
}

func compressionModeFromString(s string) psmithv1.CompressionMode {
	switch s {
	case compressionModeReplace:
		return psmithv1.CompressionMode_COMPRESSION_MODE_REPLACE
	case compressionModeAppend:
		return psmithv1.CompressionMode_COMPRESSION_MODE_APPEND
	default:
		return psmithv1.CompressionMode_COMPRESSION_MODE_UNSPECIFIED
	}
}

// defaultsToJSON marshals a ProfileDefaults message to a JSON blob suitable
// for the JSONB column. Returns nil for a nil input (so the column stays NULL).
func defaultsToJSON(d *psmithv1.ProfileDefaults) ([]byte, error) {
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

// DefaultsFromJSON unmarshals a JSONB blob back into a ProfileDefaults message.
// Returns nil for empty input. Exported so other packages (e.g. conversations)
// can decode profiles.default_settings without re-implementing the storage
// shape — the snake_case JSON keys don't match protojson's camelCase output,
// so a vanilla json.Unmarshal into ProfileDefaults silently misses every field.
func DefaultsFromJSON(b []byte) (*psmithv1.ProfileDefaults, error) {
	return defaultsFromJSON(b)
}

func defaultsFromJSON(b []byte) (*psmithv1.ProfileDefaults, error) {
	if len(b) == 0 {
		return nil, nil
	}
	var s defaultsStorage
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("decode default_settings: %w", err)
	}
	out := &psmithv1.ProfileDefaults{
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

func profileToProto(p store.Profile) (*psmithv1.Profile, error) {
	defaults, err := defaultsFromJSON(p.DefaultSettings)
	if err != nil {
		return nil, err
	}
	out := &psmithv1.Profile{
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
		IsDefault:          p.IsDefault,
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
	out.WelcomeMessage = p.WelcomeMessage
	return out, nil
}

// attachRequiredCaps sets the proto's required_model_capabilities by
// walking the profile's effective plugin pipeline (with parent-chain
// inheritance). Best-effort: resolution failures are logged-and-skipped
// rather than failing the read — a stale row shouldn't make GetProfile
// itself fail.
func (s *Service) attachRequiredCaps(ctx context.Context, p *psmithv1.Profile) {
	if p == nil {
		return
	}
	pid, err := uuid.Parse(p.GetId())
	if err != nil {
		return
	}
	caps, err := ResolveRequiredModelCapabilities(ctx, s.queries, pid)
	if err != nil {
		return
	}
	p.RequiredModelCapabilities = capabilityRequirementsToProto(caps)
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
