// Package plugins implements Clark's chat-plugin system. A chat plugin is a
// compiled-in unit that can contribute to the system prompt, transform
// outgoing user messages, mutate stored history at prefix-build time, process
// inbound chunk streams, transform stored content for display, and provide
// tools the model can call.
//
// The required Plugin interface is intentionally tiny — name + description.
// Every behavior is a separate opt-in interface, detected by type assertion
// at the call sites that care. A plugin implements as many sub-interfaces
// as it needs.
//
// See "Chat plugins" in docs/architecture.md for the full design.
package plugins

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"

	"github.com/jdpedrie/clark/internal/providers"
)

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// Plugin is the minimum shape every plugin satisfies. Behavior comes from
// optional sub-interfaces declared below.
type Plugin interface {
	Name() string
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

// ConfigFieldType is the small enumeration of input shapes supported by the
// UI form-builder. The plugin's constructor remains the authoritative
// validator at runtime; ConfigFields is only a hint to render a form.
type ConfigFieldType string

const (
	ConfigFieldNumber   ConfigFieldType = "number"
	ConfigFieldText     ConfigFieldType = "text"
	ConfigFieldTextarea ConfigFieldType = "textarea"
	ConfigFieldBoolean  ConfigFieldType = "boolean"
	ConfigFieldSelect   ConfigFieldType = "select"
)

// ConfigField describes one entry in a plugin's per-instance config shape.
// The list is flat — there's no nesting. Default is JSON-marshaled when
// shipped over the wire; nil means "no default."
type ConfigField struct {
	Name        string
	Display     string
	Description string
	Type        ConfigFieldType
	Default     any            // JSON-marshaled when sent over the wire; nil = no default
	Options     []ConfigOption // only when Type==ConfigFieldSelect
}

// ConfigOption is one entry in a select field's options list.
type ConfigOption struct {
	Value string
	Label string
}

// Configurable lets the system introspect the plugin's per-instance config
// shape. Plugins without configuration don't implement this.
type Configurable interface {
	// ConfigFields returns a flat list of typed fields describing the config
	// blob the constructor accepts. Used by UIs to render config forms; the
	// constructor remains the source of truth for runtime validation.
	ConfigFields() []ConfigField
}

// SystemPrompter contributes to the system slot at prefix-build time.
type SystemPrompter interface {
	// PrependSystemMessage returns text prepended to the system slot.
	// Empty string means "no contribution."
	PrependSystemMessage() string
	// AppendSystemMessage returns text appended to the system slot.
	// Empty string means "no contribution."
	AppendSystemMessage() string
}

// OutgoingUserTransformer rewrites the user's outgoing content in
// SendMessage before the row is persisted, so future renders + history
// builds see the transformed form.
type OutgoingUserTransformer interface {
	TransformOutgoingUserMessage(content string) string
}

// HistoryPos tells a HistoryTransformer where the message sits relative to
// the head of the prefix being built. Both ranks are 0-indexed from the head.
//
//   - FromHead counts ALL messages back. The head (the message about to
//     elicit a response) is FromHead=0; its parent is 1; etc.
//   - FromHeadSameRole counts only messages with the same wire role. The
//     most-recent message of this role is FromHeadSameRole=0; the next is 1;
//     etc. This is the right metric for "keep choices on the last N
//     assistant turns" — independent of how user/assistant rows interleave
//     (which can vary under forks or future tool-use additions).
type HistoryPos struct {
	FromHead         int
	FromHeadSameRole int
}

// HistoryTransformer mutates a history message at prefix-build time.
// Returning the message unchanged is fine; the plugin decides based on
// position whether to apply.
type HistoryTransformer interface {
	TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage
}

// ChunkTransformer is a stream processor running inside the supervisor.
// NewInboundProcessor returns a fresh per-stream instance so internal state
// is isolated.
type ChunkTransformer interface {
	NewInboundProcessor() InboundProcessor
}

// InboundProcessor processes one stream's chunks. Process may return zero or
// more output chunks per input (buffering is allowed). Close emits any
// buffered residue at stream end.
type InboundProcessor interface {
	Process(providers.Chunk) []providers.Chunk
	Close() []providers.Chunk
}

// DisplayTransformer rewrites stored content for display at message-fetch
// time. Position-independent — same input always yields the same output for
// a given plugin config.
type DisplayTransformer interface {
	TransformForDisplay(content string) string
}

// ToolProvider declares callable tools and executes them. The runtime
// collects Tools() across active plugins to build the wire tools array;
// when the model emits a tool_use, the runtime dispatches ExecuteTool to
// the plugin owning that tool name.
type ToolProvider interface {
	Tools() []ToolDef
	ExecuteTool(ctx context.Context, name string, input json.RawMessage) (json.RawMessage, error)
}

// ToolDef describes a single callable tool. InputSchema is the raw JSON
// Schema the provider expects on its tools field.
type ToolDef struct {
	Name        string
	Description string
	InputSchema []byte
}

// ---------------------------------------------------------------------------
// Registry.
// ---------------------------------------------------------------------------

// registry is the package-level registry of constructors keyed by plugin name.
// Concrete plugins call Register in their init() so importing the package
// makes them available.
var (
	regMu sync.RWMutex
	reg   = map[string]Constructor{}
)

// Register adds a constructor under the given name. Panics on duplicate
// registration so import-order bugs surface immediately.
func Register(name string, ctor Constructor) {
	if name == "" {
		panic("plugins: empty plugin name")
	}
	if ctor == nil {
		panic("plugins: nil constructor for " + name)
	}
	regMu.Lock()
	defer regMu.Unlock()
	if _, ok := reg[name]; ok {
		panic("plugins: duplicate registration for " + name)
	}
	reg[name] = ctor
}

// Build instantiates the plugin registered under name with the given config.
func Build(name string, configBytes json.RawMessage) (Plugin, error) {
	regMu.RLock()
	ctor, ok := reg[name]
	regMu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("plugins: no plugin registered as %q", name)
	}
	return ctor(configBytes)
}

