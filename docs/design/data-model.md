# Data model

The chat data model is three nested objects and a tree. A conversation holds contexts; a context holds a tree of messages; a message points at its parent. Everything else (profiles, providers, settings) hangs off that spine. This document explains the shapes, why they are shaped that way, and the operations that move between them: editing, branching, and compression. The exact column definitions are in [schema/database.md](../schema/database.md); this is the conceptual model.

## Conversation, context, message

A **conversation** is the top-level thing a user names and returns to. It owns a profile reference (the persona and pipeline it runs under), a title, and ordering metadata. It does not hold messages directly.

A **context** is a window of activity inside a conversation. A conversation always has exactly one active context, the one with the newest activation time, and messages are added to it. Contexts exist so the conversation can be compacted without destroying history: compression retires the current context and opens a fresh one seeded with a summary, and the old context stays on disk, fully readable. A conversation is therefore a stack of contexts over time, only the newest of which is live.

A **message** belongs to a context and points at a parent message by id, forming a tree. A linear chat is the common case (each message's parent is the one before it), but the parent pointer is what makes editing and branching work without mutating history. The leaf of the active branch is the conversation's current position.

### Roles

A message has a role:

- `system` — the persona's system framing, the top of the wire prefix.
- `context` — seeded content at the head of a context, most importantly the compression summary that opens a post-compaction context.
- `user` — a user turn.
- `assistant` — a model turn, carrying text, thinking, tool calls, and usage.
- `compression_summary` — the summary produced by compaction, the bridge between a retired context and its successor.

The role set is enforced by a CHECK constraint in the schema. These five are the whole vocabulary.

## The message tree

The parent pointer is load-bearing. It means history is append-only at the model level: editing or branching adds nodes, it never rewrites them.

**Editing** a user message creates a new message with the same parent as the original, then runs the model from there. The original and its old reply still exist in the tree; the conversation's leaf just moves to the new branch. Nothing is destroyed, so the edit is reversible and the old branch is still reachable.

**Branching** is the same mechanism made explicit: any message can be the parent of more than one child, and each child roots a distinct conversation path. The active leaf determines which path is "current." Listing messages returns the active leaf chain by default; a full-tree fetch returns every branch.

This is why the wire prefix is built by walking from a leaf up to the root rather than reading a flat list. The walk follows parent pointers through the active context and, across a compaction boundary, into the summary that seeds it. See [history-builder.md](history-builder.md).

## Profiles

A **profile** is a reusable persona: a system prompt, a default model and provider, call settings, a plugin pipeline, title-generation config, and a welcome message. Conversations reference a profile, so changing the profile changes every conversation that uses it (for anything the conversation has not overridden).

Profiles inherit through a single parent. A profile can name a parent profile, and any field it leaves unset is resolved from the parent, recursively. This is how a family of personas shares a base system prompt or a default model without copy-paste: the base profile sets it, the children inherit it, and a child overrides only what it needs. Resolution walks the chain from the profile up to the root, taking the first set value for each field.

Plugin pipelines inherit too, with a twist. A child profile's pipeline is the parent's pipeline plus the child's additions, and a child can subtract an inherited plugin by marking it disabled rather than by removing it (which it cannot, since it does not own the parent's entry). See [plugins.md](plugins.md).

## Call settings and four-layer resolution

A model call has settings: temperature, top-p, max tokens, thinking budget, and so on. These resolve through four layers, most specific wins:

1. **Conversation** — an override set on this conversation.
2. **Profile** — the profile's settings (themselves resolved up the profile parent chain).
3. **Model** — defaults attached to the enabled model snapshot.
4. **Provider** — defaults on the provider instance.

Each field resolves independently. A conversation can override temperature while inheriting max tokens from the profile and thinking budget from the model. The client shows the resolved value and labels its source (for example "Enabled (Inherited)") so the user can see where a setting comes from before deciding to override it. Some models lock a setting regardless of the layers: a model whose constraints fix temperature at 1.0 has that value forced and the others suppressed (see [providers.md](providers.md)).

## Compression and the context lifecycle

When a conversation gets long, its wire prefix gets expensive and eventually exceeds the model's window. Compression solves this by retiring the active context and opening a new one seeded with a summary of what came before. The full mechanism is in [compression.md](compression.md); the data-model view is:

- The active context is marked retired (it keeps all its messages).
- A `compression_summary` message captures the prior context's content.
- A new context is created with a newer activation time, so it becomes active, and the summary seeds its head as a `context`-role message.
- New turns append to the new context. The wire prefix from now on starts from the summary, not from the original first message, so it is short again.

Nothing is deleted. The retired context is still fully readable, and semantic search can reach back into it (see [embeddings-and-search.md](embeddings-and-search.md)), which is what lets the model recover a compressed-out passage with `search_history`. The conversation is the durable whole; the active context is just the live working set.
