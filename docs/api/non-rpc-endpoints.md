# Non-RPC endpoints

A few things do not fit the ConnectRPC mold and are served as plain HTTP on the same mux as the RPC services. They are mounted in `cmd/psmithd/main.go`. All except `/healthz` use the same bearer session as the RPCs.

## `GET` / `HEAD /files/{id}`

The file download. Unlike the rest of the API it authenticates with a signed URL query token rather than a bearer header, so an image loader that cannot set headers (or a cached `<img>` URL) can fetch bytes directly.

- Mint the URL with `FilesService.GetFileURL`, which returns `/files/{id}?token=...`. The token is an HMAC over the file id, the owner, and an expiry, signed with a sub-key derived from the master key ([encryption.md](../design/encryption.md)).
- `GET` streams the bytes with the stored content type and a short, immutable cache header (the bytes are content-addressed, so they never change for the life of the URL). `HEAD` returns the headers only.
- Every failure mode (bad or expired token, wrong owner, missing file) returns the same `404`, so the endpoint leaks nothing about whether a file exists.
- The signed URL is short-lived (a few minutes). Mint a fresh one rather than persisting it; a stale URL just 404s.

## `POST /conversations/{id}/device-tools/{call_id}/respond`

How a client returns the result of a device tool the server asked it to run ([tools.md](../design/tools.md)). Bearer-authenticated with the same session as the RPCs.

- The conversation is ownership-checked; a cross-user or missing conversation returns `404`, not `403`.
- Body: `{"output": <json>}` or `{"error": "..."}`, at least one present. A blank body is `400`.
- Success is `204`. The write is once-only; a second post for the same call id returns `404`.
- The server has about 60 seconds from emitting the `DEVICE_TOOL_USE` chunk before the call times out and the model sees a timeout result.

## `POST /conversations/{id}/elicitations/{eid}/respond`

How a client returns a user's answer to an elicitation the server raised mid-run ([tools.md](../design/tools.md)). Bearer-authenticated.

- Ownership-checked with the same cross-user `404` masking.
- Body: `{"action": "accept"|"decline"|"cancel", "content": {...}}`. Content matters only on accept.
- Success is `204`, write-once.
- The timeout is generous (about five minutes), because the user may be fetching a secret from a password manager.

The elicited content flows to the waiting tool and never enters the model's context or the persisted transcript.

## `POST /tts`

Read-aloud synthesis for one message ([speech.md](../design/speech.md)). Bearer-authenticated. Audio streams through and is never persisted server-side — this response is the only copy the server ever holds.

- Body: `{"message_id": "<uuid>"}`. Ownership is checked through message → context → conversation; cross-user or missing returns the same `404`.
- Success streams `audio/pcm` (s16le mono) with `X-Speech-Sample-Rate` (24000) and `X-Speech-Normalizer` (the normalizer version, part of the client replay-cache key). Chunks flush as the provider synthesizes each text segment, so playback can start on the first one.
- `412` when the user's speech config is `apple_local` — that kind synthesizes on-device and the client should not have called.
- `422` when the message has no speakable text after normalization.
- Provider failure before any audio is a `502` carrying the provider's error excerpt; failure mid-stream truncates the audio (the 200 is already committed) and logs server-side.
- Each successful call writes a `cost_events` row when the config references a chat provider; self-hosted and standalone-key configs skip the ledger.

## `/mcp`

Psmith's own MCP server surface, mounted for dogfooding through the `mcp` plugin. `POST`-only (other methods `405`), Streamable-HTTP transport with JSON responses (no SSE), and the same bearer session as the RPCs (a `401` on a bad token). It exposes a curated subset of Psmith's RPCs as MCP tools (profile, plugin-pipeline, conversation, and model/provider operations), all scoped to the authenticated user. The same dispatcher is also reachable in-process by the `mcp` plugin without a network hop, which is the transport elicitation runs over. Protocol and tool detail are in [tools.md](../design/tools.md).

## `/healthz`

An unauthenticated liveness check that returns a simple OK. It is the one endpoint that does not require a session, suitable for a load balancer or container health probe. To validate that a server is a Psmith server and learn its version, a client uses the `AuthService.Probe` RPC instead, which is also unauthenticated but returns structured identity.
