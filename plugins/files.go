package plugins

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// FilesName is the registered name for the device-files plugin.
const FilesName = "files"

// files exposes a small catalog of tools backed by a folder of
// markdown/text files the user grants access to — read/write via
// filesystem access through a security-scoped bookmark the client
// maintains. An Obsidian vault is the flagship use (content stays
// plain markdown, frontmatter is preserved verbatim), but any notes
// folder works.
//
// Distinct from `app_tools`: same device-tool wire (DeviceToolBroker
// dispatches the call to the connected client) but owns its own tool
// catalog + its own per-tool enabled config. Keeping it separate
// gives the folder its own settings page rather than burying its
// toggles in a long "every device tool" list; future per-folder
// settings (default "scratch" target, frontmatter templates, etc.)
// live cleanly under the `files` plugin config too.
type files struct {
	cfg filesConfig
}

// filesConfig is the per-instance config blob. The Enabled map is
// keyed by tool name; tools not in the map fall back to the per-tool
// `defaultEnabled` so a fresh config starts with sensible reads-on /
// writes-off defaults.
type filesConfig struct {
	Enabled map[string]bool `json:"enabled"`
}

// filesTool describes one tool the model can call. Mirrors the
// shape of devicetools.Tool but lives in this file so the catalog
// stays local to the plugin (no cross-package dependency for
// per-plugin metadata).
type filesTool struct {
	name           string
	displayName    string
	description    string
	inputSchema    string
	defaultEnabled bool
}

var filesCatalog = []filesTool{
	{
		name:           "files_list_notes",
		displayName:    "List notes",
		description:    "List markdown notes in the user's bookmarked folder. Returns relative paths; use files_read_note to fetch contents.",
		inputSchema:    `{"type":"object","properties":{"folder":{"type":"string","description":"Optional folder-relative subfolder to scope to."},"recursive":{"type":"boolean","description":"Recurse into subfolders. Default true."}}}`,
		defaultEnabled: true,
	},
	{
		name:           "files_read_note",
		displayName:    "Read note",
		description:    "Read the full contents of a note in the user's bookmarked folder by its folder-relative path.",
		inputSchema:    `{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}`,
		defaultEnabled: true,
	},
	{
		name:           "files_append_note",
		displayName:    "Append to note",
		description:    "Append content to the end of an existing note, with a blank-line separator. Use for incremental capture (daily logs, scratch notes).",
		inputSchema:    `{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}`,
		defaultEnabled: false,
	},
	{
		name:           "files_create_note",
		displayName:    "Create note",
		description:    "Create a new note at the given folder-relative path. Fails if the file already exists unless overwrite is true.",
		inputSchema:    `{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"overwrite":{"type":"boolean","description":"Default false."}},"required":["path","content"]}`,
		defaultEnabled: false,
	},
	{
		name:           "files_search_text",
		displayName:    "Search notes",
		description:    "Substring search across the user's bookmarked folder. Returns up to `limit` matches with the note path and a short context excerpt.",
		inputSchema:    `{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50,"description":"Max matches. Default 10."}},"required":["query"]}`,
		defaultEnabled: true,
	},
}

func newFiles(configBytes json.RawMessage) (Plugin, error) {
	cfg := filesConfig{}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("files: parse config: %w", err)
		}
	}
	if cfg.Enabled == nil {
		cfg.Enabled = map[string]bool{}
	}
	// Pre-rename configs (the plugin shipped as "obsidian") carry
	// enabled-map keys with the old tool prefix; normalize so stored
	// toggles keep applying. New writes use files_* keys.
	for k, v := range cfg.Enabled {
		if strings.HasPrefix(k, "obsidian_") {
			nk := "files_" + strings.TrimPrefix(k, "obsidian_")
			if _, exists := cfg.Enabled[nk]; !exists {
				cfg.Enabled[nk] = v
			}
			delete(cfg.Enabled, k)
		}
	}
	return &files{cfg: cfg}, nil
}

func init() {
	Register(FilesName, newFiles)
}

func (p *files) Name() string        { return FilesName }
func (p *files) DisplayName() string { return "Files" }

func (p *files) Description() string {
	return "Lets the model read and write markdown notes in a folder " +
		"you grant access to on your device. Works great as an Obsidian " +
		"vault (or a subfolder of one) — content stays plain markdown and " +
		"frontmatter is preserved — but any notes folder works. Backed by " +
		"a security-scoped folder bookmark the client maintains via the " +
		"system file picker; no extra setup required. Tools default to " +
		"read-only; flip writes on per profile."
}

// --- Configurable ---

func (p *files) ConfigFields() []ConfigField {
	out := make([]ConfigField, 0, len(filesCatalog))
	for _, t := range filesCatalog {
		out = append(out, ConfigField{
			Name:        "enabled." + t.name,
			Display:     t.displayName,
			Description: t.description,
			Type:        ConfigFieldBoolean,
			Default:     t.defaultEnabled,
			// All obsidian tools share one category — keeps the
			// form structurally consistent with app_tools even
			// though everything's bundled here.
			Category: "Folder",
		})
	}
	return out
}

// --- ToolProvider ---

func (p *files) Tools() []ToolDef {
	out := make([]ToolDef, 0, len(filesCatalog))
	for _, t := range filesCatalog {
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
func (p *files) ToolsForClient(supported map[string]struct{}) []ToolDef {
	if supported == nil {
		return p.Tools()
	}
	out := make([]ToolDef, 0, len(filesCatalog))
	for _, t := range filesCatalog {
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

func (p *files) isEnabled(t filesTool) bool {
	if v, ok := p.cfg.Enabled[t.name]; ok {
		return v
	}
	return t.defaultEnabled
}

func (p *files) findCatalog(name string) *filesTool {
	for i := range filesCatalog {
		if filesCatalog[i].name == name {
			return &filesCatalog[i]
		}
	}
	return nil
}

func (p *files) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	tool := p.findCatalog(name)
	if tool == nil {
		return ToolResult{}, fmt.Errorf("files: unknown tool %q", name)
	}
	if !p.isEnabled(*tool) {
		return ToolResult{}, fmt.Errorf("files: tool %q is disabled for this profile", name)
	}

	broker := DeviceToolBrokerFrom(ctx)
	if broker == nil {
		return ToolResult{}, fmt.Errorf("files: no DeviceToolBroker in context — server not wired")
	}
	if supported := broker.SupportedTools(ctx); supported != nil {
		if _, ok := supported[name]; !ok {
			return ToolResult{}, fmt.Errorf(
				"files: %q not available — the connected device hasn't bookmarked a notes folder yet "+
					"(open the Psmith app, Settings → Files, pick your folder)",
				name)
		}
	}

	out, err := broker.Invoke(ctx, name, input)
	if err != nil {
		return ToolResult{}, err
	}
	return ToolResult{Output: out}, nil
}
