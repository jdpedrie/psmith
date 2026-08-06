package conversations

import (
	"context"
	"errors"
	"fmt"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/pluginapi/host"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/store"
)

// GetPluginPanel renders one plugin's panel for a conversation.
//
// The response is UIFragments, the same structure plugins emit into messages,
// so clients draw panels with the renderer they already have. Nothing here is
// plugin-specific: the handler resolves the pipeline, finds the named plugin,
// and hands back whatever it produced.
func (s *Service) GetPluginPanel(ctx context.Context, req *connect.Request[psmithv1.GetPluginPanelRequest]) (*connect.Response[psmithv1.GetPluginPanelResponse], error) {
	pipeline, conv, err := s.panelPipeline(ctx, req.Msg.ConversationId)
	if err != nil {
		return nil, err
	}

	parts, err := pipeline.PanelFor(ctx, req.Msg.PluginName, s.panelDecorator(ctx, conv))
	if err != nil {
		return nil, connect.NewError(connect.CodeNotFound, err)
	}
	return connect.NewResponse(&psmithv1.GetPluginPanelResponse{
		Fragments: contentPartsToProto(parts),
	}), nil
}

// InvokePluginAction routes a panel action back to the plugin that drew it,
// then returns the re-rendered panel.
//
// Re-rendering here rather than making the client ask again is not just a
// saved round trip: every action this exists for changes what the panel should
// show, so a client that had to re-fetch would flash stale state in between.
func (s *Service) InvokePluginAction(ctx context.Context, req *connect.Request[psmithv1.InvokePluginActionRequest]) (*connect.Response[psmithv1.InvokePluginActionResponse], error) {
	if req.Msg.Action == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("action is required"))
	}
	pipeline, conv, err := s.panelPipeline(ctx, req.Msg.ConversationId)
	if err != nil {
		return nil, err
	}
	decorate := s.panelDecorator(ctx, conv)

	if err := pipeline.DispatchAction(ctx, req.Msg.PluginName, req.Msg.Action, req.Msg.Params, decorate); err != nil {
		// An action a plugin does not recognise means the client is newer
		// than the server. That is a precondition failure the user can act on
		// (update the server), not an internal error.
		if errors.Is(err, pluginapi.ErrUnknownAction) {
			return nil, connect.NewError(connect.CodeFailedPrecondition, err)
		}
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}

	parts, err := pipeline.PanelFor(ctx, req.Msg.PluginName, decorate)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("re-render panel: %w", err))
	}
	return connect.NewResponse(&psmithv1.InvokePluginActionResponse{
		Fragments: contentPartsToProto(parts),
	}), nil
}

// panelPipeline resolves the conversation's active pipeline, owner-checked.
func (s *Service) panelPipeline(ctx context.Context, rawID string) (pluginapi.Pipeline, store.Conversation, error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(rawID)
	if err != nil {
		return nil, store.Conversation{}, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid conversation_id: %w", err))
	}
	conv, err := s.fetchOwnedConversation(ctx, id, caller.ID)
	if err != nil {
		return nil, store.Conversation{}, err
	}
	pipeline, err := s.resolvePipelineForConversation(ctx, conv)
	if err != nil {
		return nil, store.Conversation{}, connect.NewError(connect.CodeInternal, err)
	}
	return pipeline, conv, nil
}

// panelDecorator gives a panel the same per-plugin state store tool dispatch
// gets, anchored at the conversation's current leaf.
//
// Panels run outside a send, so there is no new message to key writes to. The
// leaf is the branch as it stands, which is what an action should read and
// write against.
func (s *Service) panelDecorator(ctx context.Context, conv store.Conversation) func(context.Context, string) context.Context {
	// Best effort: a conversation with no active context or no messages yet
	// has no leaf, and a plugin that needs one reports that itself rather
	// than having the panel fail to open.
	var leaf uuid.UUID
	if active, err := s.queries.GetActiveContextByConversation(ctx, conv.ID); err == nil {
		if active.CurrentLeafMessageID != nil {
			leaf = *active.CurrentLeafMessageID
		}
	}
	return func(c context.Context, pluginName string) context.Context {
		return host.WithPluginStateStore(c, s.newPluginStateStore(pluginName, conv.UserID, conv.ID, leaf))
	}
}
