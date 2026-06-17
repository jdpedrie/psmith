package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/spalt/internal/devicetools"
	"github.com/jdpedrie/spalt/internal/elicit"
	"github.com/jdpedrie/spalt/internal/providers"
	"github.com/jdpedrie/spalt/plugins"
)

// maxToolRounds caps how many tool-use → tool-result → continued-stream
// iterations the wrapper performs inside a single SendMessage.
const maxToolRounds = 8

// makeToolLoopSendFunc wraps a base SendRequest into a SendFunc that
// transparently runs tool-use rounds before returning the final stream
// to the supervisor. From the supervisor's point of view it sees a
// single linear chunk stream — text, thinking, tool_use_*, tool_result,
// text, … — and materialises one assistant message at the end.
//
// Per round:
//  1. Drain the upstream stream into a single output channel.
//  2. Track every tool_use the model emitted: id, name, accumulated
//     input JSON, ProviderOpaque (Gemini thoughtSignature).
//  3. Capture signed thinking blocks (Anthropic) — text + signature
//     pairs collected during the round.
//  4. When the round ends with tool_use blocks pending, dispatch each
//     to its owning plugin's ExecuteTool, emit a synthetic
//     ChunkToolResult per result for live UI + persistence.
//  5. Build a follow-up SendRequest that appends two synthetic
//     WireMessages — assistant carrying text+tool_use (+ signed
//     thinking), user carrying the tool_results — and re-issue the
//     stream. The model continues from there.
//  6. Loop until a round ends with no pending tool_use, or the round
//     cap is reached. The loop swallows the upstream's intermediate
//     ChunkDone events so the supervisor only sees one ChunkDone at
//     the very end.
//
// ToolSpan is the per-call observation the tool loop hands to its
// onToolSpan callback. The conversations service uses these to fan
// out Langfuse span events nested under the parent assistant
// trace; tests can use them to assert tool dispatch happened.
type ToolSpan struct {
	ToolName  string
	Input     []byte // raw JSON the model emitted
	Output    []byte // raw JSON the plugin returned (empty when ErrorMsg is set)
	ErrorMsg  string // empty on success
	StartedAt time.Time
	EndedAt   time.Time
}

