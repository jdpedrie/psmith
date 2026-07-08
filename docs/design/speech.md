# Speech (text-to-speech)

**Status: draft for review.** Nothing here is built. Open questions are
marked inline and collected at the end.

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
| `openai` | server HTTP | $15/1M chars; simple; keys often already on file |

ElevenLabs and Cartesia follow the same shape later (premium voices,
lowest latency respectively).

**Credential reuse:** for kinds whose vendor is already a configured
chat provider (xAI, OpenAI), the config references the existing
`user_model_providers` row for its key instead of storing a second
copy — one key, encrypted once, used by both drivers. Standalone-key
entry exists for vendors that aren't chat providers (ElevenLabs).

**OPEN:** per-user only, or per-profile override? Profiles are
personas; a voice per persona (the title-model pattern:
`tts_voice`/`tts_provider` on the profile, falling back to the user
config) is more work but matches how everything else resolves.

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

**Audio format — OPEN:** PCM s16le 24kHz mono end-to-end is the draft
choice. It concatenates gaplessly across segment boundaries with zero
codecs anywhere in our stack; the cost is bandwidth (~48KB/s, ~21MB
per hour of listening). Opus at ~6KB/s is the alternative, but
streaming opus needs an ogg demuxer on the client and either an
encoder dependency server-side or per-provider passthrough with messy
segment joins. Recommendation: PCM for v1, revisit if cellular data
bills complain.

## Segmentation and normalization

One shared segmenter in `internal/speech`: split on sentence
terminators and paragraph breaks, minimum ~40 chars per segment,
force-flush on markdown block boundaries and at end of input.

A markdown-to-speech normalizer runs first: code fences reduce to
"code omitted" (**OPEN:** or skip silently), links speak their text,
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
`/tts` call (provider, characters synthesized, derived USD from the
config's price. **OPEN:** hardcode per-kind prices like the catalog
does, or a price field on the config?). `apple_local` costs nothing
and records nothing.

## Phasing

1. **v1 — read-aloud:** `internal/speech` package + segmenter +
   normalizer, `grok` + `openai` drivers, `user_tts_config` +
   SpeechService RPCs, `POST /tts` endpoint, iOS speaker action with
   both paths, `apple_local` default. Tests at every layer per
   CLAUDE.md.
2. **v2 — live tee:** `GET /tts?run_id`, client "speak this reply"
   toggle that starts audio while the turn streams.
3. **Later:** WS drivers (Cartesia, Grok WS, ElevenLabs) behind the
   same interface; per-profile voices; expressive-tag emission; STT /
   voice input (a separate design).

## Open questions

1. Config scope: per-user only, or per-profile voice override?
2. Wire format: PCM s16le 24kHz (draft) vs opus passthrough?
3. Code blocks: announce "code omitted" (draft) or skip silently?
4. Cost: hardcoded per-kind prices (draft) or user-editable?
5. v1 provider set: `apple_local` + `grok` + `openai` (draft) — add
   ElevenLabs now or later?
