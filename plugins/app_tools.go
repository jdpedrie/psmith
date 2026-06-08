package plugins

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jdpedrie/reeve/internal/devicetools"
)

// AppToolsName is the registered name for the device-tools plugin.
// "app_tools" reads more naturally to the user than "device_tools" —
// it's "apps on your device the model can talk to" (Calendar,
// Obsidian, etc.) rather than the abstract "device tool" plumbing.
const AppToolsName = "app_tools"

// appTools exposes the server-side catalog of device tools to the
// model, filtered by:
//
//   1. The plugin's per-tool `enabled` config (per-profile, with
//      the usual parent→child→conversation merge chain).
//   2. The currently-connected client's advertised supported set
//      (so iOS-only tools like HealthKit don't appear when only a
//      Mac is connected, and vice versa).
//   3. The server-side catalog itself (the source of truth — a
//      tool not in the catalog can never be exposed even if some
//      stale config says enabled).
//
// ExecuteTool routes the call through the DeviceToolBroker, which
// emits a CHUNK_TYPE_DEVICE_TOOL_USE chunk and blocks until the
// client POSTs a response back. The model sees the result as an
// ordinary tool_result chunk on the next round.
type appTools struct {
	cfg appToolsConfig
}

// appToolsConfig is the per-instance config blob. The Enabled map
// is keyed by tool name; tools not in the map fall back to the
// catalog's per-tool DefaultEnabled flag so a freshly-added tool
// can ship with a sensible default without forcing every existing
// profile to re-save.
type appToolsConfig struct {
	// Enabled is a per-tool-name on/off override. When a tool
	// name isn't in the map, the catalog's DefaultEnabled wins.
	// Explicit false beats catalog-default-true (the user said no).
	Enabled map[string]bool `json:"enabled"`
}

func newAppTools(configBytes json.RawMessage) (Plugin, error) {
	cfg := appToolsConfig{}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("app_tools: parse config: %w", err)
		}
	}
	if cfg.Enabled == nil {
		cfg.Enabled = map[string]bool{}
	}
	return &appTools{cfg: cfg}, nil
}

func init() {
	Register(AppToolsName, newAppTools)
}

func (p *appTools) Name() string        { return AppToolsName }
func (p *appTools) DisplayName() string { return "App Tools" }

func (p *appTools) Description() string {
	return "Lets the model call apps on your device — Calendar, Reminders, " +
		"your Obsidian vault, etc. Each tool is opt-in per profile; the " +
		"connected device's OS permission grant still has to be in place " +
		"for a call to succeed."
}

// --- Configurable ---

// ConfigFields returns one boolean per catalog tool. The UI renders
// a checkbox per row; the user toggles the tools they want their
// model to be able to call within this profile. Tools the
// connected client doesn't support stay clickable here — the user
// might switch devices later, and we don't want to silently drop
// their preference.
func (p *appTools) ConfigFields() []ConfigField {
	tools := devicetools.All()
	out := make([]ConfigField, 0, len(tools))
	for _, t := range tools {
		out = append(out, ConfigField{
			Name:        "enabled." + t.Name,
			Display:     t.DisplayName,
			Description: t.Description,
			Type:        ConfigFieldBoolean,
			Default:     t.DefaultEnabled,
			Category:    t.Category,
		})
	}
	return out
}

// --- ToolProvider ---

func (p *appTools) Tools() []ToolDef {
	// Without a ctx we can't ask the broker which tools the client
	// supports — so Tools() returns the full enabled-intersect-
	// catalog set and ExecuteTool handles the "not supported"
	// case at call time with a clear error. This matches how the
	// memory plugin handles a missing Searcher.
	tools := devicetools.All()
	out := make([]ToolDef, 0, len(tools))
	for _, t := range tools {
		if !p.isEnabled(t) {
			continue
		}
		out = append(out, ToolDef{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: []byte(t.InputSchema),
		})
	}
	return out
}

// ToolsForClient is a richer Tools() the conversations side calls
// with the connected client's supported set in hand. Filters the
// enabled-intersect-catalog further so the model never sees defs
// for tools the device can't run. Falls back to Tools() (no
// client filter) when supported is nil — covers the "no client
// has registered yet" case at startup.
//
// The supervisor calls this from collectPipelineTools when it
// detects an app_tools plugin in the pipeline; other ToolProvider
// plugins are unaffected.
func (p *appTools) ToolsForClient(supported map[string]struct{}) []ToolDef {
	if supported == nil {
		return p.Tools()
	}
	tools := devicetools.All()
	out := make([]ToolDef, 0, len(tools))
	for _, t := range tools {
		if !p.isEnabled(t) {
			continue
		}
		if _, ok := supported[t.Name]; !ok {
			continue
		}
		out = append(out, ToolDef{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: []byte(t.InputSchema),
		})
	}
	return out
}

func (p *appTools) isEnabled(t devicetools.Tool) bool {
	if v, ok := p.cfg.Enabled[t.Name]; ok {
		return v
	}
	return t.DefaultEnabled
}

func (p *appTools) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	tool := devicetools.Find(name)
	if tool == nil {
		return ToolResult{}, fmt.Errorf("app_tools: unknown tool %q", name)
	}
	if !p.isEnabled(*tool) {
		return ToolResult{}, fmt.Errorf("app_tools: tool %q is disabled for this profile", name)
	}

	broker := DeviceToolBrokerFrom(ctx)
	if broker == nil {
		return ToolResult{}, fmt.Errorf("app_tools: no DeviceToolBroker in context — server not wired")
	}
	if supported := broker.SupportedTools(ctx); supported != nil {
		if _, ok := supported[name]; !ok {
			return ToolResult{}, fmt.Errorf("app_tools: tool %q is not supported by the connected device", name)
		}
	}

	out, err := broker.Invoke(ctx, name, input)
	if err != nil {
		return ToolResult{}, err
	}
	return ToolResult{Output: out}, nil
}
