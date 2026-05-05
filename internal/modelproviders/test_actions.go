// Connection / responsiveness checks for user-configured providers and models.
//
// These RPCs back the "Test" affordances in the UI. Both treat success and
// failure as response payloads (ok / error_message) — they do NOT return an
// RPC error for "the provider was unreachable" or "the model errored mid-
// generation". RPC errors are reserved for cases where we couldn't even start
// the test (NotFound / InvalidArgument / FailedPrecondition).

package modelproviders

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/providers"
)

const (
	// modelTestPrompt is the tiny prompt sent to a model under test. The
	// "single word" framing keeps responses short on every model we've tried.
	modelTestPrompt = "Reply with the single word OK."
	// modelTestTimeout caps the model-test wall clock. Slow providers should
	// still produce a usage chunk within a few seconds.
	modelTestTimeout = 15 * time.Second
	// modelTestMaxChunks bounds how many text chunks we'll accumulate. Even a
	// chatty model has no business writing more than a few dozen for "OK".
	modelTestMaxChunks = 64
	// modelTestSampleCap caps the sample_text returned to clients. Long enough
	// to surface a chatty refusal/error string, short enough to stay inline.
	modelTestSampleCap = 80
)

// TestUserModelProvider verifies a provider's auth + reachability by
// driver.DiscoverModels. Failures are packed into the response — only
// "couldn't start the test" cases (NotFound, FailedPrecondition for
// unbuildable driver) come back as RPC errors.
func (s *Service) TestUserModelProvider(ctx context.Context, req *connect.Request[reevev1.TestUserModelProviderRequest]) (*connect.Response[reevev1.TestUserModelProviderResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}

	cfg, err := s.resolveProviderConfig(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	driver, err := providers.Build(row.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, cfg)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build driver: %w", err))
	}

	start := time.Now()
	models, derr := driver.DiscoverModels(ctx)
	elapsed := time.Since(start)

	resp := &reevev1.TestUserModelProviderResponse{
		LatencyMs: elapsed.Milliseconds(),
	}
	if derr != nil {
		resp.Ok = false
		resp.ErrorMessage = firstLine(derr.Error())
		return connect.NewResponse(resp), nil
	}
	resp.Ok = true
	resp.ModelCount = int32(len(models))
	return connect.NewResponse(resp), nil
}

// TestUserModel sends a tiny prompt to the model and reports latency, tokens,
// and a short sample of the reply. Bills a few tokens (expected). Stateful
// providers don't have a "send a quick prompt without a session" surface —
// for those we report ok=false with an explanatory message rather than an
// RPC error so the UI can render the explanation inline alongside reachable
// providers' real results.
func (s *Service) TestUserModel(ctx context.Context, req *connect.Request[reevev1.TestUserModelRequest]) (*connect.Response[reevev1.TestUserModelResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(req.Msg.ModelId) == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("model_id is required"))
	}

	cfg, err := s.resolveProviderConfig(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	driver, err := providers.Build(row.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, cfg)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build driver: %w", err))
	}
	stateless, ok := driver.(providers.StatelessProvider)
	if !ok {
		// Same pattern as conversations.Compact: stateful providers don't have
		// a session-less "send a turn" surface yet. Return ok=false rather
		// than an RPC error so the UI shows the reason in the test row.
		return connect.NewResponse(&reevev1.TestUserModelResponse{
			Ok:           false,
			ErrorMessage: fmt.Sprintf("driver %q is not a stateless provider; model test not yet wired", row.Type),
		}), nil
	}

	testCtx, cancel := context.WithTimeout(ctx, modelTestTimeout)
	defer cancel()

	start := time.Now()
	srcCh, sendErr := stateless.Send(testCtx, providers.SendRequest{
		ModelID: req.Msg.ModelId,
		Messages: []providers.WireMessage{
			{Role: "user", Content: modelTestPrompt},
		},
	})
	if sendErr != nil {
		// Driver refused to even start (4xx, etc.). Pack into the response so
		// the UI shows the message inline.
		return connect.NewResponse(&reevev1.TestUserModelResponse{
			Ok:           false,
			ErrorMessage: firstLine(sendErr.Error()),
			LatencyMs:    time.Since(start).Milliseconds(),
		}), nil
	}

	var (
		sample    strings.Builder
		usage     *providers.Usage
		streamErr string
		nChunks   int
	)
	for chunk := range srcCh {
		nChunks++
		switch chunk.Type {
		case providers.ChunkText:
			if sample.Len() < modelTestSampleCap {
				var payload struct {
					Text string `json:"text"`
				}
				if err := json.Unmarshal(chunk.Payload, &payload); err == nil {
					sample.WriteString(payload.Text)
				}
			}
		case providers.ChunkUsage:
			var u providers.Usage
			if err := json.Unmarshal(chunk.Payload, &u); err == nil {
				u := u // copy
				usage = &u
			}
		case providers.ChunkError:
			var payload struct {
				Message string `json:"message"`
			}
			if err := json.Unmarshal(chunk.Payload, &payload); err == nil && payload.Message != "" {
				streamErr = payload.Message
			} else {
				streamErr = string(chunk.Payload)
			}
		}
		if nChunks >= modelTestMaxChunks {
			// Drain remaining chunks the driver may produce after we cancel.
			cancel()
			for range srcCh {
				// no-op; drain to let the producer goroutine finish.
			}
			break
		}
	}
	elapsed := time.Since(start)

	resp := &reevev1.TestUserModelResponse{
		LatencyMs: elapsed.Milliseconds(),
	}
	resp.SampleText = capSampleText(sample.String(), modelTestSampleCap)
	if usage != nil {
		if usage.InputTokens != nil {
			resp.InputTokens = int32(*usage.InputTokens)
		}
		if usage.OutputTokens != nil {
			resp.OutputTokens = int32(*usage.OutputTokens)
		}
	}

	switch {
	case streamErr != "":
		resp.Ok = false
		resp.ErrorMessage = firstLine(streamErr)
	case sample.Len() == 0 && usage == nil:
		// Stream closed without producing anything useful. Treat as failure.
		resp.Ok = false
		resp.ErrorMessage = "no response from model"
	default:
		resp.Ok = true
	}
	return connect.NewResponse(resp), nil
}

// firstLine returns the leading line of s, trimmed. Used to keep error rows
// in the UI single-line; full errors are still in server logs.
func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}

// capSampleText truncates s at n runes and appends an ellipsis if needed.
// Operates on runes so we don't slice mid-codepoint.
func capSampleText(s string, n int) string {
	s = strings.TrimSpace(s)
	if n <= 0 || len([]rune(s)) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n]) + "…"
}
