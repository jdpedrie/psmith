# Compression

A long conversation eventually outgrows the model's context window, and even before that the wire prefix gets slow and expensive to re-send every turn. Compression solves it by summarizing the conversation so far and starting a fresh context from that summary, while keeping every original message on disk. The design is two-stage and user-reviewable on purpose: the model proposes a summary, the user reads and edits it, and only then does it become the seed of a new context. Nothing is destroyed and nothing happens behind the user's back.

## Why two stages

A one-shot "compact now" that immediately swapped in a model-written summary would be unsafe. The summary is lossy by definition, and if the model dropped something important the user would have no recourse. So compaction splits in two:

1. **Compact** produces a `compression_summary` message in the current context. It is just a message: visible, durable, and editable. Nothing about the conversation's active context changes yet.
2. **Promote** takes that summary (possibly after the user has edited it) and creates a new context seeded from it. This is the step that actually rolls the conversation forward.

Between the two steps the user reviews. If the summary is wrong, they edit the message before promoting, or they do not promote at all.

## Stage one: Compact

`Compact` resolves the compression model, guide, and mode from the profile inheritance chain, with per-call overrides allowed on the request so the client's compact screen can pick a model and prompt for a single invocation without persisting to the profile. All three (a provider, a model, and a guide) must resolve to something, or the call fails with `FailedPrecondition`; the per-call override also covers the case where the profile points at a model the user has since disabled.

It renders the active chain (the linear walk from the current leaf back to root, not every row in the context, so forks do not pollute the summary with sibling turns the user cannot see) into a transcript, builds the compression prompt from the guide, and hands it to the supervisor with a compression purpose. It returns the run id immediately and streams like any other turn. On the terminal handler, the supervisor writes the `compression_summary` message into the original context, with its own usage, cost, and `finish_reason` recorded, and a Langfuse trace tagged `compression` in the same session.

The compression call does not inherit the conversation's call settings; it builds its own. The output budget is the model's `max_output_tokens` capped at 32768, falling back to 8192 when the model row does not know its ceiling. The cap must budget for hidden reasoning, not just the visible summary: current-generation models think by default and spend those tokens from the same output budget as the text (OpenAI's `max_output_tokens` covers reasoning plus text, Gemini counts thoughts toward `maxOutputTokens`, Anthropic's adaptive models count thinking toward `max_tokens`). A fixed 8192 cap was routinely half-eaten by reasoning and the summary hard-truncated mid-sentence with `finish_reason=max_tokens`. Thinking is also force-disabled on the request, but that is best-effort: the OpenAI driver translates it to `reasoning.effort=low` on reasoning models (there is no off position), Gemini's `includeThoughts=false` only hides the thoughts, and Anthropic's adaptive generation decides for itself.

If a leg still stops at the cap, the send wrapper (`compact_continue.go`) continues it transparently: it re-sends the same request with the accumulated partial appended as an assistant turn plus a continue-exactly-where-you-stopped instruction, and pipes the new leg's chunks into the same stream, so the supervisor, subscribers, and the materialized summary all see one uninterrupted run. Two failure shapes showed up in a live compaction and are guarded against: a model with no thinking channel narrates its planning as visible prose (the compression prompt now demands the document and nothing else — no deliberation, no preamble), and a continuation leg can RESTART the document from the top instead of resuming (the partial ended mid-deliberation and the model chose to start clean, duplicating every section). The wrapper's restart probe buffers each continuation leg's opening, compares it — whitespace-insensitively — against the head of the accumulated document, and on a match discards the superseded accumulation: `partial` resets so later legs get the right context, and a `content_reset` chunk tells consumers to do the same, which is what keeps the MATERIALIZED summary clean. The already-streamed text can't be retracted from live subscribers; they converge at terminal when they fetch the settled row. Legs are capped at 4 total so a model that reports a length stop forever can't loop spend; token usage sums across legs (each leg bills its own input pass, mostly cache reads), and the final `finish_reason` is the last leg's, so a cap-exhausted summary still says `max_tokens` while a finished one says `end_turn`. The persisted `finish_reason` is how a capped summary stays distinguishable from a complete one, and the review UIs read it: a `max_tokens`/`length` summary is badged "Truncated" with a delete-and-re-run recommendation on the summary card, the review bar, and the web compact page (`PsmithMessage.isTruncatedOutput` client-side, `isTruncatedFinish` in `internal/web`) — confirming a cut summary would bake the missing tail into the fresh context. The run row itself carries no finish reason; when one is needed for a run, join through `stream_runs.result_message_id` to the message. One caveat: between legs the consume loop's 60-second idle timeout keeps running, so a continuation whose first token takes longer than that (cold cache on a giant transcript) errors the run rather than hanging it.

