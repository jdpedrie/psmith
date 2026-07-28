---
name: psmith-add-provider
description: "Scaffold a new Psmith provider driver under server/providers/<name>/ with proper CallSettings translation, registry init, and per-field tests. Use when adding support for a new LLM provider (e.g. Cohere, AWS Bedrock, Replicate) or a new variant of an existing one."
trigger: /psmith-add-provider
---

# /psmith-add-provider

Adds a provider driver to Psmith. Drivers live in `server/providers/<name>/`,
self-register in `init()`, and translate the shared `CallSettings` into
provider-specific request shapes.

Read [`docs/design/providers.md`](../../../docs/design/providers.md) first. It
is the canonical account of drivers, provider instances, the live catalog, and
stateless versus stateful.

## Usage

```
/psmith-add-provider <name>                 # e.g. /psmith-add-provider cohere
/psmith-add-provider <name> --openai-compat # OpenAI-compatible endpoint, use the Quirks overlay
/psmith-add-provider <name> --stateful      # long-lived session (Claude Code, Codex)
```

## Decide before writing code

**Is it OpenAI-compatible?** If the upstream is `/chat/completions` shaped, do
not add a driver. Add a `Quirks` entry to `server/providers/openai/quirks.go`
with the specific deviations: auth header name, extra body fields, custom
discovery endpoint, cache header. Most presets in
`server/providers/openai/presets.go` share the OpenAI driver this way. A new
driver is the expensive answer to a question the Quirks table usually answers.

**Stateless or stateful?** Stateless means the server owns history and every
Send replays the full prefix (Anthropic, OpenAI, Google). Stateful means the
harness owns history and the server appends turns to a long-lived session
(Claude Code, Codex). Almost everything is stateless.

**Is there an official Go SDK?** Prefer it over `net/http`. Provider-specific
features (Anthropic `cache_control`, OpenAI Responses `Reasoning.Effort`, Google
`safetySettings`) survive intact through typed params and are miserable to keep
current by hand.

## Layout

```
server/providers/<name>/
  <name>.go        # Provider type, New constructor, init() registration
  send.go          # buildXParams + Send
  send_test.go     # per-CallSettings-field translation tests
  discover.go      # DiscoverModels, if the catalog is dynamic
cmd/psmithd/main.go              # blank import _ ".../server/providers/<name>"
server/providers/providers.go    # only if adding a top-level CallSettings field
```

## Playbook

1. **Register.** `func init() { providers.Register("<name>", New) }`. The string must match `user_models.driver` going forward.
2. **Implement `providers.Provider`**: `Type()`, `Stateful()`, `DiscoverModels(ctx)`, `RenderThinkingToText(thinking)`. Stateless drivers add `Send(ctx, req) (<-chan Chunk, error)`. Stateful drivers add `StartSession`, `SendInSession`, `TerminateSession`. `CountTokens` is optional.
3. **Enrich the catalog.** `DiscoverModels` gets a `modelmeta.Catalog` at construction; use it rather than hand-writing metadata. A static-catalog driver may return a hardcoded list.
4. **Wire CallSettings.** Translate every field from `providers.CallSettings`. Drop what the provider does not support: never error, never warn. `docs/design/providers.md` has the per-driver translations.
5. **Cache routing.** If the provider takes a per-conversation cache key (OpenAI `prompt_cache_key`), pull it from `req.ConversationID` and set it every call. Implicit caching (Google) and auto-placement (Anthropic) also belong here. Anthropic's breakpoint placement is subtle: it goes on the last text block of the final assistant turn, and anything per-turn in the system slot invalidates the whole cached prefix every turn.
6. **Usage on the terminal chunk.** Emit `Usage{InputTokens, OutputTokens, CachedTokens, ...}`. Cost is computed downstream; the driver only reports tokens.
7. **Errors carry context.** A user should see "Anthropic 401: invalid api_key", not "context canceled". The HTTP layer surfaces these verbatim.

## Tests

Stdlib `testing`, table-driven. The repo does not use testify.

```go
func TestBuildParams_Temperature(t *testing.T) {
	cs := providers.CallSettings{Temperature: ptr(0.7)}
	params := buildXParams(cs, ...)
	if params.Temperature != 0.7 {
		t.Errorf("temperature: got %v want 0.7", params.Temperature)
	}
}
```

One row per `CallSettings` field the driver wires, asserting the built request
struct's shape. No live network; mock the SDK transport.

Plus a drop test per field the driver intentionally ignores.
`TestBuildParams_TopK_Dropped` confirms an OpenAI driver does not crash when
`top_k` is set.

## Verification

```bash
make test
go test ./server/providers/<name>/...
make run
```

Then add the provider through the UI, discover models, enable one, send a turn,
and check the per-message cost line shows non-zero tokens. If cost shows `--`,
the driver is not emitting `Usage` on the terminal chunk.

## Don't

- Don't error on unknown CallSettings. Drop silently.
- Don't add a top-level CallSettings field for one provider. Use the extras block (`AnthropicExtras`, `OpenAIExtras`, `GoogleExtras`, or a new `<Name>Extras`) and mirror it in the proto.
- Don't write a driver when a Quirks entry would do.
- Don't reach for `net/http` when an official SDK exists. Hand-maintained provider quirks have eaten substantial time historically.
- Don't skip tests. CLAUDE.md is unambiguous.
