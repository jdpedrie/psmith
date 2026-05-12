# Reeve — multi-modal support plan

Design plan for getting non-text content through Reeve: file uploads (incl. image input), image generation, speech-to-text, and text-to-speech. Live audio APIs (OpenAI Realtime / Gemini Live) are explicitly out of scope and warrant their own pass.

Reads as a sibling to `architecture.md` (long-lived design) and `todo.md` (in-flight tactical TODOs). Once each phase ships, the corresponding bullets here can move into the "shipped" record at the top of `todo.md` and the residual deferrals collapse back into this doc as "Open threads".

---

## Scope

| Capability | Where the work lives |
|---|---|
| **File uploads** (incl. image input) | Storage + data model + wire + drivers + UI — the foundation everything else needs |
| **Image generation** | Mostly falls out of file uploads + a tool plugin; native (model emits image inline) needs driver chunk work |
| **STT** | Two paths: client-side transcribe-then-send (free, works everywhere) vs send-audio-directly to a multimodal model |
| **TTS** | Two paths: local Apple `AVSpeechSynthesizer` (free, immediate) vs cloud TTS (ElevenLabs / OpenAI / Google) plugin |

**Out of scope, separate plan:** Realtime / Live full-duplex audio sessions; video input.

---

## Architectural decisions (locked in)

1. **Generic storage interface from day one.** A `Storage` interface in `internal/storage` with a filesystem implementation as the v1 backend. S3 / blob-store implementations slot in later without touching callers.

2. **No cross-user dedup.** Storage path bakes the `user_id` into the filesystem layout: `$REEVE_DATA_DIR/files/{user_id}/{sha256}` for the filesystem backend. Two users uploading identical bytes produce two physical files. Within a single user, the content-addressed SHA-256 path naturally dedups: re-uploading the same image by the same user reuses the existing file row.

3. **50 MB hard cap on uploads.** Enforced at the upload endpoint before any bytes hit disk, and enforced again on the inline-base64 path to keep request sizes sane.

4. **Inline-base64 v1; provider Files API caching as a later phase, done right.** Drivers attach inline bytes to outbound requests in v1. The data model is shaped so we can later add a per-provider, per-file mapping table (`provider_file_uploads (file_id, provider_id, provider_file_id, expires_at)`) and have drivers prefer a cached upload over re-inlining. Provider-side cached files matter most for Anthropic + Gemini conversations with stable image attachments — re-inlining the same 5 MB image on every turn is the kind of cache-hostile thing the rest of Reeve avoids.

5. **Cache observability hashes attachments.** The prefix-cache stability calculation (currently text-only) extends to include each user-message attachment's SHA-256 in the hash chain. Without this, the cache observability dot lies on multimodal turns. The `stream_runs` cache observability columns already cover this conceptually; only the implementation in `internal/conversations/cache_observability.go` needs the attachment fold-in.

6. **Client-side preprocessing before upload.** The client converts HEIC→JPEG (quality 90), downsizes so the longest edge is ≤ 2048 px, and strips EXIF before computing the SHA-256 and uploading. Three motivations: (a) most providers reject HEIC outright; (b) per-tile / per-pixel pricing on vision models makes 4000×3000 phone photos uneconomical when 2048×1536 carries the same semantic content; (c) EXIF GPS / device metadata is data exfiltration the user didn't sign up for. The original file is never sent — the SHA-256 (and dedup) is over the preprocessed bytes.

7. **Compression converts attachments to file refs + recall tool.** On context compression, attachments in the compressed prefix are replaced with a textual reference of the form `[image: kitchen_sink.jpg #f0a3]` (where `f0a3` is a short prefix of the `file_id` — full UUID would clutter the summary). A built-in `recall_attachment(file_id)` system plugin (auto-available whenever the conversation has any attachments) lets the model fetch the inline bytes back on demand. Side benefits: the compressor model doesn't need vision capability (it sees text refs), and the user pays inline-image cost only on turns where the model actually needs the image. Retention bookkeeping: when compression converts attachments to refs, the `compression_summary` message gets `message_attachments` rows with `role_hint='compressed_reference'` so the FK-based GC keeps the underlying file alive.

---

## Data model

### `files` table (new)

