package embeddings

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// fakeEmbedder is a deterministic stub used to exercise the registry
// without standing up a real backend.
type fakeEmbedder struct {
	model string
	dim   int
}

func (f *fakeEmbedder) Embed(_ context.Context, inputs []string) ([][]float32, error) {
	out := make([][]float32, len(inputs))
	for i, in := range inputs {
		v := make([]float32, f.dim)
		// Reproducible per-input pattern so callers can assert.
		v[0] = float32(len(in))
		out[i] = v
	}
	return out, nil
}

func (f *fakeEmbedder) Model() string   { return f.model }
func (f *fakeEmbedder) Dimensions() int { return f.dim }

// resetRegistry wipes the package-global so each test starts clean.
// Required because Register panics on duplicate names.
func resetRegistry(t *testing.T) {
	t.Helper()
	registry = map[string]Constructor{}
}

func TestRegisterAndBuild(t *testing.T) {
	resetRegistry(t)
	Register("fake", func(_ json.RawMessage) (Embedder, error) {
		return &fakeEmbedder{model: "fake-v1", dim: 4}, nil
	})

	e, err := Build("fake", nil)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if e.Model() != "fake-v1" {
		t.Errorf("Model() = %q", e.Model())
	}
	if e.Dimensions() != 4 {
		t.Errorf("Dimensions() = %d", e.Dimensions())
	}
}

func TestBuild_UnknownName(t *testing.T) {
	resetRegistry(t)
	_, err := Build("nope", nil)
	if err == nil || !strings.Contains(err.Error(), "unknown embedder") {
		t.Errorf("want unknown-embedder error, got %v", err)
	}
}

func TestRegister_DuplicatePanics(t *testing.T) {
	resetRegistry(t)
	ctor := func(_ json.RawMessage) (Embedder, error) {
		return &fakeEmbedder{}, nil
	}
	Register("dup", ctor)
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic on duplicate Register")
		}
	}()
	Register("dup", ctor)
}

func TestIsRegisteredAndNames(t *testing.T) {
	resetRegistry(t)
	Register("a", func(_ json.RawMessage) (Embedder, error) { return &fakeEmbedder{}, nil })
	Register("b", func(_ json.RawMessage) (Embedder, error) { return &fakeEmbedder{}, nil })

	if !IsRegistered("a") || !IsRegistered("b") {
		t.Error("registered names should report true")
	}
	if IsRegistered("c") {
		t.Error("unregistered name should report false")
	}
	got := Names()
	if len(got) != 2 {
		t.Fatalf("Names() = %v, want 2", got)
	}
}

func TestBuild_ConstructorErrorPropagates(t *testing.T) {
	resetRegistry(t)
	want := errors.New("config blew up")
	Register("bad", func(_ json.RawMessage) (Embedder, error) {
		return nil, want
	})
	if _, err := Build("bad", nil); !errors.Is(err, want) {
		t.Errorf("want %v, got %v", want, err)
	}
}