func makeToolLoopSendFunc(
	drv providers.StatelessProvider,
	initial providers.SendRequest,
	pipeline plugins.Pipeline,
	logger *slog.Logger,
	// onToolAttachment, when non-nil, is called once per
	// attachment a tool produces (typically a screenshot or
	// generated image). The conversations service captures these
	// per-run + persists them on the assistant message in the
	// post-materialize hook so they show up in the chat surface
	// alongside the tool's text output.
	onToolAttachment func(plugins.ToolAttachment),
	// onToolCost, when non-nil, is called once per tool result
	// that returned a non-nil ToolResult.CostUSD (today: imagegen
	// after a successful gpt-image-1 / gemini image generation).
	// The conversations service accumulates these into a per-run
	// total that the supervisor reads via StartParams.ToolCostProvider
	// at materialize time and writes to messages.tool_cost_usd
	// (also folded into total_cost_usd).
	onToolCost func(float64),
	// onToolSpan, when non-nil, is called once per tool dispatch
	// (success or failure) with the input/output/timing window.
	// Conversations service buffers these into per-run Langfuse
	// spans nested under the parent assistant trace; the
	// supervisor's post-materialize hook drains the buffer and
	// fans out the spans alongside the trace + generation events.
	// Best-effort: the loop continues if the callback panics
	// (defensive — Langfuse going sideways shouldn't break tools).
	onToolSpan func(ToolSpan),
	// resolver, when non-nil, is attached to the dispatch
	// context so plugins (e.g. `imagegen`) can look up the
	// (provider_id, model_id) pair the user picked in their
	// MODEL_PICKER config and dispatch to the corresponding
	// upstream API.
	resolver plugins.ProviderResolver,
	// elicitBroker, when non-nil, lets in-process MCP tools call
	// ctx.Elicit(...) to ask the user for input mid-call. The
	// closure creates a per-run elicit.Client bound to the broker
	// and the run's chunk channel (so Elicit can emit a UIFragment
	// chunk before blocking on the user's response).
	elicitBroker *elicitBroker,
	// conversationID scopes elicitations to the run's conversation;
	// the user response endpoint cross-checks ownership before
	// delivering. Zero UUID when elicitation is disabled.
	conversationID uuid.UUID,
	// userID scopes per-tool work (e.g. memory plugin's semantic
	// search) so plugins can never see another user's data. Always
	// the conversation's owner; required.
	userID uuid.UUID,
	// activeContextID is the run's active context — the slice of
	// the conversation currently in the wire prefix. The memory
	// plugin uses it to drop hits that already are in scope, since
	// a conversation is a sequence of contexts (compression
	// retires the old one, opens a new one).
	activeContextID uuid.UUID,
	// searcher, when non-nil, is attached to the dispatch context
	// so the memory plugin can answer search_history calls.
	// SPALT_EMBEDDER unset → searcher is nil → search_history
	// surfaces a clean "search not configured" error.
	searcher plugins.Searcher,
	// deviceToolBroker + deviceToolRegistry power the `app_tools`
	// plugin's per-call routing to the connected client. Both
	// nil-tolerant: the plugin reports "no DeviceToolBroker in
	// context" when missing, which the model sees as an ordinary
	// tool error.
	deviceToolBroker *devicetools.Broker,
	deviceToolRegistry *devicetools.Registry,
) func(ctx context.Context) (<-chan providers.Chunk, error) {
	dispatch := buildToolDispatch(pipeline, resolver, searcher,
		plugins.CallerInfo{
			UserID:          userID,
			ConversationID:  conversationID,
			ActiveContextID: activeContextID,
		})

	return func(ctx context.Context) (<-chan providers.Chunk, error) {
		out := make(chan providers.Chunk, 32)
		// Attach an elicit client bound to this run's chunk
		// channel so tools can emit a chunk + block on the user's
		// response. Built inside the closure so the chunk emitter
		// can reference `out` directly.
		if elicitBroker != nil {
			emit := func(eid uuid.UUID, req elicit.Request) {
				payload, err := json.Marshal(struct {
					ElicitationID   uuid.UUID       `json:"elicitation_id"`
					Message         string          `json:"message"`
					RequestedSchema json.RawMessage `json:"requested_schema"`
				}{eid, req.Message, req.RequestedSchema})
				if err != nil {
					return
				}
				select {
				case out <- providers.Chunk{Type: providers.ChunkElicit, Payload: payload}:
				default:
					// Channel full — drop. Better to lose the
					// prompt than block the entire run on a UI
					// that may already be disconnected.
				}
			}
			ctx = elicit.WithClient(ctx, newElicitClient(elicitBroker, conversationID, emit))
		}
		// Per-call DeviceToolBroker binding — emits a
		// CHUNK_TYPE_DEVICE_TOOL_USE chunk and blocks on the HTTP
		// /respond endpoint via the broker. Bound here so emit
		// can write into `out` directly. Wired even when the
		// pipeline doesn't include app_tools — cheap, and avoids
		// surprising "no broker" errors in tests that swap a
		// fixture plugin late.
		if deviceToolBroker != nil && deviceToolRegistry != nil {
			emit := func(req devicetools.Request) {
				payload, err := json.Marshal(req)
				if err != nil {
					return
				}
				select {
				case out <- providers.Chunk{Type: providers.ChunkDeviceToolUse, Payload: payload}:
				default:
					// Channel full — drop. Same rationale as
					// the elicit emit: a disconnected UI
					// shouldn't block the whole run.
				}
			}
			binding := newDeviceToolBinding(deviceToolBroker, deviceToolRegistry,
				userID, conversationID, emit)
			ctx = plugins.WithDeviceToolBroker(ctx, binding)
		}

		go func() {
			defer close(out)

			req := initial
			for round := 0; round < maxToolRounds; round++ {
				upstream, err := drv.Send(ctx, req)
				if err != nil {
					emitError(ctx, out, fmt.Errorf("tool round %d: %w", round, err))
					return
				}

				captured, fatal := drainRound(ctx, upstream, out)
				if fatal != nil {
					return
				}
				if len(captured.calls) == 0 {
					_ = forward(ctx, out, providers.Chunk{
						Type: providers.ChunkDone, Payload: []byte(`{}`),
					})
					return
				}

				results := make([]providers.ToolResultBlock, 0, len(captured.calls))
				for _, c := range captured.calls {
					if err := ctx.Err(); err != nil {
						return
					}
					started := time.Now()
					var toolOut plugins.ToolResult
					var execErr error
					if dispatch == nil {
						execErr = errors.New("no ToolProvider in pipeline")
					} else {
						toolOut, execErr = dispatch(ctx, c.Name, c.Input)
					}
					ended := time.Now()
					elapsed := ended.Sub(started)

					if errors.Is(execErr, context.Canceled) || errors.Is(execErr, context.DeadlineExceeded) {
						return
					}

					rb := providers.ToolResultBlock{ToolUseID: c.ID}
					if execErr != nil {
						rb.Error = execErr.Error()
						if logger != nil {
							logger.Warn("tool execute failed",
								"tool", c.Name,
								"id", c.ID,
								"err", execErr)
						}
					} else {
						rb.Output = toolOut.Output
						// Forward attachments to the next-round
						// wire prefix. Drivers that support
						// image-in-tool-result blocks (Anthropic,
						// Google) re-encode them on the way out;
						// drivers that don't drop silently.
						for _, a := range toolOut.Attachments {
							rb.Attachments = append(rb.Attachments, providers.Attachment{
								Kind:     providers.AttachmentKind(a.Kind),
								MimeType: a.MimeType,
								Data:     a.Data,
								Filename: a.Filename,
							})
							// Hand a copy to the persistence
							// callback so the conversations
							// service can bind it to the
							// assistant message after
							// materialize. Best-effort: callback
							// nil = caller doesn't care.
							if onToolAttachment != nil {
								onToolAttachment(a)
							}
						}
						// Forward the tool's reported spend (if
						// any) to the per-run accumulator. Plugins
						// without a price model leave CostUSD nil
						// and the accumulator stays untouched.
						if onToolCost != nil && toolOut.CostUSD != nil {
							onToolCost(*toolOut.CostUSD)
						}
					}
					results = append(results, rb)

					payload, _ := json.Marshal(map[string]any{
						"tool_use_id":      c.ID,
						"output":           json.RawMessage(rb.Output),
						"error":            rb.Error,
						"elapsed_ms":       elapsed.Milliseconds(),
						"attachment_count": len(rb.Attachments),
					})
					if !forward(ctx, out, providers.Chunk{
						Type: providers.ChunkToolResult, Payload: payload,
					}) {
						return
					}

					// Hand the per-call span window to the observability
					// callback (Langfuse). Best-effort: nil callback OR a
					// panic inside it must not break tool dispatch. Output
					// is the plugin's raw JSON when the call succeeded;
					// the model-emitted Input is captured verbatim either
					// way so failures still get the request body.
					if onToolSpan != nil {
						span := ToolSpan{
							ToolName:  c.Name,
							Input:     append([]byte(nil), c.Input...),
							StartedAt: started,
							EndedAt:   ended,
						}
						if execErr != nil {
							span.ErrorMsg = execErr.Error()
						} else {
							span.Output = append([]byte(nil), rb.Output...)
						}
						func() {
							defer func() {
								if r := recover(); r != nil && logger != nil {
									logger.Warn("tool span callback panicked",
										"tool", c.Name, "recover", r)
								}
							}()
							onToolSpan(span)
						}()
					}
				}

				// Build the follow-up assistant + user messages.
				asstWire := providers.WireMessage{
					Role:     "assistant",
					ToolUses: captured.calls,
				}
				if len(captured.thinking) > 0 {
					if blob, mErr := json.Marshal(captured.thinking); mErr == nil {
						asstWire.Thinking = blob
					}
				}
				userWire := providers.WireMessage{
					Role:        "user",
					ToolResults: results,
				}
				req.Messages = append(append([]providers.WireMessage(nil), req.Messages...), asstWire, userWire)
			}

			emitError(ctx, out, fmt.Errorf("tool loop exceeded %d rounds", maxToolRounds))
		}()

		return out, nil
	}
}