// ListRegistered returns the names of all currently-registered plugins, in
// no particular order.
func ListRegistered() []string {
	regMu.RLock()
	defer regMu.RUnlock()
	out := make([]string, 0, len(reg))
	for name := range reg {
		out = append(out, name)
	}
	return out
}

// resetRegistryForTest clears the registry. Tests use this from a single
// helper to keep the package-global state from leaking between tests.
// Never call from production code.
func resetRegistryForTest() {
	regMu.Lock()
	defer regMu.Unlock()
	reg = map[string]Constructor{}
}

// ---------------------------------------------------------------------------
// Pipeline.
// ---------------------------------------------------------------------------

// Pipeline is an ordered list of plugin instances resolved for one operation
// (a single SendMessage, history.Build call, or fetch). The order is the
// profile's stored ordinal; every phase iterates in that order.
type Pipeline []Plugin

// Empty reports whether the pipeline has no plugins.
func (p Pipeline) Empty() bool { return len(p) == 0 }

// SystemPrompts walks the pipeline and concatenates the prepend/append
// contributions of every SystemPrompter, joining individual contributions
// with newlines. Returns ("", "") for a pipeline without SystemPrompters.
func (p Pipeline) SystemPrompts() (prepend, appendStr string) {
	var prep, app []string
	for _, pl := range p {
		sp, ok := pl.(SystemPrompter)
		if !ok {
			continue
		}
		if s := sp.PrependSystemMessage(); s != "" {
			prep = append(prep, s)
		}
		if s := sp.AppendSystemMessage(); s != "" {
			app = append(app, s)
		}
	}
	prepend = joinNonEmpty(prep, "\n\n")
	appendStr = joinNonEmpty(app, "\n\n")
	return
}

// TransformOutgoingUser walks the pipeline, applying every
// OutgoingUserTransformer in order. Plugins that don't implement the
// interface are skipped.
func (p Pipeline) TransformOutgoingUser(content string) string {
	for _, pl := range p {
		if t, ok := pl.(OutgoingUserTransformer); ok {
			content = t.TransformOutgoingUserMessage(content)
		}
	}
	return content
}

