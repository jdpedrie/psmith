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

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/gen/reeve/v1/reevev1connect"
	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
)

// Service satisfies reevev1connect.StreamsServiceHandler.
type Service struct {
	reevev1connect.UnimplementedStreamsServiceHandler
	supervisor *stream.Supervisor
}

func NewService(supervisor *stream.Supervisor) *Service {
	return &Service{supervisor: supervisor}
}

// SubscribeStream forwards events from supervisor.Subscribe to the Connect
// server-stream. Closes when the supervisor signals terminal or when the
// client/context is done.
func (s *Service) SubscribeStream(ctx context.Context, req *connect.Request[reevev1.SubscribeStreamRequest], serverStream *connect.ServerStream[reevev1.SubscribeStreamResponse]) error {
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
		var msg *reevev1.SubscribeStreamResponse
		switch {
		case ev.Chunk != nil:
			msg = &reevev1.SubscribeStreamResponse{
				Event: &reevev1.SubscribeStreamResponse_Chunk{
					Chunk: &reevev1.Chunk{
						Sequence: ev.Chunk.Sequence,
						Type:     chunkTypeToProto(ev.Chunk.Type),
						Payload:  ev.Chunk.Payload,
					},
				},
			}
		case ev.Terminal != nil:
			msg = &reevev1.SubscribeStreamResponse{
				Event: &reevev1.SubscribeStreamResponse_Terminal{
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

func (s *Service) CancelStream(ctx context.Context, req *connect.Request[reevev1.CancelStreamRequest]) (*connect.Response[reevev1.CancelStreamResponse], error) {
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
	return connect.NewResponse(&reevev1.CancelStreamResponse{}), nil
}

func (s *Service) GetStreamRun(ctx context.Context, req *connect.Request[reevev1.GetStreamRunRequest]) (*connect.Response[reevev1.GetStreamRunResponse], error) {
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
	return connect.NewResponse(&reevev1.GetStreamRunResponse{StreamRun: streamRunToProto(row)}), nil
}

// --- conversions ---

func streamRunToProto(r store.StreamRun) *reevev1.StreamRun {
	out := &reevev1.StreamRun{
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

func statusToProto(s string) reevev1.StreamRunStatus {
	switch s {
	case "running":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING
	case "completed":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_COMPLETED
	case "errored":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_ERRORED
	case "cancelled":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_CANCELLED
	case "interrupted":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_INTERRUPTED
	}
	return reevev1.StreamRunStatus_STREAM_RUN_STATUS_UNSPECIFIED
}

func purposeToProto(p string) reevev1.StreamRunPurpose {
	switch p {
	case "assistant_response":
		return reevev1.StreamRunPurpose_STREAM_RUN_PURPOSE_ASSISTANT_RESPONSE
	case "compression":
		return reevev1.StreamRunPurpose_STREAM_RUN_PURPOSE_COMPRESSION
	}
	return reevev1.StreamRunPurpose_STREAM_RUN_PURPOSE_UNSPECIFIED
}

func chunkTypeToProto(t providers.ChunkType) reevev1.ChunkType {
	switch t {
	case providers.ChunkText:
		return reevev1.ChunkType_CHUNK_TYPE_TEXT_DELTA
	case providers.ChunkThinking:
		return reevev1.ChunkType_CHUNK_TYPE_THINKING_DELTA
	case providers.ChunkToolUseStart:
		return reevev1.ChunkType_CHUNK_TYPE_TOOL_USE_START
	case providers.ChunkToolUseDelta:
		return reevev1.ChunkType_CHUNK_TYPE_TOOL_USE_DELTA
	case providers.ChunkToolUseEnd:
		return reevev1.ChunkType_CHUNK_TYPE_TOOL_USE_END
	case providers.ChunkUsage:
		return reevev1.ChunkType_CHUNK_TYPE_USAGE
	case providers.ChunkError:
		return reevev1.ChunkType_CHUNK_TYPE_ERROR
	case providers.ChunkDone:
		return reevev1.ChunkType_CHUNK_TYPE_DONE
	case providers.ChunkToolResult:
		return reevev1.ChunkType_CHUNK_TYPE_TOOL_RESULT
	case providers.ChunkThinkingSignature:
		return reevev1.ChunkType_CHUNK_TYPE_THINKING_SIGNATURE
	}
	return reevev1.ChunkType_CHUNK_TYPE_UNSPECIFIED
}
