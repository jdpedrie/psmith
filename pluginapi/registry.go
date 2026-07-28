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

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
)

// ---------------------------------------------------------------------------
// Required core interface.
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

// IsRegistered reports whether a plugin is registered under `name`.
// Cheaper than Build when callers only need to validate the name
// (e.g., accepting a disabled = true row whose config is irrelevant).
func IsRegistered(name string) bool {
	regMu.RLock()
	defer regMu.RUnlock()
	_, ok := reg[name]
	return ok
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
	Configurable   bool
	SystemPrompter bool
	// MessageEnvelope: contributes persisted header/trailer blocks to
	// outgoing user messages. Rides the proto's legacy
	// `outgoing_user_transformer` field — same meaning ("this plugin
	// touches the outgoing user message"), stable field number.
	MessageEnvelope             bool
	HistoryTransformer          bool
	ChunkTransformer            bool
	DisplayTransformer          bool
	ToolProvider                bool
	AssistantContentTransformer bool
	MessageLifecycleHook        bool
	DeviceFactRequester         bool
	ContentRenderer             bool
}

// ModelCapabilityRequirements is the set of model capabilities a plugin needs
// from the conversation's assigned model in order to function. Sparse: any
// field left false is "no requirement here." Multiple plugins on a profile
// OR together (Combine).
//
// Distinct from `Capabilities` above (which-interfaces-a-plugin-implements).
// Mirrors the field set on the proto `ModelCapabilities` so a server-side
// check is a straight field-by-field implication test.
type ModelCapabilityRequirements struct {
	Streaming       bool
	Thinking        bool
	ToolUse         bool
	Vision          bool
	PromptCaching   bool
	GeneratesImages bool
}

// Combine returns the union — every requirement set on either input is set on
// the result. Used to roll up an entire pipeline's requirements.
func (r ModelCapabilityRequirements) Combine(o ModelCapabilityRequirements) ModelCapabilityRequirements {
	return ModelCapabilityRequirements{
		Streaming:       r.Streaming || o.Streaming,
		Thinking:        r.Thinking || o.Thinking,
		ToolUse:         r.ToolUse || o.ToolUse,
		Vision:          r.Vision || o.Vision,
		PromptCaching:   r.PromptCaching || o.PromptCaching,
		GeneratesImages: r.GeneratesImages || o.GeneratesImages,
	}
}

// Names returns the field names that are set to true, in stable order.
// Useful for human-facing error messages ("model lacks: tool_use, vision").
func (r ModelCapabilityRequirements) Names() []string {
	var out []string
	if r.Streaming {
		out = append(out, "streaming")
	}
	if r.Thinking {
		out = append(out, "thinking")
	}
	if r.ToolUse {
		out = append(out, "tool_use")
	}
	if r.Vision {
		out = append(out, "vision")
	}
	if r.PromptCaching {
		out = append(out, "prompt_caching")
	}
	if r.GeneratesImages {
		out = append(out, "generates_images")
	}
	return out
}

// CapabilityRequirer is implemented by plugins that need specific model
// capabilities to function (e.g. an image-generating plugin needs
// `GeneratesImages`). Plugins that only need ToolUse don't need to implement
// this — Describe auto-derives ToolUse from the ToolProvider interface.
type CapabilityRequirer interface {
	RequiredModelCapabilities() ModelCapabilityRequirements
}

// TypeDescriptor is the introspectable metadata for one registered plugin.
// Returned by Describe and DescribeAll for use by management RPCs.
type TypeDescriptor struct {
	Name         string
	DisplayName  string
	Description  string
	ConfigFields []ConfigField // empty unless the plugin implements Configurable
	Capabilities Capabilities
	// Empty unless the plugin implements DeviceFactRequester. The
	// client uses this to know which on-device facts to gather
	// before each SendMessage; absent keys mean "no need to ask
	// the OS for permission for this fact".
	RequestedDeviceFacts []string
	// Model capabilities the plugin needs from the conversation's
	// assigned model. Auto-derives ToolUse from the ToolProvider
	// interface; additional requirements come from the
	// CapabilityRequirer interface.
	RequiredModelCapabilities ModelCapabilityRequirements
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
		DisplayName: inst.DisplayName(),
		Description: inst.Description(),
	}
	if c, ok := inst.(Configurable); ok {
		desc.Capabilities.Configurable = true
		desc.ConfigFields = c.ConfigFields()
	}
	if _, ok := inst.(SystemPrompter); ok {
		desc.Capabilities.SystemPrompter = true
	}
	if _, ok := inst.(MessageEnvelope); ok {
		desc.Capabilities.MessageEnvelope = true
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
		// A plugin that exposes tools necessarily needs the
		// model to support tool calls. Auto-derive — saves every
		// tool-providing plugin from re-declaring it via
		// CapabilityRequirer.
		desc.RequiredModelCapabilities.ToolUse = true
	}
	if _, ok := inst.(AssistantContentTransformer); ok {
		desc.Capabilities.AssistantContentTransformer = true
	}
	if _, ok := inst.(MessageLifecycleHook); ok {
		desc.Capabilities.MessageLifecycleHook = true
	}
	if _, ok := inst.(ContentRenderer); ok {
		desc.Capabilities.ContentRenderer = true
	}
	if r, ok := inst.(DeviceFactRequester); ok {
		desc.Capabilities.DeviceFactRequester = true
		desc.RequestedDeviceFacts = r.RequestedDeviceFacts()
	}
	if r, ok := inst.(CapabilityRequirer); ok {
		// Combine with the auto-derived ToolUse requirement above
		// so a plugin can both expose tools and declare extras
		// (e.g. an image-generating tool plugin needs ToolUse +
		// GeneratesImages).
		desc.RequiredModelCapabilities = desc.RequiredModelCapabilities.Combine(r.RequiredModelCapabilities())
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

// Empty reports whether no requirement is set — every field is false.
func (r ModelCapabilityRequirements) Empty() bool {
	return r == ModelCapabilityRequirements{}
}
