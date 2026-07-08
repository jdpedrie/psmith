# Speech (text-to-speech)

**Status: v1 scope agreed (2026-07-08).** Nothing here is built yet;
this is the contract the implementation follows.

Psmith speaks assistant turns aloud: on demand for a finished message
(read-aloud), and eventually live as a turn streams. Synthesis is
multi-provider behind one driver interface, with an on-device default
so the feature works before any cloud voice is configured. Audio is
ephemeral — it is never persisted and never enters the durable stream
log.

## The paradigm

Sentence-chunked incremental synthesis, the pattern every serious
voice stack (LiveKit Agents, Pipecat, Vapi) converged on: segment text
at sentence/clause boundaries, dispatch each completed segment to the
provider immediately, play the audio segments back-to-back from a
queue. One adapter shape absorbs both kinds of provider API:

1. **HTTP request → chunked audio** (OpenAI `/v1/audio/speech`, xAI
   `POST /v1/tts`, ElevenLabs `/stream`). Needs a complete segment per
   request. First audio ~200–500ms after send. Universal; the v1
   target.
2. **WebSocket bidirectional** (xAI TTS WS, ElevenLabs `stream-input`,
   Cartesia). Feed raw deltas, audio returns before the sentence
   completes. Same interface, lower latency; a later drop-in.

Latency budget with shape 1: first LLM token ~0.5s → first sentence
~1.5s → first audio ~2s. Shape 2 cuts that to under a second. Shape 1
is 90% of the perceived win.

Speech-native realtime models (OpenAI Realtime, Gemini Live) are a
non-goal: they replace the text pipeline rather than voicing it, and
would bypass history, compaction, and plugins entirely.

## Where it runs

The server owns every provider credential (the core Psmith invariant),
so cloud synthesis happens server-side. But audio does not ride the
stream supervisor: `stream_chunks` is a durable replay log and audio
has no replay value — even opus would bloat it. Instead, a dedicated
non-RPC streaming endpoint (the `/files/{id}` pattern):

- **`POST /tts`** with `{message_id}` — read-aloud. The server loads
  the message text, normalizes it for speech, pipes segments through
  the configured driver with its stored key, and streams audio back in
  one HTTP response. Bearer or cookie auth, same as the other non-RPC
  endpoints.
- **`GET /tts?run_id=...`** (phase 2) — speak-as-it-streams. The
  server subscribes to the live run internally (Subscribe already
  replays-then-tails), segments text as it lands, and streams audio.
  The client can lock the screen mid-turn and audio keeps coming,
  because the server owns the pipeline — the same resilience story as
  text streams.

The exception is the on-device path: `apple_local` is a client-side
sentinel kind (the `apple_foundation` titling precedent). The client
feeds text to `AVSpeechSynthesizer` directly; no server round trip, no
key, no cost. It is the default, so speech works out of the box.

## Configuration

A per-user speech config in the embedder/Langfuse mold
(`user_tts_config`: kind, voice, model, speed, encrypted config blob),
managed by a small `SpeechService` (get/set/test/delete RPCs with
dedicated request/response messages).

Provider kinds at v1:

| kind | transport | notes |
|---|---|---|
| `apple_local` | on-device | default; free, private, instant |
| `grok` | server HTTP | $4.20/1M chars; 26 voices; speech tags; WS upgrade path |
| `openai-compatible` | server HTTP | OpenAI itself ($15/1M chars) or any self-hosted server speaking the same API |

`openai-compatible` mirrors the chat-driver naming deliberately: the
self-hosted TTS ecosystem (Kokoro via kokoro-fastapi, openedai-speech
fronting Piper and XTTS, LocalAI, speaches) converged on OpenAI's
`/v1/audio/speech` shape the same way chat servers converged on
chat-completions. The config carries a base URL (default
api.openai.com) and an optional key (a LAN Kokoro needs none), and
voice/model are free-form strings — never validated against OpenAI's
voice list, because a self-hosted server's voices are its own.
Self-hosted synthesis is therefore a v1 capability, not a follow-up.

ElevenLabs and Cartesia follow the same driver shape later (premium
voices, lowest latency respectively).

**Credential reuse:** for kinds whose vendor is already a configured
chat provider (xAI, OpenAI), the config references the existing
`user_model_providers` row for its key instead of storing a second
copy — one key, encrypted once, used by both drivers. Standalone-key
entry exists for vendors that aren't chat providers (ElevenLabs).

Scope is per-user in v1. The designed-for follow-up is the standard
resolution chain: conversation override > profile override > user
default — a voice per persona, and a voice per conversation on top
(the title-model pattern, one resolution function). Further out:
multiple voices within one conversation (interactive fiction —
character-tagged dialogue mapped to voices), which is plugin-shaped
and waits for the tag/component machinery to drive it.

