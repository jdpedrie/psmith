// Package preferencessvc serves the PreferencesService Connect RPCs:
// per-user client preferences stored on the server so every device a
// user signs in on reads the same values.
package preferencessvc

import (
	"context"
	"errors"
	"fmt"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/store"
)

// Service implements psmithv1connect.PreferencesServiceHandler.
type Service struct {
	queries *store.Queries
}

func NewService(queries *store.Queries) *Service {
	return &Service{queries: queries}
}

// GetPreferences returns the stored row, or the defaults when the user
// has never changed a setting.
func (s *Service) GetPreferences(ctx context.Context, _ *connect.Request[psmithv1.GetPreferencesRequest]) (*connect.Response[psmithv1.GetPreferencesResponse], error) {
	user := auth.MustFromContext(ctx)
	prefs, err := s.load(ctx, user)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&psmithv1.GetPreferencesResponse{Preferences: prefs}), nil
}

// UpdatePreferences merges the request's set fields onto the current
// values and writes the whole row.
func (s *Service) UpdatePreferences(ctx context.Context, req *connect.Request[psmithv1.UpdatePreferencesRequest]) (*connect.Response[psmithv1.UpdatePreferencesResponse], error) {
	user := auth.MustFromContext(ctx)
	prefs, err := s.load(ctx, user)
	if err != nil {
		return nil, err
	}
	if v := req.Msg.ContextWarningTokens; v != nil {
		if *v < 0 {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("context_warning_tokens must be >= 0, got %d", *v))
		}
		prefs.ContextWarningTokens = *v
	}
	row, err := s.queries.UpsertUserPreferences(ctx, store.UpsertUserPreferencesParams{
		UserID:               user.ID,
		ContextWarningTokens: prefs.ContextWarningTokens,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.UpdatePreferencesResponse{Preferences: rowToProto(row)}), nil
}

func (s *Service) load(ctx context.Context, user auth.User) (*psmithv1.UserPreferences, error) {
	row, err := s.queries.GetUserPreferences(ctx, user.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return defaults(), nil
	}
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return rowToProto(row), nil
}

// defaults is what a user who never changed a setting gets. Kept in
// step with the column defaults in migration 00054.
func defaults() *psmithv1.UserPreferences {
	return &psmithv1.UserPreferences{ContextWarningTokens: 0}
}

func rowToProto(r store.UserPreference) *psmithv1.UserPreferences {
	return &psmithv1.UserPreferences{ContextWarningTokens: r.ContextWarningTokens}
}
