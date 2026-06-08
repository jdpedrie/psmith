package plugins

import (
	"context"
	"encoding/json"
	"fmt"
)

// ObsidianName is the registered name for the Obsidian-vault plugin.
const ObsidianName = "obsidian"

// obsidian exposes a small catalog of tools backed by the user's
// Obsidian vault — read/write markdown notes via filesystem access
// through a security-scoped bookmark the client maintains.
//
// Distinct from `app_tools`: same device-tool wire (DeviceToolBroker
// dispatches the call to the connected client) but owns its own tool
// catalog + its own per-tool enabled config. Keeping it separate
// gives Obsidian its own settings page rather than burying its
// toggles in a long "every device tool" list; future per-vault
// settings (which folder is the default "scratch" target, whether
// to prefix notes with frontmatter, etc.) live cleanly under the
// `obsidian` plugin config too.
type obsidian struct {
	cfg obsidianConfig
}

// obsidianConfig is the per-instance config blob. The Enabled map is
// keyed by tool name; tools not in the map fall back to the per-tool
// `defaultEnabled` so a fresh config starts with sensible reads-on /
// writes-off defaults.
type obsidianConfig struct {
	Enabled map[string]bool `json:"enabled"`
}

// obsidianTool describes one tool the model can call. Mirrors the
// shape of devicetools.Tool but lives in this file so the catalog
// stays local to the plugin (no cross-package dependency for
// per-plugin metadata).
type obsidianTool struct {
	name           string
	displayName    string
	description    string
	inputSchema    string
	defaultEnabled bool
}

var obsidianCatalog = []obsidianTool{
	{
		name:           "obsidian_list_notes",
		displayName:    "List Obsidian notes",
		description:    "List markdown notes in the user's Obsidian vault. Returns relative paths; use obsidian_read_note to fetch contents.",
		inputSchema:    `{"type":"object","properties":{"folder":{"type":"string","description":"Optional vault-relative folder to scope to."},"recursive":{"type":"boolean","description":"Recurse into subfolders. Default true."}}}`,
		defaultEnabled: true,
	},
	{
		name:           "obsidian_read_note",
		displayName:    "Read Obsidian note",
		description:    "Read the full contents of a note in the user's Obsidian vault by its vault-relative path.",
		inputSchema:    `{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}`,
		defaultEnabled: true,
	},
	{
		name:           "obsidian_append_note",
		displayName:    "Append to Obsidian note",
		description:    "Append content to the end of an existing note, with a blank-line separator. Use for incremental capture (daily logs, scratch notes).",
		inputSchema:    `{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}`,
		defaultEnabled: false,
	},
	{
		name:           "obsidian_create_note",
		displayName:    "Create Obsidian note",
		description:    "Create a new note at the given vault-relative path. Fails if the file already exists unless overwrite is true.",
		inputSchema:    `{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"overwrite":{"type":"boolean","description":"Default false."}},"required":["path","content"]}`,
		defaultEnabled: false,
	},
	{
		name:           "obsidian_search_text",
		displayName:    "Search Obsidian vault",
		description:    "Substring search across the user's Obsidian vault. Returns up to `limit` matches with the note path and a short context excerpt.",
		inputSchema:    `{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50,"description":"Max matches. Default 10."}},"required":["query"]}`,
		defaultEnabled: true,
	},
}

func newObsidian(configBytes json.RawMessage) (Plugin, error) {
	cfg := obsidianConfig{}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("obsidian: parse config: %w", err)
		}
	}
	if cfg.Enabled == nil {
		cfg.Enabled = map[string]bool{}
	}
	return &obsidian{cfg: cfg}, nil
}

func init() {
	Register(ObsidianName, newObsidian)
}

func (p *obsidian) Name() string        { return ObsidianName }
func (p *obsidian) DisplayName() string { return "Obsidian" }

func (p *obsidian) Description() string {
	return "Lets the model read and write markdown notes in a folder " +
		"you grant access to — your entire Obsidian vault, or a " +
		"subfolder of it (e.g. just \"Vault/Reeve/\"). Backed by a " +
		"security-scoped folder bookmark the client maintains via the " +
		"system file picker; no Obsidian plugin or local-REST setup " +
		"required. Tools default to read-only; flip writes on per profile."
}

// --- Configurable ---

func (p *obsidian) ConfigFields() []ConfigField {
	out := make([]ConfigField, 0, len(obsidianCatalog))
	for _, t := range obsidianCatalog {
		out = append(out, ConfigField{
			Name:        "enabled." + t.name,
			Display:     t.displayName,
			Description: t.description,
			Type:        ConfigFieldBoolean,
			Default:     t.defaultEnabled,
			// All obsidian tools share one category — keeps the
			// form structurally consistent with app_tools even
			// though everything's bundled here.
			Category: "Vault",
		})
	}
	return out
}

// --- ToolProvider ---

func (p *obsidian) Tools() []ToolDef {
	out := make([]ToolDef, 0, len(obsidianCatalog))
	for _, t := range obsidianCatalog {
		if !p.isEnabled(t) {
			continue
		}
		out = append(out, ToolDef{
			Name:        t.name,
			Description: t.description,
			InputSchema: []byte(t.inputSchema),
		})
	}
	return out
}

// ToolsForClient filters further to the connected client's
// supported set — same shape app_tools exposes for the same reason
// (don't surface obsidian tools to the model when no client is
// holding a vault bookmark).
func (p *obsidian) ToolsForClient(supported map[string]struct{}) []ToolDef {
	if supported == nil {
		return p.Tools()
	}
	out := make([]ToolDef, 0, len(obsidianCatalog))
	for _, t := range obsidianCatalog {
		if !p.isEnabled(t) {
			continue
		}
		if _, ok := supported[t.name]; !ok {
			continue
		}
		out = append(out, ToolDef{
			Name:        t.name,
			Description: t.description,
			InputSchema: []byte(t.inputSchema),
		})
	}
	return out
}

func (p *obsidian) isEnabled(t obsidianTool) bool {
	if v, ok := p.cfg.Enabled[t.name]; ok {
		return v
	}
	return t.defaultEnabled
}

func (p *obsidian) findCatalog(name string) *obsidianTool {
	for i := range obsidianCatalog {
		if obsidianCatalog[i].name == name {
			return &obsidianCatalog[i]
		}
	}
	return nil
}

func (p *obsidian) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	tool := p.findCatalog(name)
	if tool == nil {
		return ToolResult{}, fmt.Errorf("obsidian: unknown tool %q", name)
	}
	if !p.isEnabled(*tool) {
		return ToolResult{}, fmt.Errorf("obsidian: tool %q is disabled for this profile", name)
	}

	broker := DeviceToolBrokerFrom(ctx)
	if broker == nil {
		return ToolResult{}, fmt.Errorf("obsidian: no DeviceToolBroker in context — server not wired")
	}
	if supported := broker.SupportedTools(ctx); supported != nil {
		if _, ok := supported[name]; !ok {
			return ToolResult{}, fmt.Errorf(
				"obsidian: %q not available — the connected device hasn't bookmarked an Obsidian vault yet "+
					"(open the Reeve app, Settings → Obsidian, pick your vault folder)",
				name)
		}
	}

	out, err := broker.Invoke(ctx, name, input)
	if err != nil {
		return ToolResult{}, err
	}
	return ToolResult{Output: out}, nil
}
