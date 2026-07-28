# memory

One tool, `search_history`, that finds semantically related older messages. It
exists for long compressed conversations, where the wire prefix has been pruned
and the model needs to recover something that is no longer in scope.

## How it works

The plugin calls the `host.Searcher` on the dispatch context and returns hits as
JSON the model reads directly. No attachments, no upstream cost, because the
search is local.

It is deliberately close to config-free. The user already configured an embedder
at the daemon level via `PSMITH_EMBEDDER`, and the same searcher serves every
memory-enabled conversation. The per-call knobs (`count`, `max_distance`) are
driven by the model, not by a settings form.

Results from the caller's current active context are excluded by default. Those
messages are already in the wire prefix, so surfacing them again is budget spent
on something the model can already see. Retired contexts of the same
conversation always come through. That is the primary case: content compressed
out of scope that the model now needs back.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | Three defaults, all overridable per call by the model. |
| `pluginapi.ToolProvider` | Implies a `ToolUse` model requirement. |

## Config

| Field | Default | Notes |
|---|---|---|
| `default_count` | 5 | Used when the model does not pass `count`. Capped at 25 regardless; past that the model rarely benefits. |
| `max_distance` | 0.6 | Cosine-distance threshold. Hits above it are dropped before the model sees them. 0 disables the filter. The default is tuned for `nomic-embed-text`, where distances much past 0.6 are usually noise. |
| `include_active_context` | false | See above. |

## Failure modes

- **No searcher on the context.** "no Searcher in context, server not wired (set
  PSMITH_EMBEDDER)". The error names the fix because this one is almost always a
  deployment gap rather than a bug.
- **Empty query.** Rejected before the search.
- **Nothing above the distance threshold.** Empty result set, not an error. The
  model should be able to tell "I looked and found nothing" from "the search
  broke", and an error conflates them.
