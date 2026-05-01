package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/store"
)

// fakeLoader is an in-memory parentLoader keyed by profile ID.
type fakeLoader struct {
	rows  map[uuid.UUID]store.Profile
	calls int
}

func (f *fakeLoader) GetProfileByID(_ context.Context, id uuid.UUID) (store.Profile, error) {
	f.calls++
	p, ok := f.rows[id]
	if !ok {
		return store.Profile{}, errors.New("not found")
	}
	return p, nil
}

func newLoader(profiles ...store.Profile) *fakeLoader {
	m := make(map[uuid.UUID]store.Profile, len(profiles))
	for _, p := range profiles {
		m[p.ID] = p
	}
	return &fakeLoader{rows: m}
}

func strPtr(s string) *string  { return &s }
func boolPtr(b bool) *bool     { return &b }
func uuidPtr(u uuid.UUID) *uuid.UUID { return &u }

// makeProfile builds a minimal store.Profile for tests. nil parent means root.
func makeProfile(name string, parent *uuid.UUID) store.Profile {
	id := uuid.New()
	return store.Profile{
		ID:              id,
		UserID:          uuid.New(),
		ParentProfileID: parent,
		Name:            name,
	}
}

func TestResolve_NoParent(t *testing.T) {
	t.Parallel()
	p := makeProfile("solo", nil)
	p.SystemMessage = strPtr("hello")

	got, err := Resolve(context.Background(), newLoader(p), p)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.SystemMessage == nil || *got.SystemMessage != "hello" {
		t.Errorf("system_message lost: %+v", got.SystemMessage)
	}
}

func TestResolve_SingleParent_FieldMerged(t *testing.T) {
	t.Parallel()
	parent := makeProfile("parent", nil)
	parent.SystemMessage = strPtr("from-parent")
	parent.CompressionGuide = strPtr("parent-guide")

	child := makeProfile("child", &parent.ID)
	// child overrides system_message but inherits compression_guide
	child.SystemMessage = strPtr("from-child")

	loader := newLoader(parent, child)
	got, err := Resolve(context.Background(), loader, child)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.SystemMessage == nil || *got.SystemMessage != "from-child" {
		t.Errorf("child should win for system_message: %+v", got.SystemMessage)
	}
	if got.CompressionGuide == nil || *got.CompressionGuide != "parent-guide" {
		t.Errorf("compression_guide should come from parent: %+v", got.CompressionGuide)
	}
	if got.Name != "child" {
		t.Errorf("name should remain child's: %q", got.Name)
	}
}

func TestResolve_DeepChain(t *testing.T) {
	t.Parallel()

	// root has compression_guide, mid has default_user_message, leaf has nothing
	root := makeProfile("root", nil)
	root.CompressionGuide = strPtr("root-guide")

	mid := makeProfile("mid", &root.ID)
	mid.DefaultUserMessage = strPtr("mid-context")

	leaf := makeProfile("leaf", &mid.ID)

	loader := newLoader(root, mid, leaf)
	got, err := Resolve(context.Background(), loader, leaf)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.CompressionGuide == nil || *got.CompressionGuide != "root-guide" {
		t.Errorf("compression_guide should come from root: %+v", got.CompressionGuide)
	}
	if got.DefaultUserMessage == nil || *got.DefaultUserMessage != "mid-context" {
		t.Errorf("default_user_message should come from mid: %+v", got.DefaultUserMessage)
	}
	if got.SystemMessage != nil {
		t.Errorf("nothing set system_message; got %+v", got.SystemMessage)
	}
	if got.ID != leaf.ID {
		t.Errorf("identity must be leaf: %v vs %v", got.ID, leaf.ID)
	}
}