```sql
CREATE TABLE files (
    id                UUID        PRIMARY KEY,
    user_id           UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256            TEXT        NOT NULL,
    mime_type         TEXT        NOT NULL,
    size_bytes        BIGINT      NOT NULL,
    original_filename TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Within a user, identical content produces one row. Different users
    -- get different rows even for byte-identical content (no cross-user
    -- dedup, per scoping decision above).
    UNIQUE (user_id, sha256)
);
CREATE INDEX files_user ON files (user_id, created_at DESC);
```

Persistence is handled via the `Storage` interface; the row's `id` is the public handle. Bytes never live in the DB.

### `message_attachments` table (new)

```sql
CREATE TABLE message_attachments (
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    ordinal    INT  NOT NULL,
    file_id    UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    -- image | audio | document | video. The kind is denormalized off
    -- the file's mime_type for fast-path routing in drivers and UI
    -- (avoids a join + parse on every history build).
    kind       TEXT NOT NULL,
    -- "user_supplied" | "tool_result" | "model_generated" | "compressed_reference".
    -- Lets the UI distinguish "user sent it" from "model emitted it"
    -- from "tool returned it" from "compression kept a reference so
    -- the recall plugin can fetch it back" — same rendering, different
    -- provenance for audit, export filters, and GC retention.
    role_hint  TEXT NOT NULL DEFAULT 'user_supplied',
    PRIMARY KEY (message_id, ordinal)
);
CREATE INDEX message_attachments_file ON message_attachments (file_id);
```

`messages.content` keeps its meaning — primary text body of the turn. Attachments ride alongside in stable `ordinal` order. A user "image-only" message has `content = ""` plus one attachment row.

### `provider_file_uploads` table (deferred to phase 4 — sketched here so the migration shape is foreseeable)

```sql
CREATE TABLE provider_file_uploads (
    file_id          UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    provider_id      UUID NOT NULL REFERENCES user_model_providers(id) ON DELETE CASCADE,
    provider_file_id TEXT NOT NULL,    -- e.g. OpenAI "file_abc123", Gemini "files/xyz"
    expires_at       TIMESTAMPTZ,      -- some providers TTL their files; null = no TTL
    uploaded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (file_id, provider_id)
);
```

Drivers consult this table when building requests; on cache miss, they upload via the provider's Files API and insert the row. On `expires_at`-elapsed rows the driver re-uploads. This phase is not implemented in v1 — but the v1 file storage already ships with stable `file_id`s ready to be referenced.

---

## Wire shape

`providers.WireMessage` extension:

```go
type WireMessage struct {
    Role        string
    Content     string                  // primary text part — unchanged
    Attachments []Attachment            // new
    Thinking    json.RawMessage
    ToolUses    []ToolUseBlock
    ToolResults []ToolResultBlock
}

type AttachmentKind string
const (
    AttachmentImage    AttachmentKind = "image"
    AttachmentAudio    AttachmentKind = "audio"
    AttachmentDocument AttachmentKind = "document"
    AttachmentVideo    AttachmentKind = "video"
)

type Attachment struct {
    Kind     AttachmentKind
    MimeType string                     // "image/png", "audio/wav", "application/pdf"
    // Exactly one of Data / URL / ProviderFileID is populated. The
    // first is set when history.Build inlines the bytes; the second
    // when the attachment lives at a stable URL the provider can
    // fetch (rare in v1); the third when a phase-4 cached upload
    // resolved against the active provider.
    Data            []byte
    URL             string
    ProviderFileID  string
    Filename        string              // original name; rendered for documents
}
```

`history.Build` inlines `Data` from filesystem reads in v1. Phase 4 swaps in `ProviderFileID` resolution before falling back to inline.

### Per-provider translation

