# Web client

The web client is a server-rendered UI built into `psmithd` itself. It isn't a separate app talking over the RPC API; it's a presentation layer in the Go process that calls the same services in-process and renders HTML. Every page works as plain HTML (forms post, links navigate) and gets faster and livelier with [htmx](https://htmx.org), its SSE extension and one small script. The design lives on the "Psmith web design" canvas; [web-redesign/plan.md](web-redesign/plan.md) has the rules, tokens and board corrections.

## Why server-rendered

The project optimizes for operational simplicity (one Go binary) and resilient server-owned streams. A server-rendered client keeps both: no Node runtime, no second deploy, no TypeScript client to keep in sync, and direct in-process access to the streaming supervisor. It also sidesteps the browser limits of the Connect protocol: client streaming (`UploadFile`) doesn't exist in browsers, so the composer posts multipart and the handler stores bytes through `files.Service.Store`.

The trade is that the web client doesn't consume the wire contract the way iOS and the Mac do. Parity means the same features and the same behavior, backed by the same services. The [client spec](client-spec.md) is the checklist.

## What it covers

Everything the Mac and iOS apps do that a browser can: the list (search that also runs commands, chips, sort, pinned, archived, select many, rename, generate title, row menu, in-place delete), new conversations from a profile, the conversation (streaming with live thinking and tool chips, stop, branches, edit and delete in place, retry, usage detail, attachments of any type with an image page, council personas, UI fragments, the harness strip), the inspector (context gauge, branch points and contexts, call settings with inheritance, the plugin pipeline, the model picker, conversation info, plugin panels, and the harness binding in Settings' place when Claude Code runs the conversation), compression in the composer's place, elicitation, every Settings page (general and password, appearance, usage, providers and models, profiles, plugins, MCP servers, Langfuse, embedder, speech, users for admins) and first-run setup.

Device tools (Calendar, Reminders, Health, files) need the device's own APIs, so the web client registers no device capabilities and the server answers those tools with "not supported by the connected device".

## Layout

One responsive layout. On a desktop the list, conversation and inspector sit side by side. Below 1180px the inspector becomes a page reached from the header; below 760px the list is the home page and opening anything hides it. Every state is a URL (`?tab=settings`, `?m=<id>&s=edit`, `?rename=1`, `?f=archived`), so it works without script and can be bookmarked.

## Appearance

Theme and light or dark are per browser, as they're per device on the apps. Both live in cookies, and the server writes them onto `<html>` (`data-theme`, `data-mode`), so the first paint has the right colors. Text size and turn details are cookies too (`psmith_text`, `psmith_turns`). `assets/tokens.css` holds each theme's three seed colors per appearance and derives everything else with `color-mix()`, using the same rules as iOS. Any element with `data-theme` re-derives, which is how the Appearance page's cards show other themes. Inter is vendored in `assets/fonts`.

## Code

- `server/web/*.templ` compile to `*_templ.go`, checked in. Run `make web-generate` after editing a template.
- Each area has its own files, routes and assets, so areas don't step on each other: the list and shell (`shell.templ`, `list_*.go`, `routes_list.go`, `assets/list.css` and `list.js`), the conversation (`convo.*`, `conv_*`, `chats.go`), the inspector and composer slot (`inspector.*`, `insp_*`), and Settings in two halves (`seta_*`, `setb_*`, `settings_*`). `page.templ`, `tokens.css`, `app.css` and `app.js` are shared.
- Area stylesheets load after `app.css`. A class one area styles at the top level is everyone's, so scope area rules under the area's own classes.
- `Mount` registers every area's routes on one `ServeMux`. Two areas claiming the same pattern panics at startup; `TestMount_RoutesDontConflict` catches it.

## Streaming

The conversation renders the materialized messages server-side. The composer `hx-post`s to `/c/{id}/send`, which calls `SendMessage` and returns the user's bubble plus a live reply row. That row opens `/c/{id}/stream?run=…` with htmx's SSE extension; the stream subscribes through the supervisor and sends named events: `message` (the reply's markdown so far), `chips` (live thinking and tool chips), `elicit` (a card for the composer's place) and `done`. When the run ends, the account event stream (`/events`) says the conversation changed and the transcript refreshes itself.

Every `sse-swap` target sets `hx-swap` itself. htmx inherits `hx-swap` from ancestors, and `#messages` declares `outerHTML` for its own refresh; inherited, that replaced the reply's body with the first chunk and left later chunks nowhere to go, so a reply froze at its first word.

Without script, the send posts and redirects to `/c/{id}?run=…`; the page renders the same live row, and the run completes server-side either way.

## Elicitation

When a tool asks for input mid-run, the stream sends an `elicit` event with a card built from the request's JSON Schema (text, password, number and boolean fields), which lands in the composer's place. Submitting posts to a cookie-authenticated route that hands the answer to the same broker the bearer endpoint uses. The stream stays open, so the waiting tool unblocks and the reply resumes on the same connection. The secret never enters the transcript.

## Tests

- Handler tests (httptest and pgtestdb) for every route, per area: `handlers_list_test.go`, `actions_conv_test.go`, `inspector_insp_test.go`, `handlers_seta_test.go`, `handlers_setb_test.go`, plus the older per-feature tests.
- Browser tests drive the real client in headless Chrome against a real database and a fake model that streams slowly (`browser_test.go`, `browser_keys_test.go`). They record what was on the page every 150ms, because streaming bugs live between frames. They cover a send from start to settle, `/` search running a command, J and K, Esc stopping a reply, and ⌘S. Frames and a timeline land in `$PSMITH_WEB_E2E_OUT`. They skip without Chrome or with `-short`.
- Board conformance: `probe_*_test.go` render every screen's templates with its board's content when `PSMITH_WEB_PROBE_OUT` is set, and `tools/boardcheck` renders the boards and the pages and diffs them. See `tools/boardcheck/check.sh`.

## Building and running

The generated templ files are checked in, so `go build ./...` and `make build` need no extra step. The UI is served by `psmithd` on its normal address; open `/` (it redirects to `/login`). See [operations/configuration.md](../operations/configuration.md) for the server's environment.
