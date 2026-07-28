// Package plugins implements Psmith's chat-plugin system. A chat plugin is a
// compiled-in unit that can contribute to the system prompt, transform
// outgoing user messages, mutate stored history at prefix-build time, process
// inbound chunk streams, transform stored content for display, and provide
// tools the model can call.
//
// The required Plugin interface is intentionally tiny — name + display name + description.
// Every behavior is a separate opt-in interface, detected by type assertion
// at the call sites that care. A plugin implements as many sub-interfaces
// as it needs.
//
// See docs/design/plugins.md for the full design.
package pluginapi

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// Pipeline is an ordered list of plugin instances resolved for one operation
// (a single SendMessage, history.Build call, or fetch). The order is the
// profile's stored ordinal; every phase iterates in that order.
type Pipeline []Plugin

// Empty reports whether the pipeline has no plugins.
func (p Pipeline) Empty() bool { return len(p) == 0 }

// joinNonEmpty joins the slice with sep, treating an empty slice as "".
func joinNonEmpty(parts []string, sep string) string {
	switch len(parts) {
	case 0:
		return ""
	case 1:
		return parts[0]
	}
	out := parts[0]
	for _, p := range parts[1:] {
		out += sep + p
	}
	return out
}

// ---------------------------------------------------------------------------
// Configuration spec (used by callers to assemble a Pipeline from DB rows).
// ---------------------------------------------------------------------------
