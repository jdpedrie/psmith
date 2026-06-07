package devicetools

import "sort"

// Catalog is the canonical list of every device-tool the server
// knows how to dispatch. Hand-curated — adding a tool means a server
// release. Client-side implementation lives in iOS / Mac code keyed
// by Tool.Name.
//
// Stored as a package-level slice rather than a registry-with-init
// because the catalog is small and reviewing the full surface in one
// file makes "what can the model do on my phone?" easy to audit.

// Tool is one entry in the catalog. JSON Schema lives as a raw
// string so the file stays readable; the server marshals it as
// bytes when assembling the model-facing ToolDef.
type Tool struct {
	// Name is the wire-stable identifier the model calls and the
	// client's handler key. Never renamed.
	Name string
	// DisplayName is the human-readable label rendered in
	// settings UIs and on per-call audit rows.
	DisplayName string
	// Description is the one-paragraph tool description the model
	// sees. Tuned for clarity to the model, not the user.
	Description string
	// Category is the UI grouping ("Calendar", "Reminders",
	// "Obsidian", "Contacts", …). Stable across releases.
	Category string
	// InputSchema is the JSON Schema for the tool's `input`
	// payload. Pure schema text; embedded into ToolDef as bytes.
	InputSchema string
	// RequiredPermissions is the list of OS / app permissions the
	// client needs at runtime. Free-form strings consumed by the
	// settings UI ("calendar", "reminders", "files.bookmark:obsidian").
	RequiredPermissions []string
	// DefaultEnabled is whether the tool starts toggled-on in a
	// fresh app_tools plugin config. Conservative defaults — read-
	// only tools (calendar_list_events, obsidian_read_note) default
	// on once the OS permission is granted; mutating tools default
	// off to avoid the model writing without explicit user consent.
	DefaultEnabled bool
}

// catalog is the in-memory source-of-truth. Edit this slice to add
// or remove tools. Order doesn't matter — All() returns a name-
// sorted copy.
var catalog = []Tool{
	{
		Name:                "calendar_list_events",
		DisplayName:         "List calendar events",
		Category:            "Calendar",
		Description:         "List events from the user's calendars between two ISO-8601 dates. Use to answer questions about today, upcoming meetings, or past events. Returns events with title, start/end times, location, and notes.",
		InputSchema:         `{"type":"object","properties":{"start_date":{"type":"string","description":"ISO-8601 timestamp; events ending on or after this are included."},"end_date":{"type":"string","description":"ISO-8601 timestamp; events starting on or before this are included."},"calendar":{"type":"string","description":"Optional calendar title to filter to a single calendar."}},"required":["start_date","end_date"]}`,
		RequiredPermissions: []string{"calendar"},
		DefaultEnabled:      true,
	},
	{
		Name:                "calendar_create_event",
		DisplayName:         "Create calendar event",
		Category:            "Calendar",
		Description:         "Create a new event in the user's calendar. Use when the user explicitly asks to schedule something. Confirm details with the user before calling if there's any ambiguity.",
		InputSchema:         `{"type":"object","properties":{"title":{"type":"string"},"start":{"type":"string","description":"ISO-8601 timestamp."},"end":{"type":"string","description":"ISO-8601 timestamp."},"location":{"type":"string"},"notes":{"type":"string"},"calendar":{"type":"string","description":"Calendar title; defaults to the user's default calendar if omitted."}},"required":["title","start","end"]}`,
		RequiredPermissions: []string{"calendar"},
		DefaultEnabled:      false,
	},
	{
		Name:                "calendar_update_event",
		DisplayName:         "Update calendar event",
		Category:            "Calendar",
		Description:         "Modify an existing event. Use the event's id returned by calendar_list_events. Only fields you provide are updated.",
		InputSchema:         `{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},"location":{"type":"string"},"notes":{"type":"string"}},"required":["id"]}`,
		RequiredPermissions: []string{"calendar"},
		DefaultEnabled:      false,
	},
	{
		Name:                "calendar_delete_event",
		DisplayName:         "Delete calendar event",
		Category:            "Calendar",
		Description:         "Delete an event from the user's calendar. Confirm with the user before calling.",
		InputSchema:         `{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}`,
		RequiredPermissions: []string{"calendar"},
		DefaultEnabled:      false,
	},

	{
		Name:                "reminders_list",
		DisplayName:         "List reminders",
		Category:            "Reminders",
		Description:         "List the user's reminders. Optionally filter to a list or by completion status.",
		InputSchema:         `{"type":"object","properties":{"list":{"type":"string","description":"Reminders list title; omit to span all lists."},"completed":{"type":"boolean","description":"Filter to completed (true) or pending (false). Omit for both."}}}`,
		RequiredPermissions: []string{"reminders"},
		DefaultEnabled:      true,
	},
	{
		Name:                "reminders_create",
		DisplayName:         "Create reminder",
		Category:            "Reminders",
		Description:         "Add a new reminder. Use when the user asks to be reminded of something.",
		InputSchema:         `{"type":"object","properties":{"title":{"type":"string"},"due_date":{"type":"string","description":"ISO-8601 timestamp; optional."},"list":{"type":"string","description":"Target list; defaults to the user's default."},"notes":{"type":"string"}},"required":["title"]}`,
		RequiredPermissions: []string{"reminders"},
		DefaultEnabled:      false,
	},
	{
		Name:                "reminders_complete",
		DisplayName:         "Complete reminder",
		Category:            "Reminders",
		Description:         "Mark a reminder as completed. Use the id from reminders_list.",
		InputSchema:         `{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}`,
		RequiredPermissions: []string{"reminders"},
		DefaultEnabled:      false,
	},

	// Obsidian intentionally NOT in this catalog — it gets its own
	// plugin (`obsidian`) with its own tool catalog and per-vault
	// bookmark management. The shared device-tool broker + dispatch
	// path still handle wire routing; only the catalog and
	// per-plugin config are separate. Keeping app_tools focused on
	// the bundled Apple frameworks (EventKit / Contacts / Health /
	// generic Files) means each surface gets its own settings page
	// rather than one massive "every tool" toggle list.
}

// All returns a name-sorted copy of the catalog. Safe for callers
// to mutate.
func All() []Tool {
	out := make([]Tool, len(catalog))
	copy(out, catalog)
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Find returns the tool with the given name, or nil if not in the
// catalog.
func Find(name string) *Tool {
	for i := range catalog {
		if catalog[i].Name == name {
			t := catalog[i]
			return &t
		}
	}
	return nil
}

// Names returns just the names from the catalog, sorted.
func Names() []string {
	out := make([]string, len(catalog))
	for i, t := range catalog {
		out[i] = t.Name
	}
	sort.Strings(out)
	return out
}
