# Web client

The web client is a server-rendered UI built into `psmithd` itself. It isn't a separate app talking over the RPC API; it's a presentation layer in the Go process that calls the same services in-process and renders HTML. Every page works as plain HTML (forms post, links navigate) and gets faster and livelier with [htmx](https://htmx.org), its SSE extension and one small script. The design lives on the "Psmith web design" canvas; [web-redesign/plan.md](web-redesign/plan.md) has the rules, tokens and board corrections.

## Why server-rendered

The project optimizes for operational simplicity (one Go binary) and resilient server-owned streams. A server-rendered client keeps both: no Node runtime, no second deploy, no TypeScript client to keep in sync, and direct in-process access to the streaming supervisor. It also sidesteps the browser limits of the Connect protocol: client streaming (`UploadFile`) doesn't exist in browsers, so the composer posts multipart and the handler stores bytes through `files.Service.Store`.

The trade is that the web client doesn't consume the wire contract the way iOS and the Mac do. Parity means the same features and the same behavior, backed by the same services. The [client spec](client-spec.md) is the checklist.

## What it covers

Everything the Mac and iOS apps do that a browser can: the list (search that also runs commands, chips, sort, pinned, archived, select many, rename, generate title, row menu, in-place delete), new conversations from a profile, the conversation (streaming with live thinking and tool chips, stop, branches, edit and delete in place, retry, usage detail, attachments of any type with an image page, council personas, UI fragments, the harness strip), the inspector (context gauge, branch points and contexts, call settings with inheritance, the plugin pipeline, the model picker, conversation info, plugin panels, and the harness binding in Settings' place when Claude Code runs the conversation), compression in the composer's place, elicitation, every Settings page (general and password, appearance, usage, providers and models, profiles, plugins, MCP servers, Langfuse, embedder, speech, users for admins) and first-run setup.

Device tools (Calendar, Reminders, Health, files) need the device's own APIs, so the web client registers no device capabilities and the server answers those tools with "not supported by the connected device".

## Layout

One responsive layout. On a desktop the list, conversation and inspector sit side by side. Below 1180px the inspector becomes a page reached from the header; below 760px the list is the home page and opening anything hides it. Every state is a URL (`?tab=settings`, `?m=<id>&s=edit`, `?rename=1`, `?f=archived`), so it works without script and can be bookmarked. The keyboard shortcuts panel is a third column on a desktop and the page below 1180px, as the inspector is.

## The list

The list column refreshes by swapping itself whole when the account event stream says a conversation changed. Its `hx-select` and `hx-swap` are for that refresh alone (`hx-disinherit="*"`); inherited, they filtered a row menu's or Show more's response down to nothing, so Rename, Delete and Show more did nothing. Everything `list.js` does is delegated, because the column it bound to at load is gone after the first refresh. A swap keeps the list's scroll and the row drafts, and on load the open conversation's row scrolls into view.

A refresh waits while the column is held: a row being renamed or confirmed, an open menu, a selection, or typed search results. One skipped while held runs when the hold lets go, so the list never stays stale.

Filtering, sorting and searching stay on the page the list sits on (`/c/{id}?f=archived`), so they change the list and leave the conversation open. A row's own states use `?renaming=` and `?deleting=`, which stay clear of the conversation's `?rename=1` and the inspector's `?confirm=`. Show more carries the section it ended in (`g`) so the next page doesn't repeat it, and a bulk delete confirms at `/chats?select=1&id=…&bulk=delete`, a URL like every other state.

A row's actions hide behind hover on a desktop. Without hover (below 760px, or any touch screen) there's nothing to reveal them, so the more button is always there, a 44px target beside the time, and its menu has touch-sized items (board PhoneRowMenu). Archived rows offer Unarchive and Delete, as the Mac's archive does; Delete confirms in place like any other row's.

A reply that finishes while its conversation isn't open marks its row unread: a dot before the time, the time and title in accent ink (board Main). The server doesn't record what each device has seen, and neither do the apps (`StreamHub.unseenConversationIDs` lives on the device), so the browser keeps the marks in `localStorage` (`psmith.unseen`). Each row carries its newest message's time (`data-at`), and `list.js` marks a row whose time moved between two refreshes of the column while it wasn't the open conversation. Watching for `data-live` to go away missed most replies: the refresh for the user's message lands before the run registers, and the next one comes after it ends. Opening the conversation clears its mark, in every tab. A reply that lands while no tab is open isn't marked, as on a Mac whose app was quit.

When `ListConversations` fails, the column says so with the reason and Try again (board ListLoadError) rather than rendering blank. A filter with nothing in it says what's missing: a profile chip offers a new conversation with that profile (board ListEmptyFilter), Archived reads "Nothing archived", and an account whose conversations are all archived reads "No active conversations" with a button into the archive (board ListEmptyArchive), not "No conversations yet".

An account with no enabled model can't chat, so `/chats` sends it to setup, as the apps' onboarding gate does. With a provider already made it resumes at that provider's models rather than making a second provider. A profile without a model of its own starts a draft on the model the conversation's composer would show (the first enabled one by provider and name), and the send carries it.

Signing in returns to the page that asked for it (`/login?next=/c/…`, same-site paths only); an htmx request without a session gets `HX-Redirect` rather than the sign-in page swapped into a fragment. Signing out revokes the session on the server, as the apps' Logout does.

## Appearance

Theme and light or dark are per browser, as they're per device on the apps. Both live in cookies, and the server writes them onto `<html>` (`data-theme`, `data-mode`), so the first paint has the right colors. Text size and turn details are cookies too (`psmith_text`, `psmith_turns`). With turn details on (board TurnDetails), every turn gets a line saying who and when, a reply's line adds the provider and how long it took, and its usage shows tokens in and out. `assets/tokens.css` holds each theme's three seed colors per appearance and derives everything else with `color-mix()`, using the same rules as iOS. Any element with `data-theme` re-derives, which is how the Appearance page's cards show other themes. Inter is vendored in `assets/fonts`.

## Code

- `server/web/*.templ` compile to `*_templ.go`, checked in. Run `make web-generate` after editing a template.
- Each area has its own files, routes and assets, so areas don't step on each other: the list and shell (`shell.templ`, `list_*.go`, `routes_list.go`, `assets/list.css` and `list.js`), the conversation (`convo.*`, `conv_*`, `chats.go`), the inspector and composer slot (`inspector.*`, `insp_*`), and Settings in two halves (`seta_*`, `setb_*`, `settings_*`). `page.templ`, `tokens.css`, `app.css` and `app.js` are shared.
- Area stylesheets load after `app.css`. A class one area styles at the top level is everyone's, so scope area rules under the area's own classes.
- `Mount` registers every area's routes on one `ServeMux`. Two areas claiming the same pattern panics at startup; `TestMount_RoutesDontConflict` catches it.

## Streaming

The conversation renders the materialized messages server-side. The composer `hx-post`s to `/c/{id}/send`, which calls `SendMessage` and returns the user's bubble plus a live reply row. That row opens `/c/{id}/stream?run=…` with htmx's SSE extension; the stream subscribes through the supervisor and sends named events: `message` (the reply's markdown so far), `chips` (live thinking and tool chips), `elicit` (a card for the composer's place) and `done`. When the run ends, the account event stream (`/events`) says the conversation changed and the transcript refreshes itself. The inspector's Context tab and an open plugin panel refresh on the same event, so the gauge, the turn count and a pack marked delivered follow the reply without a reload.

The thinking chip opens while the reply is still thinking. The stream sends a `thinking` event with the reasoning so far into a panel that stays hidden until the chip opens it, so opening it mid-thought shows the thought. Each `chips` event redraws the row closed; `conv.js` puts each chip's `aria-expanded` back from its panel after the swap.

When a stream drops, `app.js` marks `<html data-offline>` and the page draws board Offline: the list's banner, a "Lost the connection at 10:44" line under the transcript, and a composer that reads "Send when back". A send made then is held on the form (`data-held`) rather than posted, and `conv.js` submits it when a stream reopens.

The live row carries `id="live-<run>"` and `hx-preserve`. The account event that the user's message was stored arrives a moment after the send and refreshes `#messages`; without the preserve, that refresh drew a new live row, which closed the first stream and opened a second, so every send cost two connections and any chunk between them was the new row's to replay.

Tabs share one account event stream. Over plain HTTP/1.1 a browser keeps six connections per host, and every open page held its own `/events`, so a handful of tabs left no connection for a send or a reply's stream: they queued until a tab closed or navigated, and a reply "showed up after leaving and coming back". `events-shared.js` hands htmx's SSE extension a stand-in for `/events` fed by a SharedWorker (`events-worker.js`) that holds the one connection, named per account so a tab signed in as someone else never shares it. Run streams stay direct: they belong to one tab and end with their reply. Where there's no SharedWorker, or a worker can't reach the server (some embedded browsers refuse a worker's requests), a shared stream that errors before it ever opened hands over to a direct one, and the tab remembers that in `sessionStorage`. Every event stream also sends `X-Accel-Buffering: no`, because nginx holds a response until it ends otherwise.

Every `sse-swap` target sets `hx-swap` itself. htmx inherits `hx-swap` from ancestors, and `#messages` declares `outerHTML` for its own refresh; inherited, that replaced the reply's body with the first chunk and left later chunks nowhere to go, so a reply froze at its first word.

The transcript refreshes on its conversation's account event through `#messages-sync`, a hidden element beside `#messages` that refreshes never replace. The trigger used to live on `#messages` itself, and every refresh replaced it along with anything queued on it, so an event landing next to a swap was lost and a finished reply stayed missing until a reload. The composer's send and Continue sync on `#messages-sync` (`queue all`): htmx resolves a target when a request starts, and a refresh landing mid-send left the send's response aimed at an element that was gone. Row actions don't queue; instead `conv.js` holds the refresh while a row's editor, delete strip or menu is open or a row request is out, cancels a refresh already in flight when a row acts, and runs the held refresh once the row is done. `#messages` declares no `hx-select` or `hx-swap` of its own: its children inherited them, and Edit, Delete and their Cancel swapped the message for nothing.

The header (title, model, context gauge) refreshes after each transcript refresh, unless it's being renamed; a reply, a generated title or a compression changes it and nothing else redraws it. A rename or title generation the server refuses keeps the rename form open with what was typed and the reason in the hint's place. Your own message's delete strip offers Delete from here when messages follow it, as a reply's menu does. A compression summary has no Regenerate (a failed one's Retry opens the compress card; regenerate would rerun it as a chat turn).

A transcript action the server refuses (regenerate, resend, branch, delete, continue, a fragment choice) redirects back with `?error=` and the transcript draws the reason in its alert line. htmx drops an error status without a swap, so these used to look as if nothing had been clicked. The composer saves its model as the conversation's default before it sends: once the run starts, the conversation refuses settings changes, so the choice never stuck and a later regenerate could find no model.

Without script, the send posts and redirects to `/c/{id}?run=…`; the page renders the same live row, and the run completes server-side either way.

## The inspector

The Context tab draws the run the way the Mac does once there are two replies: "Context over this run" (each reply's prompt plus output, with your warning as a dashed line) and "Cost per reply" (orange where a reply read under 30% of a prompt of 4,096 tokens or more from the cache). Both are SVG drawn on the server. Replies with usage but no cost name their model in a footnote ("No pricing for qwen3:8b"), because the cost line leaves them out.

The Plugins tab says "No plugins are running for this conversation." when the pipeline is empty, and offers Clear conversation changes whenever the conversation has overrides of its own; it drops them all, as the Mac's button does. A plugin's settings draw list fields (Context Packs' packs, a council's members) as rows that open to their fields, with Add, Delete and Paste JSON. Each of those posts the form, so it saves what's typed and works without script; a row left blank is dropped on save, and rows keep their generated ids.

The Settings tab shows what the model's constraints fix as fixed: a temperature the model locks reads "Locked at 1.0 by Claude Opus 4.8" with the value in a disabled field, and a setting the model rejects reads "Not supported by …". Disabled fields don't post, so saving clears any value the conversation held for them. The model picker only checks "Use the profile's model" when the profile has one; with none, that row is disabled and the model the next send uses is checked.

A title the info view can't save or generate comes back as the info view with the reason under the field and what was typed still in it (status 422), not a bare error page.

## Settings

Settings pages are plain forms with a save bar. A save the server refuses, and every Test (Langfuse, embedder, speech), answers with a redirect to the page's own URL plus `?shown=<token>`, and that GET serves the page the POST rendered: what was typed, the error or the result, the save bar. Rendering the answer at the POST's URL meant a refresh asked to post again, and saying yes saved or tested twice. The rendered page is kept in memory for ten minutes, for the user who posted and that path only; after that, or after a restart, the URL shows the page as stored. An MCP server's Test just redirects to its page, which tests as it loads. The second half of Settings does this through `answer` and `showAfterPost` (`setb_shown.go`); the routes wrap every page in `shownOr`.

A failed Test reads the way the apps word it (boards SettingsServerFailing and SettingsLangfuseSetup): "Test failed after 12 ms." or "Couldn't connect.", then what the error means when it's one we recognize ("Nothing is listening at 127.0.0.1:1.", "Langfuse refused the credentials (HTTP 401)."), and the service's own error on a second, small mono line.

A profile's Plugins tab orders attached plugins with Move up and Move down on each row, where the Mac drags. They're buttons, so the keyboard reaches them; with script they move the row in place, renumber, keep focus on the row, and the save bar commits the order (each row posts its position, `ppos_i`). Without script each arrow posts the tab and saves at once, as Remove does. A tag saying a plugin needs a shared setting ("Needs an API key in Plugins") links to that plugin's page in Plugins, the Mac's Open in Plugins.

Langfuse's Send traces stays off until there is a public key and a secret, saved or typed, as on both apps, and Send test trace waits for a saved secret. Editing an MCP server with stored headers or environment offers Clear beside it (board SettingsEditServer); it's a checkbox drawn as a button, so it posts without script, and the save sends an empty value, which the service takes as remove. Typing new values replaces what's stored whether or not Clear is on.

## Compression

Compression runs in the composer's place: the compress card, the streaming card, the review (with edit), and the failed card. Esc stops a running summary; the review then reads "Summary stopped", since what it holds ends where the stop cut it. The summary row carries nothing that says so, so the page reads it off the cancelled compression run whose result it is. Starting one redirects to `/c/{id}?compact=<run>`, so a summary that finishes before the page loads still gets its streaming card; that card's stream replays the run and moves on to the review. The stream only serves a compression run of the conversation in the URL.

## Elicitation

When a tool asks for input mid-run, the stream sends an `elicit` event with a card built from the request's JSON Schema (text, password, number and boolean fields), which lands in the composer's place. Submitting posts to a cookie-authenticated route that hands the answer to the same broker the bearer endpoint uses. The stream stays open, so the waiting tool unblocks and the reply resumes on the same connection. The secret never enters the transcript. The chunk names who is asking (`source`, the plugin or MCP server as the user knows it, and `tool`), so the card reads "GitHub needs input" rather than a generic title. The tool loop attaches both when it dispatches a call.

## Tests

- Handler tests (httptest and pgtestdb) for every route, per area: `handlers_list_test.go`, `actions_conv_test.go`, `inspector_insp_test.go`, `handlers_seta_test.go`, `handlers_setb_test.go`, plus the older per-feature tests.
- Browser tests drive the real client in headless Chrome against a real database and a fake model that streams slowly (`browser_test.go`, `browser_keys_test.go`). They record what was on the page every 150ms, because streaming bugs live between frames. They cover a send from start to settle, one stream per send, seven tabs at once, the shared stream's direct fallback, `/` search running a command, J and K, Esc stopping a reply, and ⌘S. Frames and a timeline land in `$PSMITH_WEB_E2E_OUT`. They skip without Chrome or with `-short`. Settings forms get the same treatment (`browser_setb_*_test.go`): a refused save must come back with what was typed and the save bar up, Revert must put switches back, and Add plugin must keep the tab's unsaved edits, because each of those failed silently before. The first half of Settings has its own (`browser_seta_*_test.go`): Test connection, Test model, Favorite and a model's On switch swap their result in place with htmx, so a rename or limit typed and not yet saved survives them, and Revert brings back a removed stop sequence. Replace (API key), a phone header's Remove, a row's Test and an off row's Delete work in place too.
- Board conformance: `probe_*_test.go` render every screen's templates with its board's content when `PSMITH_WEB_PROBE_OUT` is set, and `tools/boardcheck` renders the boards and the pages and diffs them. See `tools/boardcheck/check.sh`.

## Building and running

The generated templ files are checked in, so `go build ./...` and `make build` need no extra step. The UI is served by `psmithd` on its normal address; open `/` (it redirects to `/login`). See [operations/configuration.md](../operations/configuration.md) for the server's environment.