func TestResolve_AllFieldsFromParent(t *testing.T) {
	t.Parallel()

	mode := compressionModeReplace
	pid := uuid.New()
	parent := makeProfile("parent", nil)
	parent.SystemMessage = strPtr("p-sys")
	parent.DefaultUserMessage = strPtr("p-default-user")
	parent.CompressionGuide = strPtr("p-guide")
	parent.CompressionMode = &mode
	parent.CompressionProviderID = &pid
	parent.CompressionModelID = strPtr("p-model")
	parent.DefaultSettings = []byte(`{"default_model_id":"x"}`)

	child := makeProfile("child", &parent.ID)
	// All optional fields nil — should inherit everything.

	got, err := Resolve(context.Background(), newLoader(parent, child), child)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.SystemMessage == nil || *got.SystemMessage != "p-sys" {
		t.Errorf("system_message: %+v", got.SystemMessage)
	}
	if got.DefaultUserMessage == nil || *got.DefaultUserMessage != "p-default-user" {
		t.Errorf("default_user_message: %+v", got.DefaultUserMessage)
	}
	if got.CompressionGuide == nil || *got.CompressionGuide != "p-guide" {
		t.Errorf("compression_guide: %+v", got.CompressionGuide)
	}
	if got.CompressionMode == nil || *got.CompressionMode != compressionModeReplace {
		t.Errorf("compression_mode: %+v", got.CompressionMode)
	}
	if got.CompressionProviderID == nil || *got.CompressionProviderID != pid {
		t.Errorf("compression_provider_id: %+v", got.CompressionProviderID)
	}
	if got.CompressionModelID == nil || *got.CompressionModelID != "p-model" {
		t.Errorf("compression_model_id: %+v", got.CompressionModelID)
	}
	if string(got.DefaultSettings) != `{"default_model_id":"x"}` {
		t.Errorf("default_settings: %s", got.DefaultSettings)
	}
}

func TestResolve_TitleFieldsInheritedFromParent(t *testing.T) {
	t.Parallel()

	tid := uuid.New()
	parent := makeProfile("parent", nil)
	parent.TitleProviderID = &tid
	parent.TitleModelID = strPtr("title-model")
	parent.TitleGuide = strPtr("Custom title prompt")

	child := makeProfile("child", &parent.ID)
	// All title_* fields nil → inherit.

	got, err := Resolve(context.Background(), newLoader(parent, child), child)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.TitleProviderID == nil || *got.TitleProviderID != tid {
		t.Errorf("title_provider_id: %+v", got.TitleProviderID)
	}
	if got.TitleModelID == nil || *got.TitleModelID != "title-model" {
		t.Errorf("title_model_id: %+v", got.TitleModelID)
	}
	if got.TitleGuide == nil || *got.TitleGuide != "Custom title prompt" {
		t.Errorf("title_guide: %+v", got.TitleGuide)
	}
}

func TestResolve_TitleFieldsChildOverridesParent(t *testing.T) {
	t.Parallel()

	parentTID := uuid.New()
	childTID := uuid.New()
	parent := makeProfile("parent", nil)
	parent.TitleProviderID = &parentTID
	parent.TitleModelID = strPtr("parent-model")
	parent.TitleGuide = strPtr("parent guide")

	child := makeProfile("child", &parent.ID)
	child.TitleProviderID = &childTID
	child.TitleModelID = strPtr("child-model")
	// child leaves TitleGuide nil → inherits parent's

	got, _ := Resolve(context.Background(), newLoader(parent, child), child)
	if *got.TitleProviderID != childTID {
		t.Errorf("expected child's title_provider_id to win")
	}
	if *got.TitleModelID != "child-model" {
		t.Errorf("expected child's title_model_id to win; got %q", *got.TitleModelID)
	}
	if got.TitleGuide == nil || *got.TitleGuide != "parent guide" {
		t.Errorf("expected parent's title_guide to be inherited; got %+v", got.TitleGuide)
	}
}

// TestResolve_TitleProviderKindInheritedFromParent verifies the
// "apple_foundation" sentinel — like the other title fields — flows down
// the parent chain when the child leaves it nil.
func TestResolve_TitleProviderKindInheritedFromParent(t *testing.T) {
	t.Parallel()

	parent := makeProfile("parent", nil)
	parent.TitleProviderKind = strPtr(TitleProviderKindAppleFoundation)

	child := makeProfile("child", &parent.ID)
	// child leaves TitleProviderKind nil → inherits.

	got, err := Resolve(context.Background(), newLoader(parent, child), child)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.TitleProviderKind == nil || *got.TitleProviderKind != TitleProviderKindAppleFoundation {
		t.Errorf("expected child to inherit parent's title_provider_kind; got %+v", got.TitleProviderKind)
	}
}

