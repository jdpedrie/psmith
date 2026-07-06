// Package streamsvc implements the StreamsService Connect handler — a thin
// shim over internal/stream's Supervisor exposing Subscribe / Cancel / Get.
package streamsvc

import (
	"context"
	"errors"
	"fmt"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/gen/psmith/v1/psmithv1connect"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/providers"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/stream"
)

// Service satisfies psmithv1connect.StreamsServiceHandler.
type Service struct {
	psmithv1connect.UnimplementedStreamsServiceHandler
	queries    *store.Queries
	supervisor *stream.Supervisor
}

func NewService(queries *store.Queries, supervisor *stream.Supervisor) *Service {
	return &Service{queries: queries, supervisor: supervisor}
}

// SubscribeStream forwards events from supervisor.Subscribe to the Connect
// server-stream. Closes when the supervisor signals terminal or when the
// client/context is done.
func (s *Service) SubscribeStream(ctx context.Context, req *connect.Request[psmithv1.SubscribeStreamRequest], serverStream *connect.ServerStream[psmithv1.SubscribeStreamResponse]) error {
	runID, err := uuid.Parse(req.Msg.StreamRunId)
	if err != nil {
		return connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid stream_run_id: %w", err))
	}

	events, err := s.supervisor.Subscribe(ctx, runID, req.Msg.FromSequence)
	if err != nil {
		if errors.Is(err, stream.ErrNotFound) {
			return connect.NewError(connect.CodeNotFound, err)
		}
		return connect.NewError(connect.CodeInternal, err)
	}

	for ev := range events {
		var msg *psmithv1.SubscribeStreamResponse
		switch {
		case ev.Chunk != nil:
			msg = &psmithv1.SubscribeStreamResponse{
				Event: &psmithv1.SubscribeStreamResponse_Chunk{
					Chunk: &psmithv1.Chunk{
						Sequence: ev.Chunk.Sequence,
						Type:     chunkTypeToProto(ev.Chunk.Type),
						Payload:  ev.Chunk.Payload,
					},
				},
			}
		case ev.Terminal != nil:
			msg = &psmithv1.SubscribeStreamResponse{
				Event: &psmithv1.SubscribeStreamResponse_Terminal{
					Terminal: streamRunToProto(*ev.Terminal),
				},
			}
		default:
			// Empty event — skip.
			continue
		}
		if err := serverStream.Send(msg); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) CancelStream(ctx context.Context, req *connect.Request[psmithv1.CancelStreamRequest]) (*connect.Response[psmithv1.CancelStreamResponse], error) {
	runID, err := uuid.Parse(req.Msg.StreamRunId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid stream_run_id: %w", err))
	}
	if err := s.supervisor.Cancel(ctx, runID); err != nil {
		if errors.Is(err, stream.ErrNotFound) {
			return nil, connect.NewError(connect.CodeNotFound, err)
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.CancelStreamResponse{}), nil
}

func (s *Service) GetStreamRun(ctx context.Context, req *connect.Request[psmithv1.GetStreamRunRequest]) (*connect.Response[psmithv1.GetStreamRunResponse], error) {
	runID, err := uuid.Parse(req.Msg.StreamRunId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid stream_run_id: %w", err))
	}
	row, err := s.supervisor.Get(ctx, runID)
	if err != nil {
		if errors.Is(err, stream.ErrNotFound) {
			return nil, connect.NewError(connect.CodeNotFound, err)
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.GetStreamRunResponse{StreamRun: streamRunToProto(row)}), nil
}

// ListActiveRuns returns every `status='running'` stream_run the caller
// owns, optionally filtered to a single conversation. iOS StreamHub
// calls this on app launch and on conversation entry to adopt in-flight
// turns the previous view didn't finish receiving.
func (s *Service) ListActiveRuns(ctx context.Context, req *connect.Request[psmithv1.ListActiveRunsRequest]) (*connect.Response[psmithv1.ListActiveRunsResponse], error) {
	caller := auth.MustFromContext(ctx)

	var rows []store.StreamRun
	if req.Msg.ConversationId != nil && *req.Msg.ConversationId != "" {
		convID, err := uuid.Parse(*req.Msg.ConversationId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid conversation_id: %w", err))
		}
		got, err := s.queries.ListActiveStreamRunsByConversation(ctx, store.ListActiveStreamRunsByConversationParams{
			UserID:         caller.ID,
			ConversationID: convID,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		rows = got
	} else {
		got, err := s.queries.ListActiveStreamRunsByUser(ctx, caller.ID)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		rows = got
	}

	out := make([]*psmithv1.StreamRun, 0, len(rows))
	for _, r := range rows {
		out = append(out, streamRunToProto(r))
	}
	return connect.NewResponse(&psmithv1.ListActiveRunsResponse{Runs: out}), nil
}

// --- conversions ---

func streamRunToProto(r store.StreamRun) *psmithv1.StreamRun {
	out := &psmithv1.StreamRun{
		Id:             r.ID.String(),
		ConversationId: r.ConversationID.String(),
		ContextId:      r.ContextID.String(),
		ProviderId:     r.ProviderID.String(),
		ModelId:        r.ModelID,
		Status:         statusToProto(r.Status),
		Purpose:        purposeToProto(r.Purpose),
		StartedAt:      timestamppb.New(r.StartedAt),
		ErrorPayload:   r.ErrorPayload,
	}
	if r.ParentMessageID != nil {
		s := r.ParentMessageID.String()
		out.ParentMessageId = &s
	}
	if r.EndedAt != nil {
		out.EndedAt = timestamppb.New(*r.EndedAt)
	}
	if r.ResultMessageID != nil {
		s := r.ResultMessageID.String()
		out.ResultMessageId = &s
	}
	if r.ResultContextID != nil {
		s := r.ResultContextID.String()
		out.ResultContextId = &s
	}
	out.PrefixLength = r.PrefixLength
	out.CacheStablePrefixLength = r.CacheStablePrefixLength
	out.CacheTrailingDepth = r.CacheTrailingDepth
	return out
}

func statusToProto(s string) psmithv1.StreamRunStatus {
	switch s {
	case "running":
		return psmithv1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING
	case "completed":
		return psmithv1.StreamRunStatus_STREAM_RUN_STATUS_COMPLETED
	case "errored":
		return psmithv1.StreamRunStatus_STREAM_RUN_STATUS_ERRORED
	case "cancelled":
		return psmithv1.StreamRunStatus_STREAM_RUN_STATUS_CANCELLED
	case "interrupted":
		return psmithv1.StreamRunStatus_STREAM_RUN_STATUS_INTERRUPTED
	}
	return psmithv1.StreamRunStatus_STREAM_RUN_STATUS_UNSPECIFIED
}

func purposeToProto(p string) psmithv1.StreamRunPurpose {
	switch p {
	case "assistant_response":
		return psmithv1.StreamRunPurpose_STREAM_RUN_PURPOSE_ASSISTANT_RESPONSE
	case "compression":
		return psmithv1.StreamRunPurpose_STREAM_RUN_PURPOSE_COMPRESSION
	}
	return psmithv1.StreamRunPurpose_STREAM_RUN_PURPOSE_UNSPECIFIED
}

func chunkTypeToProto(t providers.ChunkType) psmithv1.ChunkType {
	switch t {
	case providers.ChunkText:
		return psmithv1.ChunkType_CHUNK_TYPE_TEXT_DELTA
	case providers.ChunkThinking:
		return psmithv1.ChunkType_CHUNK_TYPE_THINKING_DELTA
	case providers.ChunkToolUseStart:
		return psmithv1.ChunkType_CHUNK_TYPE_TOOL_USE_START
	case providers.ChunkToolUseDelta:
		return psmithv1.ChunkType_CHUNK_TYPE_TOOL_USE_DELTA
	case providers.ChunkToolUseEnd:
		return psmithv1.ChunkType_CHUNK_TYPE_TOOL_USE_END
	case providers.ChunkUsage:
		return psmithv1.ChunkType_CHUNK_TYPE_USAGE
	case providers.ChunkError:
		return psmithv1.ChunkType_CHUNK_TYPE_ERROR
	case providers.ChunkDone:
		return psmithv1.ChunkType_CHUNK_TYPE_DONE
	case providers.ChunkToolResult:
		return psmithv1.ChunkType_CHUNK_TYPE_TOOL_RESULT
	case providers.ChunkThinkingSignature:
		return psmithv1.ChunkType_CHUNK_TYPE_THINKING_SIGNATURE
	case providers.ChunkElicit:
		return psmithv1.ChunkType_CHUNK_TYPE_ELICIT
	case providers.ChunkDeviceToolUse:
		return psmithv1.ChunkType_CHUNK_TYPE_DEVICE_TOOL_USE
	}
	return psmithv1.ChunkType_CHUNK_TYPE_UNSPECIFIED
}
