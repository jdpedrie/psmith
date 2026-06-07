# Device tools

LLM-callable tools that run on the user's device — iOS (primary), Mac
(where it makes sense) — backed by the host OS's native APIs and
permission grants. Calendar, Reminders, Contacts, Health, the user's
Obsidian vault, etc.

Photos is **out of scope** — the existing file-upload path already
covers "let the model see a picture I picked." This doc is about
tools the model invokes proactively (`list_calendar_events_today`,
`append_to_obsidian_note`, …), not tools the user manually triggers
via attachment.

## The architectural pivot

Every tool Reeve ships today runs server-side in clarkd: a plugin
implements `ToolProvider`, the supervisor dispatches `tool_use`
chunks to `ExecuteTool`, the result feeds back into the next round.
Device tools break that model — EventKit / Contacts / HealthKit /
the user's iCloud Drive folder only exist on the device. The
server can't reach them; the device can't run a Go plugin.

So we need a **device-side execution path**: the LLM emits a
`tool_use` for `calendar_list_events`, server forwards it to the
connected iOS client, client calls EventKit, posts the result back,
server feeds it into the supervisor's tool loop. The model sees a
linear, server-side tool stream — same shape as any other plugin —
and never knows the work happened on the device.

This is essentially MCP-on-device, but we ship the **pragmatic
shape** first (see "Shape decision" below) and refactor to MCP-
on-device later if the surface area justifies it.

## Wire mechanism

Lean on the existing **elicit broker** pattern. The elicit broker
already does the "server-side tool needs a roundtrip through the
connected client" dance:

  1. Server-side tool emits a chunk (today: `Elicitation`; new:
     `DeviceToolUse`) describing the request, with a UUID.
  2. The active stream subscriber on the client receives the chunk.
  3. The client executes the work and POSTs the result back to a
     dedicated HTTP endpoint with the matching UUID.
  4. The server's broker matches the UUID, unblocks the waiting
     tool-loop goroutine, and feeds the result into the round.

Device tools reuse this pattern verbatim — only the chunk payload
and result endpoint change.

**New chunk type** (proto):

```proto
message DeviceToolUse {
  string call_id = 1;            // matches the supervisor's tool_use.id
  string tool_name = 2;          // e.g. "calendar_list_events"
  bytes input_json = 3;          // schema per tool, validated by the iOS handler
  google.protobuf.Timestamp issued_at = 4;
}
```

**New response endpoint** (HTTP):

```
POST /conversations/{id}/device-tools/{call_id}/respond
{
  "ok": true,
  "output_json": "...",         // model-visible result
  "error": null,                // present when ok=false
  "attachments": []             // optional (e.g. an .ics file the model can re-cite)
}
```

**Capability advertising** at connect time so the server doesn't
expose tools the connected client can't fulfill:

```proto
service DeviceToolsService {
  rpc RegisterCapabilities(RegisterCapabilitiesRequest)
      returns (RegisterCapabilitiesResponse);
}
message RegisterCapabilitiesRequest {
  // Tool names this client can fulfill on this device + this version.
  repeated string supported_tool_names = 1;
  // Free-form so iOS can publish OS version / app version / etc.
  // alongside, used by the server for "tool may need iOS 26+" gating.
  map<string, string> client_attributes = 2;
}
message RegisterCapabilitiesResponse {}
```

The iOS app calls this on every connection (the lifetime of a
StreamSubscriber). The server tracks `(user_id, conversation_id) →
supported_tool_names`. The `device_tools` plugin's `Tools()` filter
intersects "tools we know about" ∩ "tools this client can do." A
multi-device scenario (iOS + Mac both connected) is resolved by
preferring whichever client most recently announced support — the
profile can override via a per-tool routing config.

## Server-side: `app_tools` plugin

One server-side plugin — named `app_tools` because "apps on your
device the model can talk to" reads more naturally to users than
"device tools." Single source of truth for the catalog; per-profile
enablement falls out of the existing plugin-config merge chain
(parent profile → child profile → conversation override) for free.

```go
// plugins/app_tools.go
type appTools struct {
    cfg appToolsConfig    // Enabled: map[string]bool keyed by tool name
}

func (p *appTools) ConfigFields() []ConfigField {
    // One boolean per catalog tool. UI renders a per-tool toggle;
    // user picks which tools their model can call in this profile.
}

func (p *appTools) Tools() []ToolDef {
    // Returns (catalog ∩ enabled). The connected-client filter
    // happens via ToolsForClient at the conversations-side
    // dispatch point.
}

func (p *appTools) ExecuteTool(ctx, name, input) (ToolResult, error) {
    broker := DeviceToolBrokerFrom(ctx)   // typed handle, like SearcherFrom
    return broker.Invoke(ctx, name, input)
}
```

