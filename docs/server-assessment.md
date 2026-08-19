# Server architecture assessment

A read of `server/` looking for duplication, structural mistakes, and things
that will hurt under load. Written 2026-08-11 against `68fcd17`.

The short version: the architecture is sound and the layering is real. Nothing
here is a rewrite. The problems are concentrated in two places, the send path
and the stream writer, and most of them are the ordinary cost of a system that
grew feature-first. Findings are ordered by what I would fix first.

## Shape

```
server/conversations   8099    the send path, and by a wide margin the biggest thing
server/web             3891    htmx client; delegates to the services (good)
server/profiles        3792    profiles, inheritance, sharing
server/modelproviders  2334    providers, models, test + probe
server/stream          1994    supervisor, broker, chunk persistence
server/providers/*     4765    three drivers
server/history          722    wire prefix assembly
```

`conversations.SendMessage` is 669 lines in a 3236-line file. That single
function is the densest concentration of risk in the codebase, and most of what
follows lives inside it.

---

## 1. The send path resolves the profile four times per turn

`profiles.Resolve` walks the parent chain issuing one `GetProfileByID` per
level. A single `SendMessage` calls it from four independent places:

| Call site | Line |
|---|---|
| `resolvePipelineForConversation` | 1480 |
| `resolveProviderModel` (profile-defaults branch) | 2181 |
| `resolveIncludeThinking` | 2212 |
| `assembleCallSettings` | 2337 |

Each one re-loads the same profile row and re-walks the same ancestry. On a
three-deep inheritance chain that is twelve queries to answer questions about
one unchanging object, before any work happens. `validateModelCapabilities`
resolves plugin capabilities separately on top.

None of it is wrong, and that is why it accumulated: each helper is correct in
isolation and reads well on its own. The cost only exists when you notice
they all run on the same request.

**Fix.** Resolve once at the top of `SendMessage` and thread the result. A
`resolvedProfile` value passed to the four helpers turns twelve-plus queries
into three or four, and makes the helpers pure. This is the single highest
value change on the list, and it is mechanical.

## 2. Attachments are re-read and re-uploaded on every single turn

`history.Build` batches the attachment *rows* correctly (one
`ListAttachmentsForMessages` for the whole chain, no N+1). Then it loops and
reads every attachment's bytes out of storage, `io.ReadAll`s them, and inlines
them into the wire request (`history.go:236`).

That happens on every send. A conversation with four images attached on turn
two re-reads and re-base64s those four images on turns three through fifty, and
ships them upstream every time. The provider bills for them every time.