// TestResolve_TitleProviderKindChildOverridesParent verifies the child's
// explicit kind wins over the parent's.
func TestResolve_TitleProviderKindChildOverridesParent(t *testing.T) {
	t.Parallel()

	parent := makeProfile("parent", nil)
	parent.TitleProviderKind = strPtr("some-other-kind")

	child := makeProfile("child", &parent.ID)
	child.TitleProviderKind = strPtr(TitleProviderKindAppleFoundation)

	got, _ := Resolve(context.Background(), newLoader(parent, child), child)
	if got.TitleProviderKind == nil || *got.TitleProviderKind != TitleProviderKindAppleFoundation {
		t.Errorf("expected child's title_provider_kind to win; got %+v", got.TitleProviderKind)
	}
}

func TestResolve_Cycle(t *testing.T) {
	t.Parallel()

	// Construct a -> b -> a cycle by manually wiring IDs.
	aID := uuid.New()
	bID := uuid.New()
	a := store.Profile{ID: aID, UserID: uuid.New(), Name: "a", ParentProfileID: &bID}
	b := store.Profile{ID: bID, UserID: uuid.New(), Name: "b", ParentProfileID: &aID}

	_, err := Resolve(context.Background(), newLoader(a, b), a)
	if !errors.Is(err, ErrCycle) {
		t.Errorf("expected ErrCycle, got %v", err)
	}
}

func TestResolve_TooDeep(t *testing.T) {
	t.Parallel()

	// Build a chain longer than MaxParentDepth.
	chainLen := MaxParentDepth + 5
	profiles := make([]store.Profile, chainLen)
	// Build leaf-first by allocating IDs forward, then linking each child to its parent.
	ids := make([]uuid.UUID, chainLen)
	for i := range ids {
		ids[i] = uuid.New()
	}
	// profiles[0] is the root; profiles[chainLen-1] is the leaf.
	for i := 0; i < chainLen; i++ {
		var parent *uuid.UUID
		if i > 0 {
			parent = &ids[i-1]
		}
		profiles[i] = store.Profile{ID: ids[i], UserID: uuid.New(), Name: "p", ParentProfileID: parent}
	}
	leaf := profiles[chainLen-1]

	_, err := Resolve(context.Background(), newLoader(profiles...), leaf)
	if !errors.Is(err, ErrTooDeep) {
		t.Errorf("expected ErrTooDeep, got %v", err)
	}
}

func TestResolve_FirstNonNullWins_OverThreeLevels(t *testing.T) {
	t.Parallel()
	// system_message set on grandparent and child (overriding); parent is silent.
	gp := makeProfile("gp", nil)
	gp.SystemMessage = strPtr("from-gp")

	mid := makeProfile("mid", &gp.ID)

	leaf := makeProfile("leaf", &mid.ID)
	leaf.SystemMessage = strPtr("from-leaf")

	got, err := Resolve(context.Background(), newLoader(gp, mid, leaf), leaf)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.SystemMessage == nil || *got.SystemMessage != "from-leaf" {
		t.Errorf("expected leaf's system_message to win: %+v", got.SystemMessage)
	}
}

// --- default_settings.call_settings parent-chain inheritance --------------

// withCallSettingsBlob writes a default_settings JSONB blob carrying just
// the call_settings sub-object. Other defaultsStorage fields stay unset.
func withCallSettingsBlob(t *testing.T, p store.Profile, cs *reevev1.CallSettings) store.Profile {
	t.Helper()
	raw, err := MarshalCallSettings(cs)
	if err != nil {
		t.Fatalf("MarshalCallSettings: %v", err)
	}
	wrapper := struct {
		CallSettings json.RawMessage `json:"call_settings"`
	}{CallSettings: raw}
	blob, err := json.Marshal(wrapper)
	if err != nil {
		t.Fatalf("marshal wrapper: %v", err)
	}
	p.DefaultSettings = blob
	return p
}

