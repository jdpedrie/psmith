# ContentRenderer plugins — author's guide

> *Status: shipped server-side and on both Mac + iOS clients. The renderer set is shared across platforms via the ReeveUI Swift package.*

A `ContentRenderer` plugin turns a message's display-time content
into a structured list of `ContentPart`s the client renders with
native UI components (buttons, cards, key/value tables, images,
typed errors) instead of (or alongside) plain markdown.

It's the plugin hook that lets one plugin contribute "render the
choices block as a row of tappable buttons" without forking the
client.

---

## Where it sits in the pipeline

The full per-message render path is:

```
content (stored bytes)
    │
    ▼
DisplayTransformer chain → display_content (string)
    │
    ▼
ContentRenderer chain → []ContentPart  ──►  Message.ui_fragments  ─►  client renderers
    │
    └─ when no ContentRenderer fires, ui_fragments is empty
       and the client renders display_content as markdown
```

Two things to internalise:

1. **Renderers run AFTER `DisplayTransformer`.** The first
   `RenderContent(parts, role)` call sees `parts =
   [{Text: display_content}]`. So if your plugin already strips
   delimiters in a `TransformForDisplay`, the renderer doesn't see
   them either — design the two together (often: remove the
   `TransformForDisplay` and let the renderer parse the raw
   markers).

2. **Output is DERIVED, not stored.** The server re-runs the
   renderer pipeline on every fetch. Adding or removing a renderer
   plugin from a profile takes effect retroactively across the
   entire history with no backfill job. Don't put expensive
   computation in `RenderContent` — it runs on every `ListMessages`
   call.

---

## The interface

```go
// In plugins/plugins.go.
type ContentRenderer interface {
    RenderContent(parts []ContentPart, role string) []ContentPart
}

type ContentPart struct {
    Text     string      // when Fragment is nil
    Fragment *UIFragment // when Text is empty
}

type UIFragment struct {
    Component string          // "card_list" | "choice_list" | …
    Props     json.RawMessage // component-specific JSON
    Key       string          // optional stable id for view-state
}
```

`role` is one of `"system" | "context" | "user" | "assistant" |
"compression_summary"`. Renderers that should only fire on certain
roles (the common case is "assistant only") guard inside their
implementation.

### Helpers

```go
// Build a Text part.
NewTextPart(s string) ContentPart

// Build a Fragment part.
NewFragmentPart(component string, props json.RawMessage, key string) ContentPart

// For renderers that only operate on Text parts (the common case):
// fn is called for each Text part and returns one or more replacement
// parts. Fragment parts pass through unchanged.
WalkText(parts []ContentPart, fn func(text string) []ContentPart) []ContentPart
```

---

## Pipeline mechanics

The first renderer in the pipeline sees:

```go
parts = []ContentPart{NewTextPart(displayContent)}
```

Each subsequent renderer sees the previous output. Renderers
compose freely:

- A renderer can return `parts` unchanged (no-op).
- A renderer can replace one Text part with [Text, Fragment, Text]
  (split-and-inject — the canonical pattern).
- A renderer can collapse multiple parts into one.
- A renderer can leave Fragment parts emitted upstream untouched
  (`WalkText` does this automatically).

Plugins downstream see the parts list, not the original string.
Composition matters: a citations renderer that wraps URLs in a
`citation` fragment + a `mermaid` renderer that turns fenced
` ```mermaid ` blocks into image fragments coexist as long as
each only touches Text parts and respects `WalkText`.

---

## Skip the Go entirely: `component_builder`

For the common case — "teach the model to wrap structured output
in tags, then render the body as a UIFragment" — there's a
shipped plugin that does this without writing any Go.
`component_builder` lets you define one or more (component, open
tag, close tag, system instructions, optional `[system_reminder]`
user-tail) recipes through a structured editor in the settings
page. Each definition becomes:

  - A section appended to the system prompt explaining what the
    component does + how to wrap the body
  - (Optional, per-definition) a `[system_reminder ...]` injected
    on the head user message every turn so the model stays
    grounded in the convention
  - A ContentRenderer that scans the assistant's output for the
    open/close tags, decodes the body as JSON for the
    component's Props, and emits the UIFragment in place

Use this when:
- You want to ship a tagged-output convention without touching
  the codebase.
- You're prototyping a new renderer-driven workflow and want to
  iterate on the tag conventions / instructions live.

Reach for a hand-rolled ContentRenderer when:
- The body shape isn't naturally JSON (e.g. you're parsing a
  fenced code block out of free prose).
- You need to compose with other renderers that operate on the
  same tags.
- You want span-replacement semantics (multiple matches per
  message, interleaved with prose) — `component_builder` handles
  multiple matches per definition, but a custom renderer can do
  fancier passes.

---

## Authoring a renderer — minimal example

```go
package plugins

