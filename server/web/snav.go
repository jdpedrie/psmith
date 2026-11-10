package web

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
)

// loadSnav builds the Settings navigation column with active selected.
// Counts are best-effort: a failed lookup leaves its number at zero rather
// than failing the page.
func (h *Handler) loadSnav(ctx context.Context, r *http.Request, active string) snavVM {
	n := snavVM{Active: active, Server: r.Host}
	if u, ok := auth.FromContext(ctx); ok {
		n.UserName, n.IsAdmin = u.Username, u.IsAdmin
		if u.DisplayName != nil && *u.DisplayName != "" {
			n.UserName = *u.DisplayName
		}
	}
	if n.UserName != "" {
		n.Initial = strings.ToUpper(n.UserName[:1])
	}
	if h.models != nil {
		if resp, err := h.models.ListUserModelProviders(ctx, connect.NewRequest(&psmithv1.ListUserModelProvidersRequest{})); err == nil {
			n.Providers = len(resp.Msg.GetProviders())
		}
		if resp, err := h.models.ListProviderCosts(ctx, connect.NewRequest(&psmithv1.ListProviderCostsRequest{})); err == nil {
			n.UsageTotal = fmt.Sprintf("$%.2f", resp.Msg.GetGrandTotalUsd())
		}
	}
	if h.profiles != nil {
		if resp, err := h.profiles.ListProfiles(ctx, connect.NewRequest(&psmithv1.ListProfilesRequest{})); err == nil {
			n.Profiles = len(resp.Msg.GetProfiles())
		}
		// The servers' recorded tests, not fresh probes: probing every
		// server on every Settings page would hold each page for seconds.
		if servers, err := h.listMCPServers(ctx); err == nil {
			for _, s := range servers {
				if t := s.GetLastTest(); t != nil && !t.GetOk() {
					n.ServersBad++
				}
			}
		}
	}
	if n.IsAdmin && h.auth != nil {
		if resp, err := h.auth.ListUsers(ctx, connect.NewRequest(&psmithv1.ListUsersRequest{})); err == nil {
			n.Users = len(resp.Msg.GetUsers())
		}
	}
	return n
}