// callSettingsFromResolved decodes the call_settings sub-object out of a
// resolved profile's default_settings — same shape Resolve produces after
// re-encoding the merged result.
func callSettingsFromResolved(t *testing.T, p store.Profile) *reevev1.CallSettings {
	t.Helper()
	if len(p.DefaultSettings) == 0 {
		return nil
	}
	var s struct {
		CallSettings json.RawMessage `json:"call_settings,omitempty"`
	}
	if err := json.Unmarshal(p.DefaultSettings, &s); err != nil {
		t.Fatalf("decode resolved default_settings: %v", err)
	}
	if len(s.CallSettings) == 0 {
		return nil
	}
	cs, err := UnmarshalCallSettings(s.CallSettings)
	if err != nil {
		t.Fatalf("UnmarshalCallSettings: %v", err)
	}
	return cs
}

func TestResolve_CallSettings_ChildOverridesParentPerField(t *testing.T) {
	t.Parallel()

	// Parent sets temperature + top_p; child sets temperature only.
	// Resolved should combine: child's temperature, parent's top_p.
	parent := makeProfile("parent", nil)
	parent = withCallSettingsBlob(t, parent, &reevev1.CallSettings{
		Temperature: f64(0.2),
		TopP:        f64(0.85),
	})

	child := makeProfile("child", &parent.ID)
	child = withCallSettingsBlob(t, child, &reevev1.CallSettings{
		Temperature: f64(0.7),
	})

	got, err := Resolve(context.Background(), newLoader(parent, child), child)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	cs := callSettingsFromResolved(t, got)
	if cs == nil {
		t.Fatal("expected resolved call_settings, got nil")
	}
	if cs.GetTemperature() != 0.7 {
		t.Errorf("temperature: %v want 0.7 (child)", cs.GetTemperature())
	}
	if cs.GetTopP() != 0.85 {
		t.Errorf("top_p: %v want 0.85 (parent)", cs.GetTopP())
	}
}

func TestResolve_CallSettings_ChainAcrossThreeLevels(t *testing.T) {
	t.Parallel()

	// Grandparent: top_k. Mid: nothing. Leaf: temperature.
	// Resolved leaf should carry leaf's temperature + grandparent's top_k,
	// inherited through the silent middle layer.
	gp := makeProfile("gp", nil)
	gp = withCallSettingsBlob(t, gp, &reevev1.CallSettings{
		TopK: i32(40),
	})

	mid := makeProfile("mid", &gp.ID)
	// mid has no default_settings at all.

	leaf := makeProfile("leaf", &mid.ID)
	leaf = withCallSettingsBlob(t, leaf, &reevev1.CallSettings{
		Temperature: f64(0.9),
	})

	got, err := Resolve(context.Background(), newLoader(gp, mid, leaf), leaf)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	cs := callSettingsFromResolved(t, got)
	if cs == nil {
		t.Fatal("expected resolved call_settings, got nil")
	}
	if cs.GetTemperature() != 0.9 {
		t.Errorf("temperature: %v want 0.9 (leaf)", cs.GetTemperature())
	}
	if cs.GetTopK() != 40 {
		t.Errorf("top_k: %v want 40 (gp)", cs.GetTopK())
	}
}

func TestResolve_CallSettings_NestedThinkingMergesAcrossChain(t *testing.T) {
	t.Parallel()

	// Parent: thinking enabled with budget=2000. Child: thinking budget
	// override only (no enabled flag). Resolved: enabled=true (parent),
	// budget=8000 (child).
	parent := makeProfile("parent", nil)
	parent = withCallSettingsBlob(t, parent, &reevev1.CallSettings{
		Thinking: &reevev1.ThinkingSettings{Enabled: boolPtr(true), BudgetTokens: i32(2000)},
	})

	child := makeProfile("child", &parent.ID)
	child = withCallSettingsBlob(t, child, &reevev1.CallSettings{
		Thinking: &reevev1.ThinkingSettings{BudgetTokens: i32(8000)},
	})

	got, err := Resolve(context.Background(), newLoader(parent, child), child)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	cs := callSettingsFromResolved(t, got)
	if cs == nil || cs.GetThinking() == nil {
		t.Fatal("expected resolved thinking, got nil")
	}
	if !cs.GetThinking().GetEnabled() {
		t.Error("thinking.enabled: should inherit true from parent")
	}
	if cs.GetThinking().GetBudgetTokens() != 8000 {
		t.Errorf("thinking.budget_tokens: %v want 8000 (child)", cs.GetThinking().GetBudgetTokens())
	}
}