A context can hold only one pending compression summary at a time. `Compact` and `SendMessage` both refuse to proceed when the active context already has an un-promoted summary, which is what keeps the two-stage flow honest: you finish reviewing and promoting before the conversation moves on.

## Stage two: Promote

`PromoteCompactionToNewContext` takes the summary message id, verifies it is actually a `compression_summary` and owned by the caller, and creates a new context whose parent is the source context, whose activation time is now (making it the active context), and whose leaf is initially null. It seeds that context with a single `context`-role message computed from the summary.

How the seed is computed depends on the resolved compression mode:

- **REPLACE** (the default): the new context's seed is the summary as-is. The new prefix starts from the summary and forgets the prior framing.
- **APPEND**: the new seed is the prior context's framing message concatenated with the new summary. This accumulates framing across compactions rather than replacing it, for conversations that carry standing context that should survive every compaction.

The whole promote runs in a single transaction so the new context and its seeded message land atomically.

Promote is deliberately not idempotent. Calling it twice creates two new contexts from the same summary, each becoming active in turn, which is a usable "compact and branch into two directions" move rather than a bug to guard against.

## What happens to the old context

Nothing destructive. The source context keeps all its messages and its compression summary; it is simply no longer the active context once a newer one exists (active is defined as the context with the newest activation time, see [data-model.md](data-model.md)). The history builder walks only the active context, so from the next turn on the wire prefix starts at the new context's seed and is short again. But the old context is fully readable on demand, and semantic search reaches into it, which is exactly what lets the model recover a compressed-out passage later with `search_history` ([embeddings-and-search.md](embeddings-and-search.md)).

## How it shows up elsewhere

Compression-summary rows are audit records, not real turns, so the conversation listing and similar surfaces skip them where they would otherwise be counted as content. The cost of a compaction lands on the summary message like any other turn's cost and flows into the ledger ([titles-cost-observability.md](titles-cost-observability.md)). The summary's own auto-title path is suppressed; compaction never triggers conversation titling.

The pending state is a first-class UI mode, not just a server precondition. While a clean summary awaits the user's verdict, the clients swap the composer for a review bar carrying exactly two actions — Delete (resume the current context as if compaction never happened) and Confirm (promote into a fresh context) — and disable the compact button; the server would refuse sends and re-compacts anyway, so the bar is the UI reflecting the contract rather than enforcing it. The summary itself renders as content in the transcript, editable through the same context-menu affordance as every other message (the matrix across clients: any role's content is editable; role flips are user↔assistant only). An errored summary does not gate the conversation — it renders with inline Dismiss/Retry and the composer stays live.

## Rendering the summary is a size problem

The continuation loop means a summary can legitimately run past 100KB, and the Swift clients cannot hand a document that size to MarkdownUI inline: the transcript row would build the whole document's view tree in one main-thread layout pass, SwiftUI's update bookkeeping goes quadratic in the view count, and the app hard-locks (reproduced at 180KB — 100% CPU indefinitely, transcript never renders, exactly the "open a conversation with a pending compaction and the app freezes" report). Every transcript markdown site therefore renders through `MarkdownBudget` (`PsmithUI/Atomic/BoundedMarkdown.swift`):

- The summary card shows a short head preview (cut at a line boundary, open code fences re-closed) plus a "Show full text" affordance opening a chunked viewer — the document split at paragraph boundaries into a LazyVStack, so any size opens at interactive speed. The card's preview budget is deliberately small (1,500 chars): the full document is one tap away, and the card being the tallest row in the cold-entry window destabilizes the transcript's scroll-entry estimates.
- Regular message bubbles get the same guard at a larger budget (8,000 chars) — an assistant turn near a large `max_output_tokens` is the same failure class.
- The live stream row renders only the clamped tail of the accumulating text (with a fence reopened when the cut lands inside one) — a full markdown re-layout per flush at multi-leg scale freezes the same way. The settled row renders the full bounded body at terminal.

The web client renders markdown through the browser, which handles large documents fine; the budget is a SwiftUI-client concern.