// collectPipelineTools walks the active plugin pipeline and gathers
// every plugin-declared tool into the providers.ToolDef shape used on
// SendRequest.
func collectPipelineTools(pipeline plugins.Pipeline) []providers.ToolDef {
	if len(pipeline) == 0 {
		return nil
	}
	var out []providers.ToolDef
	for _, pl := range pipeline {
		tp, ok := pl.(plugins.ToolProvider)
		if !ok {
			continue
		}
		for _, t := range tp.Tools() {
			out = append(out, providers.ToolDef{
				Name:        t.Name,
				Description: t.Description,
				InputSchema: append([]byte(nil), t.InputSchema...),
			})
		}
	}
	return out
}

// buildToolDispatch constructs a (toolName → owning plugin) lookup.
// `resolver` is attached to every dispatch ctx so plugins that need
// to resolve a user_model id (typically because they hold a
// MODEL_PICKER config) can do so without a service dependency.
// `searcher` + `caller` are attached the same way for the memory
// plugin (and any future plugin needing per-user scoping).
func buildToolDispatch(
	pipeline plugins.Pipeline,
	resolver plugins.ProviderResolver,
	searcher plugins.Searcher,
	caller plugins.CallerInfo,
) func(ctx context.Context, name string, input json.RawMessage) (plugins.ToolResult, error) {
	owners := map[string]plugins.ToolProvider{}
	for _, pl := range pipeline {
		tp, ok := pl.(plugins.ToolProvider)
		if !ok {
			continue
		}
		for _, t := range tp.Tools() {
			if _, dup := owners[t.Name]; dup {
				continue
			}
			owners[t.Name] = tp
		}
	}
	if len(owners) == 0 {
		return nil
	}
	return func(ctx context.Context, name string, input json.RawMessage) (plugins.ToolResult, error) {
		owner, ok := owners[name]
		if !ok {
			return plugins.ToolResult{}, fmt.Errorf("no plugin owns tool %q", name)
		}
		ctx = plugins.WithProviderResolver(ctx, resolver)
		ctx = plugins.WithSearcher(ctx, searcher)
		ctx = plugins.WithCallerInfo(ctx, caller)
		return owner.ExecuteTool(ctx, name, input)
	}
}