// TransformHistoryMessage walks the pipeline, applying every
// HistoryTransformer in order to the given message at the given position.
// Plugins that don't implement the interface are skipped.
func (p Pipeline) TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage {
	for _, pl := range p {
		if t, ok := pl.(HistoryTransformer); ok {
			msg = t.TransformHistoryMessage(msg, pos)
		}
	}
	return msg
}

// TransformForDisplay walks the pipeline, applying every DisplayTransformer
// in order to content.
func (p Pipeline) TransformForDisplay(content string) string {
	for _, pl := range p {
		if t, ok := pl.(DisplayTransformer); ok {
			content = t.TransformForDisplay(content)
		}
	}
	return content
}

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

// Spec is one row in a profile's plugin pipeline. Callers (the conversations
// service) load these from profile_plugins, walking parent chain for
// inheritance, and pass them to Resolve.
type Spec struct {
	Name   string
	Config json.RawMessage
}

// Resolve constructs a Pipeline from an ordered list of specs. Returns the
// first construction error encountered, with the offending spec name in the
// message.
func Resolve(specs []Spec) (Pipeline, error) {
	if len(specs) == 0 {
		return nil, nil
	}
	out := make(Pipeline, 0, len(specs))
	for _, s := range specs {
		pl, err := Build(s.Name, s.Config)
		if err != nil {
			return nil, fmt.Errorf("plugins: build %q: %w", s.Name, err)
		}
		out = append(out, pl)
	}
	return out, nil
}

// ErrUnknownPlugin is returned by Build when the plugin name isn't registered.
// Wrap-compatible via errors.Is.
var ErrUnknownPlugin = errors.New("plugins: unknown plugin")

// ---------------------------------------------------------------------------
// Type introspection.
// ---------------------------------------------------------------------------

// Capabilities reports which opt-in interfaces a plugin implements. Used by
// UIs to decide which config knobs to expose, and by the server to skip
// phases a plugin doesn't participate in.
type Capabilities struct {
	Configurable            bool
	SystemPrompter          bool
	OutgoingUserTransformer bool
	HistoryTransformer      bool
	ChunkTransformer        bool
	DisplayTransformer      bool
	ToolProvider            bool
}

// TypeDescriptor is the introspectable metadata for one registered plugin.
// Returned by Describe and DescribeAll for use by management RPCs.
type TypeDescriptor struct {
	Name         string
	Description  string
	ConfigFields []ConfigField // empty unless the plugin implements Configurable
	Capabilities Capabilities
}

// Describe instantiates the plugin with a nil config (the Constructor
// contract requires nil to be accepted) and reports its name, description,
// capability set, and config field descriptors.
func Describe(name string) (TypeDescriptor, error) {
	inst, err := Build(name, nil)
	if err != nil {
		return TypeDescriptor{}, err
	}
	desc := TypeDescriptor{
		Name:        inst.Name(),
		Description: inst.Description(),
	}
	if c, ok := inst.(Configurable); ok {
		desc.Capabilities.Configurable = true
		desc.ConfigFields = c.ConfigFields()
	}
	if _, ok := inst.(SystemPrompter); ok {
		desc.Capabilities.SystemPrompter = true
	}
	if _, ok := inst.(OutgoingUserTransformer); ok {
		desc.Capabilities.OutgoingUserTransformer = true
	}
	if _, ok := inst.(HistoryTransformer); ok {
		desc.Capabilities.HistoryTransformer = true
	}
	if _, ok := inst.(ChunkTransformer); ok {
		desc.Capabilities.ChunkTransformer = true
	}
	if _, ok := inst.(DisplayTransformer); ok {
		desc.Capabilities.DisplayTransformer = true
	}
	if _, ok := inst.(ToolProvider); ok {
		desc.Capabilities.ToolProvider = true
	}
	return desc, nil
}

// DescribeAll returns a TypeDescriptor for every registered plugin. The
// order is unspecified; callers that want stable ordering should sort by
// Name themselves.
func DescribeAll() ([]TypeDescriptor, error) {
	names := ListRegistered()
	out := make([]TypeDescriptor, 0, len(names))
	for _, n := range names {
		d, err := Describe(n)
		if err != nil {
			return nil, fmt.Errorf("describe %q: %w", n, err)
		}
		out = append(out, d)
	}
	return out, nil
}