The driver comment already flags the intended escape hatch ("provider Files API
caching is a phase-4 escape hatch"). Two independent improvements:

- **Cache the bytes in-process** keyed by sha256. They are content-addressed
  already, so the cache is trivially correct and bounded by a size cap.
- **Use provider file references** where the driver supports it, so the bytes
  cross the wire once. `Attachment.ProviderFileID` already exists in the
  struct and is unused on this path.

The first is a small change with immediate benefit. The second is the real fix
and is a bigger piece of work.

## 3. Chunk persistence is one round-trip per chunk

`consume.go:105` buffers chunks and flushes on a ticker or at
`flushBatchSize = 16`. The flush then issues a separate `InsertStreamChunk` per
buffered chunk. Buffering to 16 and then paying 16 round-trips gets the
batching's memory behaviour without its actual benefit.

At a few hundred chunks per response, one active stream is a few hundred
sequential round-trips. Concurrent streams multiply it, and every one holds a
pool connection for the duration of its flush.

**Fix.** One multi-row insert per flush, or `pgx.Batch`. Same rows, one
round-trip. This is a contained change in one function.

**Related:** `stream_chunks.payload` is `JSONB` and no query ever reads into it
(`grep` for `payload->` across `db/queries/` returns nothing). JSONB pays
parse-and-normalize on every write to buy operators nobody uses. `JSON` or
`TEXT` would be strictly cheaper on the hottest write path in the system. It is
a one-line migration, though it rewrites the table.

## 4. Every authenticated request writes to the database

`interceptor.go:112` calls `TouchSession` on every request that carries a
bearer token, unconditionally:

```sql
UPDATE sessions SET last_used_at = NOW() WHERE token_hash = $1;
```

So a read becomes a write. Clients poll events, list conversations, subscribe to
streams, and every one of those dirties the same row. Concurrent requests from
the same session serialize on that row's lock, and the table accumulates dead
tuples at request rate for a column whose value nobody reads with precision.

**Fix.** Touch at most once per interval: `WHERE token_hash = $1 AND
last_used_at < NOW() - INTERVAL '5 minutes'`. Same information, a rounding
error of the writes. Cheap and safe.

## 5. Provider plumbing is copy-pasted across services

The sequence *load provider row, decrypt config, build driver, assert
StatelessProvider* appears in six places across `conversations` and
`modelproviders` (`providers.Build` has nine non-driver call sites).
`resolveProviderConfig` is duplicated outright between the two services
(`conversations/service.go:226`, `modelproviders/service.go:96`).

I added to this myself: `conversations/completer.go` is a seventh copy, written
while building the council moderator. That is the tell that the shape is
missing rather than that people are careless.

**Fix.** One `providerkit` (or a method on a shared struct) exposing
`OpenStateless(ctx, providerID) (StatelessProvider, store.UserModelProvider,
error)`. Every call site collapses to one line and the ownership check stops
being something each caller has to remember.

## 6. `SendMessage` is doing eight jobs

669 lines covering: validation, leaf resolution, routing, model resolution,
capability gating, pipeline resolution, the transactional user-row insert,
envelope composition, history building, cache observation, call-settings
assembly, explicit-cache attachment, tool-loop construction, five closures for
post-materialization work, and the supervisor handoff.

The transaction is correctly scoped (three operations under `SELECT FOR UPDATE`,
committed before the slow upstream call) and the comments explaining why are
genuinely good. The problem is not correctness, it is that the function has no
seams. Every new feature adds a parameter to a closure defined 200 lines from
where it is used, which is exactly how the persona plumbing went wrong and
stayed invisible.

**Fix.** Extract a `turn` struct holding the resolved inputs (conversation,
profile, pipeline, provider, model, settings, route) built by one `prepareTurn`,
then `insertUserMessage`, `buildRequest`, `startRun`. No behaviour change, four
testable pieces. Worth doing before the next feature lands in there.

## 7. Smaller things

**Unbounded list queries.** Twenty-eight `:many` queries have no `LIMIT`.
Most are legitimately small (plugins per profile, models per provider). Three
were not bounded by anything structural: `ListMessagesByContext`,
`ListStreamChunks`, `ListMessageTreeStructure`.

Fixed, though not all with cursors. `ListStreamChunks` gained an upper bound
and internal paging: the live-subscribe path only ever uses chunks up to the
fanout cursor, and was fetching the whole run to discard most of it while
holding the lock that blocks fan-out to everyone else.

The two full-tree reads are capped and report truncation instead. A cursor
would be the wrong shape there: a caller needs the entire tree to draw the
branch switcher, and half a tree is not a smaller tree, it is a tree with the
wrong shape, since a fork whose sibling fell off the page renders as no fork at
all.

**No pool tuning.** `pgxpool.New(ctx, dsn)` takes library defaults (4 or
NumCPU). Under concurrent streams each holding a connection through flushes,
that is the first thing to saturate. Worth setting `MaxConns` explicitly and
from config rather than discovering it.

**`firstLine` and friends** are duplicated per package. Trivial, and
`server/internal/` exists as the home for exactly this kind of thing.

**The `web` package delegates properly.** It calls the Connect services
in-process rather than reimplementing them. That was the thing most likely to be
a duplication disaster and it is not one.

## What is genuinely good

Worth recording so it does not get refactored away by accident.

The driver interface boundary is clean: three providers behind one interface,
per-driver quirks (thinking shapes, cache breakpoints, constraint tables) stay
inside their package. The plugin capability system is opt-in by type assertion
with no god interface. The supervisor's ownership model is clear and
`runState` is actually cleaned up (`consume.go:361`). Transaction scope in the
critical section is tight and deliberate. `pgtestdb` per-test databases mean the
DB tests are real tests. And the comment quality throughout is unusually high:
most of the non-obvious decisions explain themselves, which is why this
assessment could be written by reading rather than by running experiments.

## Status

Worked through 2026-08-11. What changed, and what is deliberately still open:

| # | Item | State |
|---|---|---|
| 1 | `TouchSession` per request | Fixed: five-minute interval |
| 2 | Per-chunk inserts | Fixed: one UNNEST insert per flush |
| 3 | Profile resolved four times | Fixed: request-scoped `profileCache` |
| 4 | Provider plumbing duplicated | Fixed: `server/providerkit` |
| 5 | Attachments re-read every turn | Fixed: `storage.ReadCache` for the backend reads, `providers.FileUploader` + `provider_files` so the bytes cross the wire once. Google implements the uploader; the other two keep inlining until they adopt it. |
| 6 | `SendMessage` has no seams | Fixed: 669 to 280 lines across `prepareTurn`, `commitUserMessage` and `buildSendRequest`. What remains is the tool-loop closures and the supervisor handoff, which belong to starting a run. |
| 7 | JSONB payload, pool defaults, unbounded reads | Fixed. Chunks page with an upper bound; the two full-tree reads are capped and report truncation rather than paginating, because a partial tree has the wrong shape rather than being a smaller one. |

## Order I would do these in

1. **TouchSession interval** (minutes, removes a write per request)
2. **Batch chunk inserts** (contained, biggest throughput win)
3. **Resolve the profile once per send** (mechanical, biggest latency win)
4. **Extract the provider-open helper** (stops the duplication spreading)
5. **Attachment byte cache** (small change, removes repeated I/O)
6. **Decompose `SendMessage`** (no behaviour change, unblocks everything after)
7. `stream_chunks.payload` to `JSON`, pool tuning, cursors on the three
   unbounded queries

Nothing above is urgent in the sense of being broken today. Items 1 through 3
are what will show up first as concurrency rises.