import (
    "encoding/json"
    "regexp"
)

type CitationRenderer struct{}

func (CitationRenderer) Name() string        { return "citation_renderer" }
func (CitationRenderer) DisplayName() string { return "Citation Renderer" }
func (CitationRenderer) Description() string {
    return "Wraps bare URLs in a citation fragment so clients render them as cards."
}

var urlRE = regexp.MustCompile(`https?://[^\s]+`)

func (CitationRenderer) RenderContent(parts []ContentPart, role string) []ContentPart {
    if role != "assistant" {
        return parts
    }
    return WalkText(parts, func(text string) []ContentPart {
        // Walk the text, emitting alternating Text + Fragment parts
        // for every URL match.
        var out []ContentPart
        last := 0
        for _, loc := range urlRE.FindAllStringIndex(text, -1) {
            if loc[0] > last {
                out = append(out, NewTextPart(text[last:loc[0]]))
            }
            url := text[loc[0]:loc[1]]
            props, _ := json.Marshal(map[string]any{
                "items": []map[string]any{
                    {"title": url, "url": url},
                },
            })
            out = append(out, NewFragmentPart("card_list", props, ""))
            last = loc[1]
        }
        if last < len(text) {
            out = append(out, NewTextPart(text[last:]))
        }
        if len(out) == 0 {
            // No URLs: pass-through.
            return []ContentPart{NewTextPart(text)}
        }
        return out
    })
}

