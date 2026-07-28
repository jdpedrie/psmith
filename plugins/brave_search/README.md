# brave_search

One tool, `web_search`, backed by the Brave Search web index. This is how a
model that has no native browsing gets current information.

## How it works

`ExecuteTool` issues a single HTTP GET against Brave's API and trims the
response before handing it back. Brave's raw payload is large and noisy; we keep
only the fields a downstream model actually uses to synthesise an answer. The
trimmed shape is a typed Go struct so the mapping is compile-checked rather than
map-index guesswork.

The API key is a `Global` config field. It lives at user scope, entered once,
and gets merged into the per-profile config blob at pipeline-build time. Users
attach this plugin to several profiles without retyping the key, and profile
config can still override on a per-key basis if it ever needs to.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | API key plus search defaults. |
| `pluginapi.ToolProvider` | Implies a `ToolUse` model requirement. |

## Config

| Field | Notes |
|---|---|
| `api_key` | Required, global. User scope, not profile scope. |
| `default_count` | Results per query when the model does not specify. Clamped to 20. |
| `safesearch` | `off`, `moderate` or `strict`. Validated in the constructor. |
| `country` | Optional two-letter bias. |

The model can override `count` per call within the same clamp. Everything else
is fixed by config, because a model choosing its own safesearch level defeats
the point of setting one.

## Failure modes

- **No API key.** `ExecuteTool` returns "api_key is not configured". The
  constructor does not reject an empty key, because a plugin has to be
  attachable before it is configurable.
- **Bad safesearch value.** Rejected at construction with the valid set named.
  This one is worth failing early: a silently coerced value would quietly widen
  what the user thought they had restricted.
- **Non-200 from Brave.** Status and a 240-character excerpt of the body come
  back as the tool error, so a quota or auth failure is legible in the
  transcript instead of arriving as an empty result set.
- **Empty query.** Rejected before the HTTP call.