| Provider | Image | Audio | PDF/Doc | Video | Attachments in tool_result |
|---|---|---|---|---|---|
| **Anthropic** | `image` content block (inline base64 or URL) | not supported (drop with log) | `document` content block (PDF only, base64) | not supported | yes — `image` block inside `tool_result.content` |
| **Google Gemini** | `inline_data` part (base64) or `file_data` (Files API URI) | `inline_data` audio/wav (multimodal models) | `inline_data` PDF | `inline_data` video/* (Gemini-only) | yes — `inline_data` part inside `function_response` |
| **OpenAI Chat** | `image_url` content part | not supported on Chat | not supported on Chat | not supported | no — `tool` message content is text-only |
| **OpenAI Responses** | `input_image` content part | `input_audio` (gpt-4o-audio family) | `input_file` via Files API | not supported | yes — `function_call_output.output` accepts content parts |
| **OpenAI-compatible (OpenRouter etc.)** | passes through `image_url` per Chat path | per-gateway support | per-gateway support | per-gateway support | gateway-dependent; default no |

A new `Provider.Capabilities()` method (or a static capability table per driver) advertises supported kinds; the UI uses this to grey out attachment buttons for the active model and to silently strip unsupported attachments from history (with a stamped warning) when a multi-provider conversation switches into a model that can't render older attachments. The `acceptsAttachmentsInToolResults` axis specifically gates whether the `recall_attachment` system plugin returns inline bytes (yes) or a text fallback ("file is not viewable on this model — switch to a vision-capable model to inspect it") (no).

---

## Streaming changes

New chunk types for assistant-emitted media (image generation, audio output):

- `ChunkAttachmentStart` — `{id, kind, mime_type, filename?}`
- `ChunkAttachmentData` — `{id, base64_chunk}` (chunked for large images)
- `ChunkAttachmentEnd` — `{id, total_size, sha256}`

Aggregator in the supervisor (mirrors the existing tool-call aggregator):
- on `Start`: open a temp buffer
- on `Data`: append base64-decoded bytes
- on `End`: hash, store via the `Storage` interface, insert a `files` row, attach to the materialised assistant message via `message_attachments` with `role_hint = 'model_generated'`

The wire transport stays JSON-serialisable; byte transmission via `base64_chunk` is enough for the typical image sizes this path produces. For genuinely large media (video, multi-MB audio) we can revisit by adding a side-channel `/files/upload` endpoint the driver streams to and emits only the resulting `file_id` over the chunk stream.

---

## Storage interface

```go
// internal/storage/storage.go
type Storage interface {
    // Put writes bytes for (userID, sha256) and returns the storage key
    // (driver-specific — filesystem path, S3 key, etc). Idempotent: a
    // second Put with identical inputs is a no-op.
    Put(ctx context.Context, userID uuid.UUID, sha256 string, mime string, data io.Reader) error
    // Get streams the bytes for (userID, sha256). Returns ErrNotFound
    // when the object isn't present.
    Get(ctx context.Context, userID uuid.UUID, sha256 string) (io.ReadCloser, error)
    // Delete removes (userID, sha256). Idempotent — missing object is
    // not an error. Cascade is the caller's job (delete the files row
    // first, then the bytes; the FK on files prevents dangling rows).
    Delete(ctx context.Context, userID uuid.UUID, sha256 string) error
    // SignedURL produces a short-lived URL the client can fetch the
    // object from without going through Connect-RPC. v1 implementation
    // returns a Reeve-served `/files/{id}?token=…` URL signed with an
    // HMAC over (file_id, user_id, expires_at). Phase-N S3 backend
    // returns a presigned S3 URL.
    SignedURL(ctx context.Context, fileID uuid.UUID, ttl time.Duration) (string, error)
}
```

v1 implementation: `internal/storage/fs.Storage` writing to `$REEVE_DATA_DIR/files/{user_id}/{sha256}`. Configurable via `REEVE_DATA_DIR`. Permissions 0600 on every file; 0700 on the per-user dir.

The signed-URL endpoint lives outside the Connect-RPC path — straight HTTP `GET /files/{id}?token=…` with an HMAC interceptor that decodes the token, verifies `(file_id, user_id, expires_at)`, and streams the bytes. Thirty-second TTL is enough for a `<img src>` to load before token expiry; auto-renewable via a separate "refresh URL" RPC if a user wants persistent download links.

---

## Per-capability design

### File uploads + image input (Phase 1 — the keystone)

Composer changes (Mac + iOS, designed in parallel):

**Mac:**
- Drag-drop target on the entire composer area (SwiftUI `onDrop`)
- Paperclip button opens `NSOpenPanel` filtered by the active model's supported MIME types
- Paste-image: cmd-V on the composer reads `NSPasteboard.general` for `NSImage` / file-URL types and uploads as if dragged

**iOS:**
- Paperclip menu offers: "Photo Library" (`PhotosPicker(matching: .images, ...)`), "Take Photo" (`UIImagePickerController(.camera)`), "Choose Files" (`.fileImporter`), "Scan Document" (`VNDocumentCameraView` → PDF)
- Paste-image: long-press the composer → standard system Paste action uploads the clipboard image when present
- Drag-drop via `.dropDestination` on iPad (and iPhone in split mode, where it works)

**Shared:**
- Inline thumbnail/chip strip above the text field showing pending attachments (with remove button per chip)
- Capability gating: when the active model lacks image support, the paperclip dims with a "switch model" tooltip / popover; drag-drop target shows a "this model doesn't accept images" overlay
- Pre-upload preprocessing pipeline (see locked-in decision #6): on Mac via `CoreGraphics` / `ImageIO`, on iOS the same APIs are available — shared Swift code in `ReeveKit` so both platforms run identical preprocessing. EXIF strip is the same `CGImageDestination` re-encode that does the format conversion.

Upload flow:
1. Client runs the preprocessing pipeline (HEIC→JPEG, downsize to ≤2048 px longest edge, strip EXIF) and computes the SHA-256 of the resulting bytes locally
2. Calls `UploadFile(sha256, mime, size, original_filename, bytes_chunks)` RPC (client-streaming for the bytes — chunked send over a Connect client stream so a 50 MB upload doesn't sit in one giant message; user_id is implicit from the auth interceptor)
3. Server: `Storage.Put` → insert `files` row (idempotent on `(user_id, sha256)` — a re-upload of the same content returns the existing `file_id`) → return `file_id`
4. Client adds the `file_id` to the pending attachments on the composer (with an inline thumbnail rendered from the local preprocessed bytes — no signed-URL round-trip needed for the preview)
5. On `SendMessage`, the request includes a `repeated string attachment_file_ids` field; the server resolves each into a `message_attachments` row when persisting the user message

Message rendering:
- Image attachments render as a thumbnail (loaded via signed URL) with click-to-expand inline lightbox
- Document attachments render as a download chip: filename · size · "Open in Quick Look" / "Open in Finder"
- Audio attachments (when phase 5 lands) render as a play-button chip with waveform preview

### `recall_attachment` system plugin (Phase 1 — ships with compression-as-file-refs)

A built-in plugin (no user configuration; auto-registered for every conversation that has any attachments) exposing one tool:

```
recall_attachment(file_id: string, reason?: string) -> attachment
```

- Server-side: looks up `files` by id, asserts `files.user_id == ctx.user_id` (404 to the model otherwise — no info leak), reads bytes via `Storage.Get`, returns them as a tool_result attachment.
- Provider-side: the tool-result attachment is wired through the per-provider translation table's "Attachments in tool_result" axis. Providers without that capability (OpenAI Chat, most OpenAI-compatible gateways) get a text response of the form `"recall_attachment: file is not viewable on the current model. Switch to a vision-capable model to inspect it."` — the model then knows to either bail or ask the user to switch.
- Discoverability: the tool's description includes "Use this when a compressed summary mentions `[image: name #abc]` and you need to actually see the image to answer the user." The compressed-summary text-ref format intentionally embeds the short file_id so the model has the argument it needs.
- Cost story: the recall round-trip is the explicit price the model pays to see an image. Cheaper than always-inlining since most turns don't need the image. The `reason?` arg lets us telemeter why models reach for the tool.

### Image generation (Phases 3 + 4)

**Phase 3 — tool plugin.** New `image_gen` plugin with a `generate_image` tool. ToolProvider executes against an image-gen API (configurable: OpenAI Images, Stability, Imagen). Tool call result is `{file_id}`; the supervisor treats it like any other tool result, but the conversations-side tool loop additionally creates a `message_attachments` row (`role_hint = 'tool_result'`) on the assistant message linking to the file. UI renders the image inline below the assistant text — no new components needed beyond Phase 1.

Plugin config: API key (Global), default size, default style. Required-field validation flags missing keys per the existing pattern.

**Phase 4 — native inline image emission.** Drivers that emit images as part of their normal response stream (Gemini imagen, OpenAI Responses + gpt-image-1) detect image content blocks and emit `ChunkAttachmentStart/Data/End`. Supervisor aggregator persists. UI rendering is identical to Phase 3.

### Speech-to-text (Phases 0 + 5)

Phase 0 ships as the **default** (it's free, fast, and works against every model). Phase 5 is an opt-in per-profile setting for users who specifically want the multimodal model to hear pronunciation / tone rather than transcribed text.

**Phase 0 — local-only, send-as-text.** Both clients use `SFSpeechRecognizer` (or `SpeechAnalyzer` on macOS 26 / iOS 26+) for live dictation. Mic button in the composer; press-and-hold to record, release to stop, transcribed text appears in the composer's text field; user reviews and sends as plain text. No backend changes. Free, fast, private.

**Phase 5 — audio attachment, model transcribes.** Per-profile setting "Send audio to model" flips the mic button from Phase 0's transcribe-locally mode to recording an `audio/wav` (or `audio/m4a`) attachment that flows through the Phase 1 attachment path to a multimodal model. Provider drivers that don't support audio degrade gracefully via the capability table. Optionally: have the model's response include a transcript surfaced in the message UI (a dedicated content type or a convention on the first paragraph).

### Text-to-speech (Phases 0 + 6)

**Phase 0 — local AVSpeechSynthesizer.** Mac + iOS. Speaker icon on each assistant message; tap to start speaking, tap to stop. Per-profile auto-speak toggle. Queue-aware (clicking a different message stops the prior). Voice quality is meh but acceptable; works offline; free; no backend.

**Phase 6 — cloud TTS plugin.** `cloud_tts` plugin with provider config (OpenAI / ElevenLabs / Google). API key + voice + speed in the config; auto-speak selector on profiles selects which TTS plugin (or "local") to use for that profile. Streaming TTS (sentence-by-sentence playback) for low latency on long responses; falls back to whole-response synthesis when the provider doesn't stream.

---

## Phasing

| Phase | Scope | Estimate | Blocks |
|---|---|---|---|
| **0 — Local TTS + STT** | AVSpeechSynthesizer playback + SFSpeechRecognizer dictation, Mac + iOS | ~1 week | Independent — can land first |
| **1 — File storage + image input** | `Storage` interface + filesystem impl, signed URLs, files + message_attachments tables, WireMessage.Attachments, Anthropic + Google + OpenAI Responses + OpenAI Chat image translation, capability table, composer drag-drop, image attachment renderer, cache observability hashing | ~3-4 weeks | Foundation — blocks all later phases |
| **2 — Document attachments** | PDFs (Anthropic + Gemini), generic docs (OpenAI Files API for OpenAI Responses), document chip renderer | ~1 week | Phase 1 |
| **3 — Image generation tool plugin** | `image_gen` plugin wrapping OpenAI Images / Stability / Imagen, tool-result → message_attachments wiring | ~1 week | Phase 1 |
| **4 — Native image generation + provider Files API caching** | Driver chunk handling for inline image emission, `provider_file_uploads` table, drivers prefer cached upload over re-inlining | ~1-2 weeks per driver, +1 week for the Files API caching infra | Phase 1 |
| **5 — Audio attachments** | Audio file uploads, gpt-4o-audio + Gemini multimodal driver wiring, audio attachment renderer with playback | ~1-2 weeks | Phase 1 |
| **6 — Cloud TTS plugin** | `cloud_tts` plugin, profile auto-speak setting, streaming playback | ~1 week | Independent of Phase 1 once the plugin system is stable |

Phase 0 can start immediately. Phase 1 is the long pole. After that, 2/3/5/6 are roughly parallel, and 4 is the deepest driver-specific work.

---

## Open threads (revisit when their phase lands)

- **Multi-tenant storage isolation.** If Reeve ever grows beyond a single self-hosted user, the per-user filesystem layout naturally extends; the signed-URL HMAC needs a key-rotation story; S3-side bucket policies need ACL alignment. Not a v1 concern but the interface boundary is what makes it tractable.
- **Attachment retention / GC.** When a message is deleted, its `message_attachments` rows cascade — but the underlying `files` row stays around (might be referenced by another message in the same context, by a compression_summary's `compressed_reference` row, or kept for an "uploaded files" sidebar). A periodic GC sweep against `files` with no `message_attachments` referrer (and older than N days) cleans up; sketch but defer until disk pressure is real.
- **Live audio sessions.** OpenAI Realtime / Gemini Live / OpenAI gpt-4o-realtime are full-duplex socket sessions, not request-response with attachments. They warrant their own design pass; the file/attachment infrastructure here is necessary but not sufficient for them.
- **Web client.** Mac + iOS are first-class implementation targets from Phase 1. A future web client would inherit the wire shape unchanged — only the composer affordances (drag-drop, paste, file picker) are platform-specific, and the preprocessing pipeline would re-implement against `Canvas` / `WebCodecs` rather than `ImageIO`.

---

## How to use this doc

Track phase progress here as bullets crossed off / moved into `todo.md`'s "shipped" section once each phase lands. Decisions that turn out wrong get amended inline (with a brief "earlier we decided X but Y forced a switch" note); strategic threads that emerge during implementation move into `architecture.md`'s Open threads.
