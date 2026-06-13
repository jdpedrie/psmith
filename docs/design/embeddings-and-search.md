# Embeddings and semantic search

Reeve embeds message bodies into vectors so the model can search a user's own history by meaning, not keyword. The motivating case is a long chat that has been compressed: the wire prefix no longer holds the early turns, but the model can call `search_history` and pull back the exact passage it needs. Everything here is opt-in. A user with no embedder configured pays nothing, and the feature is invisible.

Three pieces make it work: a pluggable embedder, a background worker that fills in vectors, and a searcher that the memory plugin calls. They are wired through a per-user resolver so two users can run different embedders on the same server.

## The embedder

`internal/embeddings/embeddings.go` mirrors the provider registry. An `Embedder` is anything with three methods: `Embed(ctx, inputs)` returns one vector per input in input order, `Model()` returns a wire-stable identifier, and `Dimensions()` returns the fixed vector length. A name-to-constructor registry maps a type string to a builder that takes the user's config JSON. `Register` panics on a duplicate name so a typo fails loudly at startup, and `Build` returns a descriptive error on an unknown type.

The shipped driver is `openai`, in `internal/embeddings/openai/openai.go`. It targets any OpenAI-shaped `/v1/embeddings` endpoint and defaults to a local Ollama at `http://localhost:11434/v1` with `nomic-embed-text` at 768 dimensions. The config fields are `base_url`, `model`, `dimensions`, `api_key`, and `timeout`, all optional. An empty API key means no `Authorization` header, which is what Ollama wants. The driver re-sorts the response by index defensively, because some gateways have shipped reordered responses, and it validates that the count and dimension of what came back match what was asked for.

The driver name is stable on purpose. Every embedding is stored next to the `Model()` string that produced it, and search filters on that string. Change the registered name and you orphan every existing vector.

## Per-user config

`user_embedder_config` holds one row per user, keyed by `user_id`. The non-secret settings (`base_url`, `model`, `dimensions`, `timeout`) live in a `config` JSONB column; the API key lives in its own encrypted `api_key_encrypted` column, separate so key rotation touches only that column and a plain read needs no decrypt. An `enabled` flag and an empty `type` both mean disabled.

The row is created lazily on first write. A user with no row falls back to the daemon-wide `REEVE_EMBEDDER`, and when the row exists it wins. `internal/embeddersvc` serves the config RPCs: get (returns a sane default on no-row), update (sparse-merge, validates the type, trims a trailing slash off the base URL, encrypts or clears the key, requires base-url plus model plus dimensions before it will save, and invalidates the resolver cache), delete, test (builds the embedder and fires one `Embed("ping")` under a 30-second timeout, returning ok-or-not with a latency inline rather than as an error), and stats (the unembedded-message count that drives the progress chip, plus whether the worker is active for this user).

## The resolver

The worker and the searcher both need "the embedder for this user," repeatedly. A `Resolver` answers that, and caching is its job. `CachingResolver` builds an embedder per user on demand and caches it under a mutex, with the build running outside the lock so a slow or down upstream (Ollama not responding) blocks only the user waiting on it, not everyone. A config change calls `Invalidate(userID)` so the next turn picks up the new settings without a restart. `StaticResolver` returns one embedder for every user and is how the server-wide `REEVE_EMBEDDER` default and the tests work. The sentinel `ErrNoEmbedderForUser` means "no config or disabled"; the worker treats it as "skip this user for now," not an error.

## The background worker

`internal/embeddings/worker.go` polls `messages` for rows that have no vector, groups them by owner, asks the resolver for each owner's embedder, and writes the vectors back. Polling beats a push queue here because a partial index makes the lookup free even on a huge table: once the backlog is drained, the index has zero rows.

A batch defaults to 32 messages. When there is nothing to do the worker sleeps 10 seconds; between back-to-back full batches it sleeps 100 milliseconds to yield CPU. A batch error is logged at warn and the loop continues, so a flaky embedder cannot kill the worker. `RunOnce` is exported for deterministic tests. The unembedded query orders by `user_id`, so same-owner rows are adjacent and a single pass can flush per-owner groups at the boundaries. An `ErrNoEmbedderForUser` from a flush is swallowed silently, because that is the steady state for every opted-out user.

The query that finds work skips system framing and empty content: it embeds only `user`, `assistant`, and `context` roles with non-empty bodies. Per-row write failures are logged and retried on the next pass rather than failing the batch.

## The storage invariant

Migration `00034` adds three columns to `messages`: `embedding vector(768)`, `embedding_model TEXT`, and `embedding_at TIMESTAMPTZ`. A CHECK constraint enforces that all three are null or all three are set, so a half-written embedding is caught loudly at insert time as the write-path bug it is.

Two partial indexes carry the load. An HNSW index with `vector_cosine_ops` covers `WHERE embedding IS NOT NULL`, so build and write cost stay at zero until a row is actually embedded. A btree on `created_at WHERE embedding IS NULL` is the backlog hot path, and it shrinks to nothing once the worker catches up.

The `vector` extension has to be installed in the database before this migration runs. `CREATE EXTENSION` is not in the migration, because the migration runner usually lacks the database-level privilege it needs; `reeve install` runs an ensure-vector preflight, and the local-dev setup installs it into `template1` so every cloned test database inherits it. See [installation.md](../operations/installation.md).

### Swapping embedders

Because every vector is stored with its model name, changing the embedder does not corrupt anything. Search filters to the current model, so old vectors stay readable but stop matching, and a re-embed query lists the rows under the old model so the worker can refill them. A same-dimension swap needs no schema change. A different-dimension swap is a future migration that adds a new typed vector column, since `vector(768)` and `vector(1024)` are different types.

## The searcher

`internal/embeddings/search.go` holds the queries and a resolver, so it can embed a query under whichever embedder the calling user configured. `Search` takes a required `UserID` (there is no cross-user search surface; a nil user is an error), a limit defaulting to 10 and capped at 50, and an optional max-distance cutoff. It trims the query, resolves the embedder, embeds the single query string, and runs a cosine-distance ranked lookup filtered to the user and the embedder's model. Each hit carries the message and context and conversation IDs, the conversation title, the role, the content, the timestamp, and the cosine distance (0 identical, 2 opposite). The distance comes back so a caller can grade hit quality. Rows arrive ascending by distance, so a max-distance cutoff can stop early.

## The memory plugin

`plugins/memory.go` exposes the searcher to the model as one tool, `search_history`. It stores nothing of its own. The corpus is the message embeddings the worker already wrote; retrieval is read-only search over them. The tool takes a natural-language `query` and an optional `count` (1 to 25, default 5). A `max_distance` config (default 0.6, tuned for nomic-embed-text) drops weak hits before they reach the model.

By default the plugin skips hits from the caller's active context, because those messages are already in the wire prefix and surfacing them again wastes budget. Retired contexts of the same conversation always come through, which is the whole point: that is the compressed-out content the model is trying to recover. When active-context hits are skipped, the count of skips is reported in the output so the model is not confused by an apparently empty result on a query it expected to match.

The conversations service attaches the searcher and the caller info to the dispatch context right before it calls the tool. If no embedder is configured the searcher is nil, and the tool returns a friendly "search not configured, set REEVE_EMBEDDER" error rather than panicking. The plugin needs the `tool_use` capability like any other tool provider, and it is one of the shipped plugins in [plugins.md](plugins.md).
