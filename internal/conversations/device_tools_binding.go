package conversations

import (
	"context"
	"encoding/json"

	"github.com/google/uuid"

	"github.com/jdpedrie/spalt/internal/devicetools"
	"github.com/jdpedrie/spalt/plugins"
)

// deviceToolBinding adapts the in-memory devicetools.Broker +
// Registry into the plugins.DeviceToolBroker interface a per-call
// ExecuteTool sees via ctx. One instance per run — the `emit`
// closure binds to the run's chunk channel so the device-tool
// chunk lands on the same wire as everything else.
//
// emitToWire is the function the conversations side passes in;
// it serializes a devicetools.Request as JSON and writes a
// CHUNK_TYPE_DEVICE_TOOL_USE chunk into the run's outgoing
// channel. Mirrors how elicit's emitChunk plumbing works.
type deviceToolBinding struct {
	broker         *devicetools.Broker
	registry       *devicetools.Registry
	userID         uuid.UUID
	conversationID uuid.UUID
	emitToWire     func(req devicetools.Request)
}

func newDeviceToolBinding(
	broker *devicetools.Broker,
	registry *devicetools.Registry,
	userID, conversationID uuid.UUID,
	emit func(devicetools.Request),
) plugins.DeviceToolBroker {
	if broker == nil || registry == nil {
		return nil
	}
	return &deviceToolBinding{
		broker:         broker,
		registry:       registry,
		userID:         userID,
		conversationID: conversationID,
		emitToWire:     emit,
	}
}

// Invoke fires a tool call at the connected client through the
// broker. The 0 timeout = use DefaultTimeout (60s).
func (b *deviceToolBinding) Invoke(ctx context.Context, toolName string, input json.RawMessage) (json.RawMessage, error) {
	return b.broker.Invoke(ctx, b.conversationID, toolName, input, 0, b.emitToWire)
}

// SupportedTools reads the (user, conversation) entry plus the
// (user, nil) entry — clients today register per-user (no
// conversation id available at handshake), so the nil-conversation
// fallback is where the live entry is. Forward-compat for the day
// per-conversation registration lands.
func (b *deviceToolBinding) SupportedTools(_ context.Context) map[string]struct{} {
	if perConvo := b.registry.SupportedSet(b.userID, b.conversationID); perConvo != nil {
		return perConvo
	}
	return b.registry.SupportedSet(b.userID, uuid.Nil)
}
