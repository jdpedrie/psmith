// Package pluginapi is Psmith's chat-plugin contract. A chat plugin is a
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

import (
	"encoding/json"

	"github.com/jdpedrie/psmith/server/providers"
)

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// Plugin is the minimum shape every plugin satisfies. Behavior comes from
// optional sub-interfaces declared below.
//
//   - Name is the stable machine identifier (e.g. `brave_search`). Used as
//     the primary key in profile_plugins / user_plugin_settings rows; do
//     not change between releases.
//   - DisplayName is the human-friendly label (e.g. `Brave Search`)
//     rendered everywhere in the UI. Free to evolve over time.
//   - Description is the one-paragraph blurb shown next to the display name.
type Plugin interface {
	Name() string
	DisplayName() string
	Description() string
}

// Constructor builds a plugin instance from its per-instance config blob.
// configBytes may be nil/empty for plugins that take no configuration.
//
// Constructors must accept a nil/empty config blob and return a usable
// instance with default values populated. Describe relies on this contract
// to introspect plugin metadata (capabilities + ConfigFields) without
// needing a hand-crafted sample config per plugin.
type Constructor func(configBytes json.RawMessage) (Plugin, error)

// ---------------------------------------------------------------------------
// Opt-in capability interfaces.
// ---------------------------------------------------------------------------

// WireMessage and Chunk are the provider-protocol types that cross the plugin
// boundary — HistoryTransformer rewrites the first, ChunkTransformer processes
// the second. Aliased rather than redefined so there is exactly one definition
// in the tree, and named here so the contract reads as a single vocabulary
// instead of making plugin authors reach into the server packages.
//
// They are re-exported API: changing the underlying structs in server/providers
// breaks out-of-tree plugins, with nothing in that package to say so.
type (
	WireMessage = providers.WireMessage
	Chunk       = providers.Chunk
)