// pendingToolUse is one in-flight tool call captured during a round.
type pendingToolUse struct {
	ID             string
	Name           string
	ProviderOpaque string
	input          strings.Builder
}

// roundCapture is the state drainRound accumulates for one round.
type roundCapture struct {
	calls    []providers.ToolUseBlock
	thinking []anthropicThinkingBlock
}

// anthropicThinkingBlock mirrors the JSONB shape Spalt stores on
// messages.thinking for signed-thinking turns.
type anthropicThinkingBlock struct {
	Type      string `json:"type"`
	Thinking  string `json:"thinking,omitempty"`
	Signature string `json:"signature,omitempty"`
}

// drainRound forwards every chunk from upstream to out (except
// intermediate ChunkDone), tracking tool_use blocks and signed
// thinking as it goes.
func drainRound(
	ctx context.Context,
	upstream <-chan providers.Chunk,
	out chan<- providers.Chunk,
) (roundCapture, error) {
	var pending []*pendingToolUse
	currentByIndex := -1

	var thinkingText strings.Builder
	var thinkingBlocks []anthropicThinkingBlock

	for ch := range upstream {
		switch ch.Type {
		case providers.ChunkToolUseStart:
			var info struct {
				ID             string `json:"id"`
				Name           string `json:"name"`
				ProviderOpaque string `json:"provider_opaque"`
			}
			_ = json.Unmarshal(ch.Payload, &info)
			pending = append(pending, &pendingToolUse{
				ID:             info.ID,
				Name:           info.Name,
				ProviderOpaque: info.ProviderOpaque,
			})
			currentByIndex = len(pending) - 1
		case providers.ChunkToolUseDelta:
			var d struct {
				PartialJSON string `json:"partial_json"`
			}
			_ = json.Unmarshal(ch.Payload, &d)
			if currentByIndex >= 0 && currentByIndex < len(pending) {
				pending[currentByIndex].input.WriteString(d.PartialJSON)
			}
		case providers.ChunkToolUseEnd:
			currentByIndex = -1
		case providers.ChunkThinking:
			var d struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(ch.Payload, &d)
			thinkingText.WriteString(d.Text)
		case providers.ChunkThinkingSignature:
			var d struct {
				Signature string `json:"signature"`
			}
			_ = json.Unmarshal(ch.Payload, &d)
			thinkingBlocks = append(thinkingBlocks, anthropicThinkingBlock{
				Type:      "thinking",
				Thinking:  thinkingText.String(),
				Signature: d.Signature,
			})
			thinkingText.Reset()
		case providers.ChunkDone:
			continue
		case providers.ChunkError:
			_ = forward(ctx, out, ch)
			return roundCapture{}, errors.New("upstream error")
		}
		if ch.Type != providers.ChunkDone {
			if !forward(ctx, out, ch) {
				return roundCapture{}, errors.New("output channel closed")
			}
		}
	}

	calls := make([]providers.ToolUseBlock, 0, len(pending))
	for _, p := range pending {
		raw := p.input.String()
		if raw == "" {
			raw = "{}"
		}
		calls = append(calls, providers.ToolUseBlock{
			ID:             p.ID,
			Name:           p.Name,
			Input:          json.RawMessage(raw),
			ProviderOpaque: p.ProviderOpaque,
		})
	}
	return roundCapture{calls: calls, thinking: thinkingBlocks}, nil
}

func forward(ctx context.Context, out chan<- providers.Chunk, ch providers.Chunk) bool {
	select {
	case out <- ch:
		return true
	case <-ctx.Done():
		return false
	}
}

func emitError(ctx context.Context, out chan<- providers.Chunk, err error) {
	payload, _ := json.Marshal(map[string]string{"message": err.Error()})
	_ = forward(ctx, out, providers.Chunk{Type: providers.ChunkError, Payload: payload})
}
