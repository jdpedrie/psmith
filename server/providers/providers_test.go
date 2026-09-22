package providers

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"testing"
)

type fakeProvider struct{ name string }

func (f *fakeProvider) Type() string   { return f.name }
func (f *fakeProvider) Stateful() bool { return false }
func (f *fakeProvider) DiscoverModels(_ context.Context) ([]Model, error) {
	return nil, nil
}
func (f *fakeProvider) RenderThinkingToText(_ json.RawMessage) string { return "" }

func resetRegistry() {
	registry = map[string]Constructor{}
}

func TestRegisterAndBuild(t *testing.T) {
	resetRegistry()
	t.Cleanup(resetRegistry)

	Register("fake", func(_ Deps, _ json.RawMessage) (Provider, error) {
		return &fakeProvider{name: "fake"}, nil
	})

	p, err := Build("fake", Deps{}, nil)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if p.Type() != "fake" {
		t.Errorf("got Type=%q want fake", p.Type())
	}
}

func TestBuild_PassesConfigAndDeps(t *testing.T) {
	resetRegistry()
	t.Cleanup(resetRegistry)

	var gotCfg json.RawMessage
	var gotDeps Deps
	Register("with-config", func(deps Deps, cfg json.RawMessage) (Provider, error) {
		gotCfg = cfg
		gotDeps = deps
		return &fakeProvider{name: "with-config"}, nil
	})

	cfg := json.RawMessage(`{"x":1}`)
	deps := Deps{} // Catalog/Logger nil — fine for this assertion.
	if _, err := Build("with-config", deps, cfg); err != nil {
		t.Fatalf("Build: %v", err)
	}
	if string(gotCfg) != `{"x":1}` {
		t.Errorf("constructor saw cfg %q, want %q", gotCfg, cfg)
	}
	if gotDeps.Catalog != nil || gotDeps.Logger != nil {
		t.Errorf("expected zero deps, got %+v", gotDeps)
	}
}

func TestBuild_ConstructorError(t *testing.T) {
	resetRegistry()
	t.Cleanup(resetRegistry)

	wantErr := errors.New("ctor failed")
	Register("err", func(_ Deps, _ json.RawMessage) (Provider, error) { return nil, wantErr })

	_, err := Build("err", Deps{}, nil)
	if !errors.Is(err, wantErr) {
		t.Errorf("got %v want %v", err, wantErr)
	}
}

func TestBuild_UnknownType(t *testing.T) {
	resetRegistry()
	t.Cleanup(resetRegistry)

	_, err := Build("nope", Deps{}, nil)
	if err == nil {
		t.Fatal("expected error for unknown type")
	}
}

func TestRegister_DuplicatePanics(t *testing.T) {
	resetRegistry()
	t.Cleanup(resetRegistry)

	Register("dup", func(_ Deps, _ json.RawMessage) (Provider, error) { return nil, nil })

	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic on duplicate registration")
		}
	}()
	Register("dup", func(_ Deps, _ json.RawMessage) (Provider, error) { return nil, nil })
}

func TestTypes(t *testing.T) {
	resetRegistry()
	t.Cleanup(resetRegistry)

	Register("a", func(_ Deps, _ json.RawMessage) (Provider, error) { return nil, nil })
	Register("b", func(_ Deps, _ json.RawMessage) (Provider, error) { return nil, nil })

	got := Types()
	sort.Strings(got)
	want := []string{"a", "b"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestTypes_Empty(t *testing.T) {
	resetRegistry()
	t.Cleanup(resetRegistry)

	if got := Types(); len(got) != 0 {
		t.Errorf("expected empty, got %v", got)
	}
}

// The budget table is the only place a level becomes tokens; every driver
// that still speaks budgets reads it, so its shape is a contract.
func TestBudgetTokensForEffort(t *testing.T) {
	cases := map[ThinkingEffort]int{
		ThinkingEffortUnset:  0,
		ThinkingEffortOff:    0,
		ThinkingEffortLow:    2048,
		ThinkingEffortMedium: 8192,
		ThinkingEffortHigh:   16384,
		ThinkingEffortXHigh:  24576,
	}
	for effort, want := range cases {
		if got := BudgetTokensForEffort(effort); got != want {
			t.Errorf("BudgetTokensForEffort(%q)=%d want %d", effort, got, want)
		}
	}
	// Anthropic's floor is 1024 and Gemini 2.5 Flash's ceiling is 24576;
	// every level that thinks at all has to sit inside both.
	for _, effort := range []ThinkingEffort{ThinkingEffortLow, ThinkingEffortMedium, ThinkingEffortHigh, ThinkingEffortXHigh} {
		if b := BudgetTokensForEffort(effort); b < 1024 || b > 24576 {
			t.Errorf("%q budget %d is outside the range every budget API accepts", effort, b)
		}
	}
}

func TestThinkingEffort_On(t *testing.T) {
	if ThinkingEffortUnset.On() || ThinkingEffortOff.On() {
		t.Error("unset and off must not count as thinking")
	}
	for _, e := range []ThinkingEffort{ThinkingEffortLow, ThinkingEffortMedium, ThinkingEffortHigh, ThinkingEffortXHigh} {
		if !e.On() {
			t.Errorf("%q should count as thinking", e)
		}
	}
	var none CallSettings
	if none.ThinkingEffort() != ThinkingEffortUnset {
		t.Error("nil thinking block must read as unset")
	}
	set := CallSettings{Thinking: &ThinkingSettings{Effort: ThinkingEffortHigh}}
	if set.ThinkingEffort() != ThinkingEffortHigh {
		t.Error("ThinkingEffort() should surface the block's level")
	}
}
