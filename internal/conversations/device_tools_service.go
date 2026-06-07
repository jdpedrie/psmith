package conversations

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/devicetools"
)

// DeviceToolsService implements the connect handler for the
// per-connection capability handshake. Lives on the conversations
// Service so it shares the broker + registry; constructed via
// `s.DeviceToolsService()` and mounted by cmd/reeved.
//
// Two RPCs:
//
//   RegisterCapabilities — client → server: "this is the set of
//                          device-tool names I can fulfill right
//                          now." Scoped by the calling user; the
//                          conversation context comes from the
//                          stream subscriber, not this call, so the
//                          handler currently registers per-user
//                          with conversation = nil — see TODO below.
//
//   ListSupportedTools   — server → client: the full server-side
//                          catalog of tools, with JSON schemas, so
//                          the client can render documentation and
//                          pre-validate inputs before POSTing them.
//
// TODO(device-tools): conversation scoping. The registry is keyed by
// (user, conversation) so multiple conversations can have different
// devices. But RegisterCapabilities today has no conversation id —
// the client publishes its capabilities once per connection, not per
// conversation. Resolution: either drop conversation from the
// registry key (registry becomes per-user) or pass conversation_id
// in the RegisterCapabilities request. Going per-user for now; the
// (user, conv) key is forward-compat for the conversation-scoped
// future.
type deviceToolsServiceHandler struct {
	broker   *devicetools.Broker
	registry *devicetools.Registry
}

// DeviceToolsService returns a Connect handler suitable for
// reevev1connect.NewDeviceToolsServiceHandler. Mounted by
// cmd/reeved alongside the other service handlers.
func (s *Service) DeviceToolsService() *deviceToolsServiceHandler {
	return &deviceToolsServiceHandler{
		broker:   s.deviceToolBroker,
		registry: s.deviceToolRegistry,
	}
}

func (h *deviceToolsServiceHandler) RegisterCapabilities(
	ctx context.Context,
	req *connect.Request[reevev1.RegisterCapabilitiesRequest],
) (*connect.Response[reevev1.RegisterCapabilitiesResponse], error) {
	user, ok := auth.FromContext(ctx)
	if !ok {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("not authenticated"))
	}
	// Conversation-id-less registration: see the TODO on this
	// type. uuid.Nil here is the "applies to every conversation
	// for this user" sentinel; Registry.SupportsForUser is a
	// future helper that walks both the (user, conv) and
	// (user, nil) entries.
	//
	// Today, with the registry keyed by (user, conv), we register
	// under (user, uuid.Nil) — the conversations tool dispatch
	// then needs to also consult that key. Wired below in the
	// per-call broker binding's SupportedTools.
	h.registry.Register(user.ID, uuid.Nil,
		req.Msg.SupportedToolNames, req.Msg.ClientAttributes)
	return connect.NewResponse(&reevev1.RegisterCapabilitiesResponse{}), nil
}

func (h *deviceToolsServiceHandler) ListSupportedTools(
	_ context.Context,
	_ *connect.Request[reevev1.ListSupportedToolsRequest],
) (*connect.Response[reevev1.ListSupportedToolsResponse], error) {
	tools := devicetools.All()
	out := make([]*reevev1.SupportedTool, 0, len(tools))
	for _, t := range tools {
		out = append(out, &reevev1.SupportedTool{
			Name:                t.Name,
			DisplayName:         t.DisplayName,
			Description:         t.Description,
			InputSchema:         []byte(t.InputSchema),
			Category:            t.Category,
			RequiredPermissions: append([]string(nil), t.RequiredPermissions...),
		})
	}
	return connect.NewResponse(&reevev1.ListSupportedToolsResponse{Tools: out}), nil
}