func init() {
    Register("citation_renderer", func(_ json.RawMessage) (Plugin, error) {
        return CitationRenderer{}, nil
    })
}
```

That's the entire plugin. Attach it to a profile and every
assistant turn that contains a URL renders the URL as a card
card list inline.

---

## Component reference

Renderers ship in
`clients/ReeveSwift/Sources/ReeveUI/PluginRenderers/` so Mac
and iOS share the same SwiftUI views. Each maps a
`UIFragment.Component` string to a `View` consumed by the
top-level `FragmentView` dispatcher.

Unknown component names render as `UnknownComponentRenderer` —
a small "unknown component" fallback that pretty-prints the
props as JSON, so a server running ahead of the client surfaces
something rather than silent gaps.

### `text`

Literal text segment (rendered as Markdown). The wire shape uses
this for every Text part in the renderer output, so the parts
list is uniform on the client side.

```json
{ "text": "Some markdown content **here**." }
```

### `card_list`

Vertical stack of titled content cards with optional URL,
description, image thumbnail, and pill badges. The motivating
use case is search results — flat markdown buries the
title/URL/snippet in a wall of text.

```json
{
  "items": [
    {
      "title": "How transformers work",
      "description": "Optional summary text.",
      "url": "https://example.com",
      "image": "https://example.com/thumb.png",
      "badges": ["news", "2026"]
    }
  ]
}
```

`url` is optional. When present, the card shows an external-link
arrow that fires the `external:<url>` action.

### `choice_list`

Vertical stack of tappable buttons. Each item has a label and an
optional `action` string in the action vocabulary below. Items
without an action render as static rows.

```json
{
  "items": [
    { "label": "Attack",   "value": "A", "action": "compose:Attack" },
    { "label": "Flee",     "value": "B", "action": "compose:Flee" },
    { "label": "Negotiate", "value": "C" }
  ]
}
```

The canonical use case is `lettered_choices`: the assistant
emits A/B/C/D options, the client surfaces them as buttons that
drop the chosen option into the composer for the user to send.

### `key_value`

Definition-list of stat-style key/value pairs. Useful for
plugins that surface structured factoids (weather, build
status, profile snapshot).

```json
{
  "pairs": [
    { "key": "Location",    "value": "Brooklyn" },
    { "key": "Temperature", "value": "62°F" },
    { "key": "Conditions",  "value": "partly cloudy" }
  ]
}
```

### `image`

Single inline image loaded from a URL.

```json
{
  "url": "https://example.com/img.png",
  "alt": "optional alt text",
  "caption": "optional below-image caption"
}
```

For images that came out of a tool (ImageGen, etc.), prefer the
existing `MessageAttachment` path — that goes through Reeve's
file-storage + signed-URL system. `image` is for plugin-supplied
externally-hosted media.

### `image_grid`

Multiple inline images in an adaptive grid.

```json
{
  "items": [
    { "url": "https://example.com/a.png", "alt": "A" },
    { "url": "https://example.com/b.png", "alt": "B" }
  ]
}
```

### `error`

Typed inline error callout. Plugins that produce structured
failures (a search API returning 429, a malformed tool result)
should emit one of these instead of dropping a raw string into
the message body.

```json
{
  "message": "Brave Search rate limit exceeded.",
  "code": "429",
  "retry": "compose:retry search"
}
```

`code` and `retry` are optional. `retry` is parsed as a
`FragmentAction` — same vocabulary as the action strings on
`choice_list` items.

### `raw_json`

Explicit fallback for "I have structured data and no dedicated
component yet." Renders as a pretty-printed JSON code block.
Use this when prototyping a new component before promoting it
to a first-class type.

```json
{ "anything": "you want" }
```

---

## The action vocabulary

Interactive components (`choice_list`, the URL button on
`card_list`, `error.retry`) carry their behaviour as a
`scheme:value` string the client parses into a `FragmentAction`.
Recognised schemes today:

| Scheme     | Value         | Effect                                                                       |
|------------|---------------|------------------------------------------------------------------------------|
| `compose`  | text          | Drop `text` into the composer for the user to send.                          |
| `send`     | text          | Drop `text` into the composer AND submit immediately (one-tap choice).       |
| `external` | URL           | Open the URL externally (system browser).                                    |

Unknown schemes are silently ignored — a renderer can't fire an
action the client doesn't understand. To grow the vocabulary:

1. Add a case to `FragmentAction` in `FragmentView.swift`.
2. Extend `FragmentActionParser.parse`.
3. Route the new case in the `onAction` handler in
   `ConversationView.swift::handleFragmentAction`.
4. Document the new scheme in this table.

Future candidates (deliberately not shipped without a use case):

- `tool:<name>?<key>=<value>` — synthesise a user message that
  invokes a tool. Useful for "Refine these search results" buttons.
- `nav:conversation:<id>` — switch the active conversation.
- `dispatch:<plugin>:<verb>` — generic plugin RPC invocation.

---

## Recipes

### A renderer that ONLY transforms text (most common)

Use `WalkText` and return one Text part per input:

```go
func (TitleCaseRenderer) RenderContent(parts []ContentPart, _ string) []ContentPart {
    return WalkText(parts, func(s string) []ContentPart {
        return []ContentPart{NewTextPart(strings.Title(s))}
    })
}
```

### A renderer that splits text + injects a fragment

Use `WalkText` and return [Text, Fragment, Text]:

```go
func (PromoBanner) RenderContent(parts []ContentPart, role string) []ContentPart {
    if role != "assistant" {
        return parts
    }
    return WalkText(parts, func(s string) []ContentPart {
        if !strings.Contains(s, "[promo]") { return []ContentPart{NewTextPart(s)} }
        before, after, _ := strings.Cut(s, "[promo]")
        props, _ := json.Marshal(map[string]any{
            "message": "Try Reeve Pro!", "code": "AD",
        })
        return []ContentPart{
            NewTextPart(before),
            NewFragmentPart("error", props, "promo"),
            NewTextPart(after),
        }
    })
}
```

### A renderer that emits an entirely structured rendering

Replace the entire parts list. The client falls back to `text`
fragments for any literal you still want — there's no rule that
the renderer's output has to retain text segments.

```go
func (StructuredOnly) RenderContent(parts []ContentPart, _ string) []ContentPart {
    // Combine all text into one structured payload + drop the
    // markdown rendering.
    var combined strings.Builder
    for _, p := range parts {
        if p.IsText() { combined.WriteString(p.Text) }
    }
    props, _ := json.Marshal(map[string]any{
        "pairs": []map[string]string{
            {"key": "raw",    "value": combined.String()},
            {"key": "length", "value": strconv.Itoa(combined.Len())},
        },
    })
    return []ContentPart{NewFragmentPart("key_value", props, "")}
}
```

### A role-gated renderer

Guard at the top of `RenderContent`. The pipeline still passes
your renderer for non-matching roles; you just return the input
unchanged:

```go
func (AssistantOnly) RenderContent(parts []ContentPart, role string) []ContentPart {
    if role != "assistant" { return parts }
    // …
}
```

---

## Testing

Renderers are pure functions. Test them directly:

```go
func TestPromoBanner_SplitsAroundMarker(t *testing.T) {
    r := PromoBanner{}
    in := []ContentPart{NewTextPart("hello [promo] world")}
    out := r.RenderContent(in, "assistant")
    if len(out) != 3 {
        t.Fatalf("got %d parts; want 3", len(out))
    }
    if out[0].Text != "hello " {
        t.Errorf("part 0 = %q; want 'hello '", out[0].Text)
    }
    if out[1].IsText() || out[1].Fragment.Component != "error" {
        t.Errorf("part 1 should be the error fragment; got %#v", out[1])
    }
    if out[2].Text != " world" {
        t.Errorf("part 2 = %q; want ' world'", out[2].Text)
    }
}
```

For the pipeline-level test, see
`plugins/plugins_test.go::TestPipeline_RenderContent_*` — those
verify ordering, role gating, and downstream renderers seeing
upstream fragments.

---

## When NOT to use a ContentRenderer

- **You only want to rewrite text** (e.g. strip ANSI codes,
  normalise whitespace) → use `DisplayTransformer`. Cheaper, no
  fragment plumbing.
- **You want to mutate what gets persisted** (rewrite the user's
  outgoing message before insert) → use `OutgoingUserTransformer`.
  Renderers can't change stored bytes.
- **You want to add a tool the model can call** → use
  `ToolProvider`. Renderers run at display time; tools run during
  generation.
- **You need structured rendering only at materialisation time
  (one-shot, not re-rendered on every fetch)** → today, no good
  story for that. Persist fragments alongside content yourself
  via a `MessageLifecycleHook` if you really need it; otherwise
  make the work cheap enough to run on every fetch.

---

## Adding a new component

1. **Pick a stable name.** It becomes part of the wire contract
   between server plugins and clients. `snake_case`. Examples:
   `card_list`, `key_value`. Avoid model-specific names
   (`brave_search_card` is too narrow).
2. **Document the Props schema** in this file under
   "Component reference" — the schema is canonical here, the
   server doesn't validate it (clients fall back to a safe
   rendering on bad payloads).
3. **Add a SwiftUI view** in
   `clients/ReeveSwift/Sources/ReeveUI/PluginRenderers/<Name>Renderer.swift`.
   Follow the `ChoiceListRenderer` shape: decode `Props`,
   render, route any user actions through the `onAction`
   closure. Mark the struct + init + body `public` so the host
   apps can import it.
4. **Add a case to `FragmentView.bodyFor`** (same file).
5. **Wire the action**, if any, through the host's
   `handleFragmentAction` (per-platform — Mac uses
   `NSWorkspace.shared.open`; iOS uses
   `UIApplication.shared.open`).

There's no proto change required to add a component — the
Component name is just a string. Renderers are platform-agnostic
SwiftUI; both Mac and iOS pick up new components automatically
once they land in ReeveUI.
