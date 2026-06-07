package plugins

import (
	"context"
	"encoding/json"
)

// DeviceToolBroker is the runtime-injected dependency the
// `app_tools` plugin uses to dispatch a tool call out to the
// connected client (iOS / Mac) for native-API execution. The
// conversations service builds a per-call binding (chunk channel +
// conversation id + the underlying broker) and attaches it via
// WithDeviceToolBroker; the plugin reads it at ExecuteTool time
// via DeviceToolBrokerFrom.
//
// Interface (rather than the concrete devicetools.Broker) so
// plugin tests can mock it without standing up chunk routing or
// the HTTP respond endpoint.
type DeviceToolBroker interface {
	// Invoke fires a tool call at the connected client and blocks
	// until either a response arrives, the per-tool timeout
	// fires, or ctx is cancelled. Returns the client's structured
	// output on success, or a wrapped error (permission denied,
	// transport failure, malformed input) that the tool loop will
	// surface to the model.
	Invoke(ctx context.Context, toolName string, input json.RawMessage) (json.RawMessage, error)

	// SupportedTools returns the set of tool names the
	// currently-connected client has advertised it can fulfill.
	// The plugin intersects this with its enabled set + the
	// server catalog when building Tools() so the model never
	// sees defs for tools the device can't run. nil = no client
	// has registered yet → no device tools available.
	SupportedTools(ctx context.Context) map[string]struct{}
}

type deviceToolBrokerKey struct{}

// WithDeviceToolBroker attaches a broker to ctx. Called by the
// dispatch site right before invoking the owning plugin's
// ExecuteTool. nil is a no-op.
func WithDeviceToolBroker(ctx context.Context, b DeviceToolBroker) context.Context {
	if b == nil {
		return ctx
	}
	return context.WithValue(ctx, deviceToolBrokerKey{}, b)
}

// DeviceToolBrokerFrom returns the broker attached to ctx, or nil
// if the runtime didn't wire one. Plugins should treat nil as
// "device tools are not configured" and report a friendly
// tool-error.
func DeviceToolBrokerFrom(ctx context.Context) DeviceToolBroker {
	v, _ := ctx.Value(deviceToolBrokerKey{}).(DeviceToolBroker)
	return v
}