## The driver interface

`internal/speech`, mirroring `internal/embeddings`:

```go
type Synthesizer interface {
    // Synthesize streams audio for text segments arriving on in.
    // HTTP drivers make one provider request per segment; WS drivers
    // forward incrementally. Frames are PCM s16le 24kHz mono.
    Synthesize(ctx context.Context, req Request, in <-chan string) (<-chan Frame, error)
}
```

`speech.Register` / `speech.Build` copy the providers-registry pattern
(mutex-guarded). Drivers are tested against `httptest` servers with
body-level assertions, the anthropic-driver style.

Audio format: PCM s16le 24kHz mono end-to-end (decided). It
concatenates gaplessly across segment boundaries with zero codecs
anywhere in our stack; the cost is bandwidth (~48KB/s, ~21MB per hour
of listening), which we accept. Revisit opus only if that ever bites.

## Segmentation and normalization

One shared segmenter in `internal/speech`: split on sentence
terminators and paragraph breaks, minimum ~40 chars per segment,
force-flush on markdown block boundaries and at end of input.

A markdown-to-speech normalizer runs first: code fences reduce to
"code omitted" (decided: announce, don't skip — the narration stays
honest about what it isn't reading), links speak their text,
emphasis/heading markers strip, tables reduce to a short notice.
Thinking blocks and tool-call bodies are never spoken.

Providers with expressive tags (Grok's `[laugh]`, `<whisper>`) get
plain text in v1; tag emission could become a per-profile knob later.

## Client behavior (iOS first)

- A speaker action on assistant message bubbles (context menu + a
  small affordance on the newest message). Tap → play; tap again →
  stop. One playback at a time, owned by a `SpeechPlaybackModel` in
  PsmithKit.
- Cloud path: stream `POST /tts` into `AVAudioEngine` +
  `AVAudioPlayerNode`, scheduling PCM buffers as they arrive.
  `AVAudioSession` category `.playback` so audio continues when the
  screen locks.
- `apple_local` path: `AVSpeechSynthesizer` fed the normalized text
  directly; it manages its own queue.
- Mac and web follow: the web client gets the cloud path nearly free
  (cookie-authenticated endpoint + MediaSource on an `<audio>`
  element).

## Cost

Synthesis spend lands in the existing ledger: a `cost_events` row per
`/tts` call (provider, characters synthesized, USD derived from a hardcoded
per-kind price table — the constraints-table pattern; revisit if a
vendor reprices). `apple_local` costs nothing and records nothing, and
neither does an `openai-compatible` config pointed at a custom base
URL — self-hosted synthesis is free and the ledger shouldn't invent
OpenAI prices for it.

## Caching and replay

Synthesized audio is cached on the client, not the server. After one
playback the client already holds the full PCM; keeping it in the
existing PsmithKit cache (a capped LRU alongside CacheKind.profiles et
al., ~50MB budget) makes replay instant and free with no new server
machinery. The key is (message id, content hash, provider kind, voice,
normalizer version) — the content hash guarantees an edited message
never replays stale audio, and a voice change naturally misses. Cache
misses (app restart eviction, another device) just re-synthesize:
fractions of a cent and ~2s. A server-side audio cache is deliberately
rejected for v1 — TTL sweeping, invalidation, and a new on-disk
artifact class buy nothing over re-synthesis at these prices.
`apple_local` bypasses the cache entirely (synthesis is instant).

## Phasing

1. **v1 — read-aloud:** `internal/speech` package + segmenter +
   normalizer, `grok` + `openai` drivers, `user_tts_config` +
   SpeechService RPCs, `POST /tts` endpoint, iOS speaker action with
   both paths, `apple_local` default. Tests at every layer per
   CLAUDE.md.
2. **v2 — live tee:** `GET /tts?run_id`, client "speak this reply"
   toggle that starts audio while the turn streams.
3. **Later:** WS drivers (Cartesia, Grok WS, ElevenLabs) behind the
   same interface; the voice resolution chain (conversation > profile
   > user); multi-voice conversations (interactive fiction via tagged
   dialogue); expressive-tag emission; STT / voice input (a separate
   design).

## Decisions log

Settled 2026-07-08: per-user config in v1 with the conversation >
profile > user resolution chain as the designed-for follow-up; PCM
s16le 24kHz on the wire; code fences announced as "code omitted";
hardcoded per-kind pricing; v1 providers `apple_local` + `grok` +
`openai-compatible` (which covers self-hosted servers — Kokoro, Piper,
XTTS — via a custom base URL) with ElevenLabs later; client-side
replay cache only.
