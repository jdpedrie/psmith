// Package embeddings provides text → vector embedding for message search.
//
// Mirrors the providers/ package shape: a small Embedder interface plus a
// name → constructor registry. Implementations live in subpackages and
// register themselves from init(). Callers (the search service, the
// background backfill worker) pick an Embedder via Build(name, config)
// and pass it text to embed.
//
// The swap path: every embedding is persisted alongside its `Model()`
// identifier. When the user reconfigures the active embedder, old rows
// stay readable (Search filters `WHERE model = current.Model()`) and a
// background worker re-embeds them under the new model. No destructive
// schema change needed for a same-dim swap; a different-dim swap adds
// a new typed vector column and migrates over time.
package embeddings

import (
	"context"
	"encoding/json"
	"fmt"
)

// Embedder turns text into a fixed-dimensional vector. Implementations
// should batch efficiently — Search and backfill both call Embed with
// dozens to hundreds of inputs at a time.
type Embedder interface {
	// Embed returns one Dimensions()-long vector per input, in input
	// order. An empty input slice returns (nil, nil). Implementations
	// are responsible for batching against their backend's own batch
	// limits (Ollama caps at the model's context, OpenAI at 2048
	// inputs, etc.) — callers can hand over arbitrarily-sized slices.
	Embed(ctx context.Context, inputs []string) ([][]float32, error)

	// Model is the wire-stable identifier (e.g. "nomic-embed-text-v1.5")
	// persisted next to each row's vector so Search can scope to "rows
	// embedded under THIS model" and the backfill worker can spot rows
	// embedded under a previous model.
	Model() string

	// Dimensions is the fixed vector length the embedder produces. The
	// storage layer reads this to pick the right typed column;
	// mismatches between a returned vector and this value are a bug
	// in the implementation.
	Dimensions() int
}

// Constructor builds an Embedder from an opaque JSON config blob. Same
// shape as providers.Constructor — the per-user (or server) config
// row's `config` column is handed to the constructor verbatim.
type Constructor func(configBytes json.RawMessage) (Embedder, error)

var registry = map[string]Constructor{}

// Register an embedder type. Call from a package init(). Panics on
// duplicate registration so a typo at startup is loud, not silent.
func Register(name string, c Constructor) {
	if _, exists := registry[name]; exists {
		panic(fmt.Sprintf("embeddings: duplicate registration for %q", name))
	}
	registry[name] = c
}

// Build instantiates an embedder from a registered name + its config.
// Unknown names return a descriptive error; the management surface
// validates `name` with IsRegistered before persisting.
func Build(name string, configBytes json.RawMessage) (Embedder, error) {
	c, ok := registry[name]
	if !ok {
		return nil, fmt.Errorf("embeddings: unknown embedder %q", name)
	}
	return c(configBytes)
}

// IsRegistered reports whether a name is in the registry. Lets the
// settings UI / RPC reject "set embedder = foo" before it hits Build
// and the user sees a confusing runtime error.
func IsRegistered(name string) bool {
	_, ok := registry[name]
	return ok
}

// Names returns every registered embedder name. Order is undefined; the
// UI sorts for display.
func Names() []string {
	out := make([]string, 0, len(registry))
	for n := range registry {
		out = append(out, n)
	}
	return out
}