`broker.Invoke` mirrors `elicit.Client.Elicit`: emit a
`CHUNK_TYPE_DEVICE_TOOL_USE` chunk, register a waiter, block on the
response endpoint resolving the UUID, return the result. 60s default
timeout; per-tool slow-op timeouts later if anything needs them.

Tool catalog (`internal/devicetools/catalog.go`) lives in code so
schema + description changes ship in a clarkd binary, not a client
release. Each entry has `DefaultEnabled` — read-only ops
(`*_list_*`, `*_read_*`, `*_search_*`) default on; mutating ops
(`*_create_*`, `*_update_*`, `*_delete_*`, `*_append_*`) default off
so a fresh profile doesn't grant the model write access without the
user explicitly flipping a toggle.

Each user picks which tools to enable per profile via the plugin's
config UI; `Enabled: {"calendar_create_event": true, ...}` rides in
on the plugin's config JSON like any other.

## iOS: capability registration + dispatch

`ReeveKit/DeviceTools/` houses the iOS side:

  - `DeviceToolRegistry.swift` — maps tool name → handler closure.
    Each capability (Calendar, Reminders, Obsidian, …) registers
    itself in `AppDelegate`-ish bootstrap; the registry calls
    `RegisterCapabilities` with the union of available tool names on
    every new StreamSubscriber connection.
  - `DeviceToolDispatcher.swift` — listens to the subscribe stream
    for `DeviceToolUse` chunks, hands each to the matching handler,
    POSTs the result.
  - Per-capability handler files:
    - `CalendarTools.swift` (EventKit / events + reminders)
    - `ContactsTools.swift` (Contacts framework)
    - `HealthTools.swift` (HealthKit, opt-in per type)
    - `LocationTools.swift` (CoreLocation, "where am I right now")
    - `FilesTools.swift` (UIDocumentPicker, generic folder access)
    - `ObsidianTools.swift` (FilesTools wrapper: search/read/write
      `.md` files in a bookmarked vault folder)

