// Package speech provides text → audio synthesis for reading assistant
// turns aloud. See docs/design/speech.md for the full design.
//
// Mirrors the providers/ and embeddings/ package shape: a small
// Synthesizer interface plus a name → constructor registry.
// Implementations live in subpackages and register themselves from
// init(). The interface takes text segments on a channel rather than a
// single string so the same drivers serve both read-aloud (all
// segments known up front) and the phase-2 live tee (segments arriving
// as the model streams). HTTP drivers make one provider request per
// segment; WebSocket drivers forward text incrementally.
package speech

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
)

// SampleRate is the wire audio format's sample rate. All drivers emit
// PCM s16le mono at this rate so segments concatenate gaplessly with
// no codec anywhere in the stack.
const SampleRate = 24000

// BytesPerSecond of the wire format (s16le mono @ SampleRate).
const BytesPerSecond = SampleRate * 2

// NormalizerVersion identifies the markdown-to-speech normalization
// behavior. It participates in client replay-cache keys: bump it when
// normalization changes audibly, so cached audio synthesized under the
// old behavior misses instead of replaying stale narration.
const NormalizerVersion = 1

// Request carries the per-synthesis knobs common to all drivers.
// Driver-specific configuration (API key, base URL) is bound at Build
// time from the config blob, not per request.
type Request struct {
	// Voice is the provider's voice identifier. Free-form: a
	// self-hosted openai-compatible server's voices are its own.
	Voice string
	// Model is the provider's synthesis model, where applicable
	// (OpenAI "gpt-4o-mini-tts", xAI ignores it today). Free-form.
	Model string
	// Speed multiplies the provider's default speaking rate. 0 means
	// provider default.
	Speed float64
}

// Frame is one chunk of synthesized audio: PCM s16le mono @ SampleRate.
// A struct rather than a bare []byte so timestamp metadata can ride
// along later without changing every driver.
type Frame struct {
	PCM []byte
}

// Synthesizer streams audio for text segments arriving on in. The
// returned channel closes when in closes and all audio has been
// emitted, or when synthesis fails — errors surface via the returned
// error channel's single terminal value (nil on clean completion).
// Segment order is preserved: audio for segment N+1 never precedes
// audio for segment N.
type Synthesizer interface {
	Synthesize(ctx context.Context, req Request, in <-chan string) (<-chan Frame, <-chan error)
}

// Constructor builds a Synthesizer from an opaque JSON config blob —
// the user_tts_config row's config column, decrypted, verbatim.
type Constructor func(configBytes json.RawMessage) (Synthesizer, error)

// The registry is mutex-guarded (not init()-only) for the same reason
// the providers registry is: tests register fake kinds from parallel
// test goroutines while other tests call Build.
var (
	registryMu sync.RWMutex
	registry   = map[string]Constructor{}
)

// Register a synthesizer kind. Production callers do this from a
// package init(); panics on duplicate registration so a collision is
// loud at startup.
func Register(name string, c Constructor) {
	registryMu.Lock()
	defer registryMu.Unlock()
	if _, exists := registry[name]; exists {
		panic(fmt.Sprintf("speech: duplicate registration for %q", name))
	}
	registry[name] = c
}

// Build instantiates a registered kind from its config blob.
func Build(name string, configBytes json.RawMessage) (Synthesizer, error) {
	registryMu.RLock()
	c, ok := registry[name]
	registryMu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("speech: unknown kind %q", name)
	}
	return c(configBytes)
}

// Kinds returns the registered kind names.
func Kinds() []string {
	registryMu.RLock()
	defer registryMu.RUnlock()
	out := make([]string, 0, len(registry))
	for k := range registry {
		out = append(out, k)
	}
	return out
}
