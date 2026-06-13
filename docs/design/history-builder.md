# History builder

Before a stateless provider can run a turn, the server has to turn the stored message tree into a flat, wire-shaped prefix. That is the history builder's whole job: take a conversation and a destination provider, walk the tree, map roles, decide what thinking travels, inline attachments, apply plugin transforms, and hand back a list of `WireMessage`. It lives in `internal/history` and is deliberately pure mechanics. It makes no policy decisions; the caller resolves all the policy (which leaf, whether thinking is allowed, which plugins) and passes the answers in.

## What it produces

`Build(ctx, queries, Params)` returns `[]providers.WireMessage`, root-first, ready to drop into a `SendRequest`. A wire message has a wire role (`system`, `user`, or `assistant` only), text content, and optional attachments. The stored model has five roles; the wire model has three. Collapsing one into the other is most of what the builder does.

## Walking the tree

The steps:

1. Find the active context for the conversation. A valid conversation always has one; its absence is a data-integrity error (`ErrNoActiveContext`).
2. Determine the leaf. The caller can pin it with `LeafMessageID` (which must live in the active context), otherwise the builder finds the sole childless message. If the context has more than one leaf (a fork) and no leaf was pinned, it errors with `ErrAmbiguousLeaf`, because it cannot guess which branch you mean.
3. Walk `parent_id` from the leaf back to the root, accumulating messages. A parent that is not in the active context is `ErrBrokenParentChain`, which a well-formed conversation cannot produce because parent pointers are scoped to a context.
4. Reverse into a root-first list.
5. Map roles and apply thinking inclusion.

The walk is per-context. The prefix begins at the active context's root, which after a compaction is the `compression_summary` seeded as a `context` message, not the original first message of the conversation. That is the mechanism that keeps a compacted conversation's prefix short: the builder never walks past the active context into a retired one. See [compression.md](compression.md) and [data-model.md](data-model.md).

## Role mapping

Wire roles are `system`, `user`, `assistant`. The stored roles map down:

- `system` stays `system`.
- `user` stays `user`.
- `assistant` stays `assistant`.
- `context` becomes `user`. A context message (most importantly a compression summary at the head of a post-compaction context) is fed to the model as user-role content.
- `compression_summary` is handled as context seeding rather than as a normal turn.

An unknown stored role is surfaced as `ErrUnknownRole` rather than silently dropped, even though the schema CHECK constraint should make it impossible. The builder would rather fail loudly than send a malformed prefix.

## Thinking

Whether stored reasoning travels on the wire depends on two things, both passed in. `IncludeThinking` is the resolved per-conversation setting; when false, no thinking is ever included. `DestProviderType` decides the form when it is allowed: a stored Anthropic thinking blob can travel as native signed thinking back to Anthropic, but to a different provider it is rendered to plain text through the driver's `RenderThinkingToText` and injected as text. This is what lets a conversation move between providers without a previous provider's reasoning format breaking the next turn. The signature capture that makes native replay possible happens during streaming (the `thinking_signature` chunk); the builder just decides whether to carry the blob and in what form.

## Tool history

A stored assistant message can carry tool calls (the `tool_calls` JSON column). The builder splits that payload back into tool-use blocks and matching tool-result blocks so the wire prefix reconstructs the full tool exchange the model saw originally. This is the path that was wrong for cross-provider tool history: an OpenAI model continuing a conversation where Anthropic had called tools needs those calls translated into the OpenAI Responses `function_call` / `function_call_output` shape, which the driver does on the way out. The builder's job is to faithfully reproduce the blocks; the driver's job is to render them in its native shape.

## Attachments

If a message in the chain has attachment rows, the builder inlines the blob bytes onto the wire message so the driver can translate them into the provider's image or file shape. It loads all attachments for the chain in one query, then reads each blob from storage (partitioned per user, which is why `UserID` is required when attachments exist). A blob that has vanished from storage is logged and dropped rather than fatal, so a missing image does not brick the conversation; the message just goes to the provider without it. Attachment inlining is opt-in via the `Attachments` reader so tests that do not exercise it leave it nil.

The bytes are hung on the wire message rather than spliced into its text, so each driver decides how to represent them (an image block, base64 inline, a file reference) or whether to drop them.

## Plugin contributions

Two plugin capabilities run inside the builder, both passed in via the resolved `Plugins` pipeline:

- **System prompters** contribute to the system slot. Their text augments the persona's system prompt (prepend or append), so a plugin can inject standing instructions without the persona owning them.
- **History transformers** mutate user and assistant messages, given each message's position relative to the head of the prefix. This is how a plugin like lettered-choices rewrites recent turns. The position information is what lets a transformer act only on the last N messages.

The position handed to a transformer also carries the destination provider type. That is what lets a transformer behave differently per backend, which is how the lettered-choices cache fix works: the transformer skips its rewrite for Anthropic so it does not mutate a message inside Anthropic's cached prefix and bust the cache breakpoint every turn. The other plugin capabilities (chunk transforms, display, outgoing-user, tools) run elsewhere in the pipeline, not in the builder. See [plugins.md](plugins.md).

## Why it is pure

The builder takes no opinion on whether thinking should travel, which plugins are active, or whether to compact. All of that is resolved by the conversations service and passed in through `Params`. Keeping the builder pure means it is exhaustively unit-testable against a fake queries interface without standing up a database, and it means the policy lives in one place (the service) rather than smeared across the assembly code. The builder is the deterministic function from (tree, leaf, destination, settings, plugins) to (wire prefix).