Each handler:

  1. Validates input against an inline JSON-Schema-y check (we
     trust the server's catalog, but defensive).
  2. Checks/requests OS permission. If denied, returns a structured
     `{permission_denied: "calendar", deep_link: "App-Prefs:..."}`
     so the model can relay a friendly "want me to deep-link you
     to settings?" message.
  3. Performs the work, builds a Codable response, POSTs back.

## Tool inventory

### Phase 1 (ship first; validates the bridge)

- **Calendar** (EventKit, iOS + Mac)
  - `calendar_list_events(start_date, end_date, calendar?)` → events
  - `calendar_create_event({title, start, end, location?, notes?, calendar?})` → event id
  - `calendar_update_event(id, fields)`
  - `calendar_delete_event(id)`
- **Reminders** (EventKit, iOS + Mac)
  - `reminders_list(list?, completed?)`
  - `reminders_create({title, due_date?, list?, notes?})`
  - `reminders_complete(id)`
**Note**: Obsidian gets its **own** plugin (`obsidian`) rather than
riding in `app_tools`. Same device-tool wire mechanism; separate
catalog + separate per-vault settings (which folder is bookmarked,
which subfolder is the "scratch" target for `append`, etc.). The
plugin still uses the shared `DeviceToolBroker` so the
infrastructure isn't duplicated — only the catalog + the per-plugin
config UI live separately.

### Phase 2 (after the bridge proves itself)

- **Contacts** (Contacts.framework, iOS + Mac)
  - `contacts_search(query)`, `contacts_read(id)`, `contacts_create({...})`
- **Health** (HealthKit, iOS only)
  - Per-type permission grant; `health_steps(date)`, `health_sleep(date)`,
    `health_weight_recent()`. Read-only.
- **Location** (CoreLocation, already wired via Privacy)
  - Promote to first-class `location_current()` tool — the model
    can ask "where am I right now?" without piggybacking on
    basic_grounding's once-per-turn injection.
- **Files (generic)** (UIDocumentPicker, iOS + Mac)
  - Any user-picked folder, read/write/list. Obsidian is the
    motivating case but generalizes to "let the model touch my
    Downloads folder," etc.

### Explicitly skipped

- **Photos** — the existing file-upload path covers "show this to
  the model"; programmatic search/save isn't compelling enough.
- **Mail / Messages** — `MFMailComposeViewController` /
  `MFMessageComposeViewController` only compose, can't read. Too
  one-sided to bother.
- **App Intents from third-party apps** — a Shortcuts-style
  integration is its own architectural beast (open-ended URI
  schemes, no schema discovery, brittle). Revisit if a concrete
  use case lands.

## Permission model

Three layers, each independently gating a tool call:

  1. **OS permission** (per-app, per-data-type): EventKit's
     calendar grant, HealthKit's per-type grants, file-bookmark
     consent. Denials surface as `permission_denied` with a deep
     link the model can offer.
  2. **Profile config** (the `app_tools` plugin's per-tool
     `Enabled` map): the user toggles each tool on or off in the
     profile editor. Read-only ops default on; mutating ops
     default off. Inherited via the plugin-config merge chain, so
     a parent profile can grant `obsidian_read_note` and a child
     can opt the model out without losing the inheritance for
     other tools.
  3. **Per-call audit** (optional v2): "always allow" / "ask each
     time" per tool, like iOS's system-wide "ask each time" for
     location. Adds friction but is the right escape hatch for
     paranoid users.

## Audit log

Every device-tool call writes a row to a new table:

```sql
CREATE TABLE device_tool_calls (
  id            UUID PRIMARY KEY,
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  message_id    UUID REFERENCES messages(id) ON DELETE SET NULL,
  tool_name     TEXT NOT NULL,
  input_json    JSONB,
  output_json   JSONB,
  status        TEXT NOT NULL CHECK (status IN ('ok','denied','error','timeout')),
  invoked_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at  TIMESTAMPTZ
);
```

Surfaces in two places:

  - **Per-message popover** on the assistant turn that triggered
    the call — same expandable section as the existing tool-call
    UI, but with a "device" badge.
  - **Settings → Privacy → Device tool activity**: scrollable list,
    grouped by tool, with "what did the model see?" full payloads
    for transparency.

## Shape decision: pragmatic now, MCP-on-device later

| | Pragmatic (chosen) | MCP-on-device (eventual?) |
|---|---|---|
| Server | One `device_tools` plugin with hardcoded catalog | Existing `mcp` plugin + new device transport |
| Client | iOS code: switch on tool name → handler | iOS hosts an in-process MCP server registering each capability |
| Adding a tool | Edit server-side catalog + iOS switch | Add an iOS MCP handler; server auto-discovers |
| First tool effort | ~2 days | ~1 week |
| Cross-platform reach | iOS + Mac separately reimplement | Same transport, different host |

Pragmatic ships faster and validates the bridge with real users.
MCP-on-device is the right destination if device tools become a
major surface area — refactor later by porting the catalog into iOS
MCP handlers and swapping the server-side plugin for the `mcp`
plugin pointed at the device transport.

## Open questions

- **Multi-client routing**: iOS + Mac both connected, which one
  runs `calendar_list_events`? Default: most-recently-connected
  client with the capability. Override: per-tool profile config.
- **Cross-device tools**: should iOS's Calendar grant be reusable
  from a Mac that's offline? No — device tools are scoped to "this
  device, right now." If the user wants their iOS calendar
  visible from Mac sessions, that's a separate ICS-export sync, not
  a tool.
- **Background execution**: iOS aggressively suspends backgrounded
  apps. If the model fires a tool while iOS is backgrounded, the
  dispatcher needs to wake (background execution time is limited
  per the existing BackgroundTaskKeeper). May need to surface a
  "this tool requires the app to be open" status to the model.
- **Caching**: should `obsidian_list_notes` results be cached
  client-side? Vault contents change rarely; a 60s TTL would
  cheaply absorb back-to-back tool calls. Defer until a concrete
  workload reveals the latency.

## Phased rollout (commits, roughly)

  1. ✅ Proto additions: `CHUNK_TYPE_DEVICE_TOOL_USE` + new
     `DeviceToolsService` (`RegisterCapabilities` +
     `ListSupportedTools`) + `respond` HTTP endpoint shape.
     Codegen on both sides.
  2. ✅ `internal/devicetools/`: Broker (mirrors elicit broker) +
     Registry (per-(user, conv) supported set) + Catalog (the
     hand-curated list of tools).
  3. ✅ `plugins/app_tools.go`: catalog-backed `ToolProvider` with
     per-tool `Enabled` config; `DeviceToolBroker` ctx-seam for
     dispatch. Includes `ToolsForClient(supported)` so the
     conversations side can pre-filter to the connected device.
  4. Conversations wiring: register the HTTP `respond` endpoint;
     register the `DeviceToolsService` Connect handler; attach a
     per-call broker binding to `ExecuteTool`'s ctx; teach
     `collectPipelineTools` to call `ToolsForClient` when the
     plugin is `app_tools`.
  5. iOS: capability registration + dispatcher + JSON-encoded
     result poster. No tools yet — just the bridge.
  6. iOS: Calendar + Reminders (EventKit) handlers. First real
     tool the model can call.
  7. iOS: Obsidian vault tools (UIDocumentPicker bookmark +
     filesystem read/write).
  8. Settings UI: per-tool enable toggles in the profile editor;
     audit-log viewer.
  9. (Phase 2) Contacts, Health, Location-as-tool, generic Files.
