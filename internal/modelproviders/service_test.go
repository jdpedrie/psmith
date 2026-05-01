package modelproviders

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// --- helpers ---

func ptr[T any](v T) *T { return &v }

func newTestService(t *testing.T) (*Service, *store.Queries, *modelmeta.LiveCatalog, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	return NewService(q, cat, nil), q, cat, pool
}

func mustUser(t *testing.T, q *store.Queries, username string, isAdmin bool) store.User {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	u, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID:           id,
		Username:     username,
		PasswordHash: "x",
		IsAdmin:      isAdmin,
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	return u
}

func ctxAs(u store.User) context.Context {
	return auth.ContextWithUser(context.Background(), auth.User{
		ID:          u.ID,
		Username:    u.Username,
		DisplayName: u.DisplayName,
		IsAdmin:     u.IsAdmin,
		CreatedAt:   u.CreatedAt,
		UpdatedAt:   u.UpdatedAt,
	})
}

func assertCode(t *testing.T, err error, want connect.Code) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error with code %v, got nil", want)
	}
	var ce *connect.Error
	if !errors.As(err, &ce) {
		t.Fatalf("expected *connect.Error, got %T (%v)", err, err)
	}
	if ce.Code() != want {
		t.Errorf("got code %v want %v (%v)", ce.Code(), want, err)
	}
}

// uniqueTypeName produces a registry-unique driver type for a single test.
// It includes the test name and a UUID to dodge providers.Register's
// duplicate-panic across parallel tests.
func uniqueTypeName(t *testing.T, prefix string) string {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	return fmt.Sprintf("%s-%s-%s", prefix,
		strings.ReplaceAll(strings.ReplaceAll(t.Name(), "/", "-"), " ", "-"),
		id.String())
}

// fakeDriver is a configurable Provider for tests.
type fakeDriver struct {
	typeName string
	stateful bool
	models   []providers.Model
	discErr  error
}

func (f *fakeDriver) Type() string                                          { return f.typeName }
func (f *fakeDriver) Stateful() bool                                        { return f.stateful }
func (f *fakeDriver) RenderThinkingToText(_ json.RawMessage) string         { return "" }
func (f *fakeDriver) DiscoverModels(_ context.Context) ([]providers.Model, error) {
	if f.discErr != nil {
		return nil, f.discErr
	}
	return f.models, nil
}

// registerFakeDriver registers a Provider type with the given models.
// Returns the chosen type name. No cleanup is possible (registry is
// process-global) so we just keep using a unique name per test.
func registerFakeDriver(t *testing.T, prefix string, models []providers.Model, discErr error) string {
	t.Helper()
	typeName := uniqueTypeName(t, prefix)
	providers.Register(typeName, func(_ providers.Deps, _ json.RawMessage) (providers.Provider, error) {
		return &fakeDriver{typeName: typeName, models: models, discErr: discErr}, nil
	})
	return typeName
}

// makeProvider creates a user_model_provider row directly.
func makeProvider(t *testing.T, q *store.Queries, userID uuid.UUID, typeName, label string, config []byte) store.UserModelProvider {
	t.Helper()
	if config == nil {
		config = []byte("{}")
	}
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	row, err := q.CreateUserModelProvider(context.Background(), store.CreateUserModelProviderParams{
		ID:     id,
		UserID: userID,
		Type:   typeName,
		Label:  label,
		Config: config,
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	return row
}

// seedCatalog injects a tiny fixture into the in-memory catalog.
func seedCatalog(t *testing.T, cat *modelmeta.LiveCatalog, providerID, providerName, apiBase, modelID, modelName string) {
	t.Helper()
	now := time.Now().UTC()
	snap := modelmeta.Snapshot{
		FetchedAt: now,
		Providers: []modelmeta.ProviderSnapshot{
			{
				Provider: modelmeta.Provider{
					ID:        providerID,
					Name:      providerName,
					APIBase:   apiBase,
					EnvKey:    strings.ToUpper(providerID) + "_API_KEY",
					DocURL:    "https://example.com/docs",
					FetchedAt: now,
				},
				RawJSON: []byte(`{}`),
				Models: []modelmeta.ModelSnapshot{
					{
						Model: modelmeta.Model{
							ProviderID:    providerID,
							ID:            modelID,
							DisplayName:   modelName,
							ContextWindow: 200_000,
							Modalities:    []string{"text"},
							Capabilities:  modelmeta.Capabilities{Streaming: true, Thinking: true},
							Pricing:       &modelmeta.Pricing{InputPerMillion: 3.0, OutputPerMillion: 15.0},
							FetchedAt:     now,
						},
						RawJSON: []byte(`{}`),
					},
				},
			},
		},
	}
	cat.MergeSnapshot(snap)
}

// --- ListProviderTypes ---

func TestListProviderTypes_IncludesRegistered(t *testing.T) {
	t.Parallel()
	svc, _, _, _ := newTestService(t)
	registered := registerFakeDriver(t, "lpt", nil, nil)

	resp, err := svc.ListProviderTypes(context.Background(), connect.NewRequest(&reevev1.ListProviderTypesRequest{}))
	if err != nil {
		t.Fatalf("ListProviderTypes: %v", err)
	}

	var found *reevev1.ProviderType
	for _, pt := range resp.Msg.Types {
		if pt.Name == registered {
			found = pt
			break
		}
	}
	if found == nil {
		t.Fatalf("registered driver %q missing from response", registered)
	}
	if found.DisplayName == "" {
		t.Error("display_name should be humanized, got empty")
	}
	if found.Stateful {
		t.Error("fake driver should report stateful=false")
	}
}

func TestListProviderTypes_StatefulHardcoded(t *testing.T) {
	t.Parallel()
	// Just make sure the helper map flags the known stateful types as such.
	if !knownStatefulTypes["claude-code-subprocess"] {
		t.Error("claude-code-subprocess should be stateful")
	}
	if !knownStatefulTypes["codex-subprocess"] {
		t.Error("codex-subprocess should be stateful")
	}
	if knownStatefulTypes["openai-compatible"] {
		t.Error("openai-compatible should not be stateful")
	}
}

// --- ListProviderTemplates ---

// TestListProviderTemplates_PresetRegistry verifies the picker emits one
// entry per built-in preset (native + openai-compatible) and that
// preset_id / logo_slug / api_base are populated correctly. Catalog
// metadata (env_key, doc_url) is layered on best-effort.
func TestListProviderTemplates_PresetRegistry(t *testing.T) {
	t.Parallel()
	svc, _, cat, _ := newTestService(t)
	// Catalog enrichment: seed the env_key + doc_url for openai so the
	// preset entry picks them up. Other presets are emitted with no
	// catalog enrichment to prove templates surface even without it.
	seedCatalog(t, cat, "openai", "OpenAI", "https://api.openai.com/v1", "gpt-foo", "GPT Foo")

	resp, err := svc.ListProviderTemplates(context.Background(), connect.NewRequest(&reevev1.ListProviderTemplatesRequest{}))
	if err != nil {
		t.Fatalf("ListProviderTemplates: %v", err)
	}

	got := map[string]*reevev1.ProviderTemplate{}
	for _, t := range resp.Msg.Templates {
		got[t.CatalogProviderId] = t
	}

	// Native drivers: present, no preset_id, logo_slug filled.
	if a := got["anthropic"]; a == nil || a.DriverType != "anthropic" {
		t.Errorf("anthropic mapping: %+v", a)
	} else {
		if a.PresetId != nil {
			t.Errorf("anthropic should have no preset_id (native driver), got %v", *a.PresetId)
		}
		if a.LogoSlug == nil || *a.LogoSlug != "anthropic" {
			t.Errorf("anthropic logo_slug=%v", a.LogoSlug)
		}
	}
	if g := got["google"]; g == nil || g.DriverType != "google" {
		t.Errorf("google mapping: %+v", g)
	} else if g.ApiBase == nil || *g.ApiBase != "https://generativelanguage.googleapis.com/v1beta" {
		t.Errorf("google api_base=%v", g.ApiBase)
	}

	// OpenAI-compat presets: every entry from openai.AllPresets() must be
	// present, with preset_id pointing back at itself.
	wantPresets := []string{"openai", "xai", "deepseek", "groq", "openrouter",
		"mistral", "together", "cerebras", "qwen", "ollama", "perplexity"}
	for _, id := range wantPresets {
		entry := got[id]
		if entry == nil {
			t.Errorf("preset %q missing from templates", id)
			continue
		}
		if entry.DriverType != "openai-compatible" {
			t.Errorf("preset %q driver_type=%q want openai-compatible", id, entry.DriverType)
		}
		if entry.PresetId == nil || *entry.PresetId != id {
			t.Errorf("preset %q preset_id=%v want %q", id, entry.PresetId, id)
		}
		if entry.ApiBase == nil || *entry.ApiBase == "" {
			t.Errorf("preset %q missing api_base", id)
		}
		if entry.LogoSlug == nil || *entry.LogoSlug == "" {
			t.Errorf("preset %q missing logo_slug", id)
		}
	}

	// Catalog enrichment: openai's env_key + doc_url filled from the seed.
	if oai := got["openai"]; oai == nil {
		t.Fatal("openai missing")
	} else {
		if oai.EnvKey == nil || *oai.EnvKey != "OPENAI_API_KEY" {
			t.Errorf("openai env_key=%v want OPENAI_API_KEY (catalog-enriched)", oai.EnvKey)
		}
	}
}

// --- CreateUserModelProvider ---

func TestCreateUserModelProvider_Success(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "create-success", nil, nil)

	resp, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:   typeName,
		Label:  "main",
		Config: []byte(`{"api_key":"sk-x"}`),
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	if resp.Msg.Provider.OwnerUserId != user.ID.String() {
		t.Errorf("owner_user_id mismatch: %s vs %s", resp.Msg.Provider.OwnerUserId, user.ID)
	}
	if resp.Msg.Provider.Type != typeName {
		t.Errorf("type mismatch")
	}
	if resp.Msg.Provider.Label != "main" {
		t.Errorf("label mismatch")
	}
}

func TestCreateUserModelProvider_DefaultsConfigToEmptyObject(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "create-default-cfg", nil, nil)

	resp, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:  typeName,
		Label: "main",
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	var defCfg map[string]any
	if err := json.Unmarshal(resp.Msg.Provider.Config, &defCfg); err != nil {
		t.Fatalf("default config not valid JSON: %v", err)
	}
	if len(defCfg) != 0 {
		t.Errorf("expected empty default config, got %q", resp.Msg.Provider.Config)
	}
}

func TestCreateUserModelProvider_RejectsInvalidConfig(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "create-bad-cfg", nil, nil)

	_, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:   typeName,
		Label:  "main",
		Config: []byte("not-json"),
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// New: validate the type-registry check.
func TestCreateUserModelProvider_RejectsUnknownType(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)

	_, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:  "nonexistent-driver-type",
		Label: "main",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestCreateUserModelProvider_RequiresType(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	_, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type: "", Label: "x",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestCreateUserModelProvider_RequiresLabel(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	_, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type: "x", Label: "",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- ListUserModelProviders ---

func TestListUserModelProviders_PerUser(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	makeProvider(t, q, alice.ID, "fake", "alice-1", nil)
	makeProvider(t, q, alice.ID, "fake", "alice-2", nil)
	makeProvider(t, q, bob.ID, "fake", "bob-1", nil)

	resp, err := svc.ListUserModelProviders(ctxAs(alice), connect.NewRequest(&reevev1.ListUserModelProvidersRequest{}))
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(resp.Msg.Providers) != 2 {
		t.Fatalf("got %d want 2", len(resp.Msg.Providers))
	}
	for _, p := range resp.Msg.Providers {
		if p.OwnerUserId != alice.ID.String() {
			t.Errorf("leaked another user's row: %v", p)
		}
	}
}

// --- GetUserModelProvider ---

func TestGetUserModelProvider_OwnerCanRead(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	resp, err := svc.GetUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if resp.Msg.Provider.Id != prov.ID.String() {
		t.Errorf("id mismatch")
	}
	if len(resp.Msg.EnabledModels) != 0 {
		t.Errorf("expected no enabled models, got %d", len(resp.Msg.EnabledModels))
	}
}

func TestGetUserModelProvider_IncludesEnabledModels(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "model-x",
		DisplayName:         "Model X",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}

	resp, err := svc.GetUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(resp.Msg.EnabledModels) != 1 || resp.Msg.EnabledModels[0].ModelId != "model-x" {
		t.Errorf("expected one enabled model 'model-x', got %+v", resp.Msg.EnabledModels)
	}
}

func TestGetUserModelProvider_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	prov := makeProvider(t, q, alice.ID, "fake", "main", nil)

	_, err := svc.GetUserModelProvider(ctxAs(bob), connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: prov.ID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestGetUserModelProvider_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	_, err := svc.GetUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestGetUserModelProvider_NotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	missing, _ := uuid.NewV7()
	_, err := svc.GetUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: missing.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- UpdateUserModelProvider ---

func TestUpdateUserModelProvider_LabelAndConfig(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "old", []byte(`{"a":1}`))

	newLabel := "new"
	newConfig := []byte(`{"a":2}`)
	resp, err := svc.UpdateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelProviderRequest{
		Id:     prov.ID.String(),
		Label:  &newLabel,
		Config: newConfig,
	}))
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if resp.Msg.Provider.Label != "new" {
		t.Errorf("label not updated, got %q", resp.Msg.Provider.Label)
	}
	var gotCfg map[string]any
	if err := json.Unmarshal(resp.Msg.Provider.Config, &gotCfg); err != nil {
		t.Fatalf("config not valid JSON: %v", err)
	}
	if v, _ := gotCfg["a"].(float64); v != 2 {
		t.Errorf("config not updated, got %q", resp.Msg.Provider.Config)
	}
}

func TestUpdateUserModelProvider_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	prov := makeProvider(t, q, alice.ID, "fake", "main", nil)

	newLabel := "x"
	_, err := svc.UpdateUserModelProvider(ctxAs(bob), connect.NewRequest(&reevev1.UpdateUserModelProviderRequest{
		Id:    prov.ID.String(),
		Label: &newLabel,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestUpdateUserModelProvider_InvalidConfig(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	_, err := svc.UpdateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelProviderRequest{
		Id:     prov.ID.String(),
		Config: []byte("not-json"),
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestUpdateUserModelProvider_EmptyLabelRejected(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	empty := ""
	_, err := svc.UpdateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelProviderRequest{
		Id:    prov.ID.String(),
		Label: &empty,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// TestUpdateUserModelProvider_DefaultSettings round-trips a CallSettings
// (temperature + thinking budget), then runs an unrelated update without the
// `default_settings` field set and verifies the previously-stored value
// survives — the unset signals "leave the column alone."
func TestUpdateUserModelProvider_DefaultSettings(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	// First write — set temperature + thinking.budget.
	temp := 0.5
	budget := int32(4096)
	thinkingOn := true
	want := &reevev1.CallSettings{
		Temperature: &temp,
		Thinking: &reevev1.ThinkingSettings{
			Enabled:      &thinkingOn,
			BudgetTokens: &budget,
		},
	}
	resp, err := svc.UpdateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelProviderRequest{
		Id:              prov.ID.String(),
		DefaultSettings: want,
	}))
	if err != nil {
		t.Fatalf("Update (with defaults): %v", err)
	}
	if got := resp.Msg.Provider.GetDefaultSettings(); got == nil ||
		got.GetTemperature() != temp ||
		got.GetThinking() == nil ||
		got.GetThinking().GetBudgetTokens() != budget ||
		!got.GetThinking().GetEnabled() {
		t.Errorf("first-write round-trip mismatch: %+v", got)
	}

	// Round-trip via Get — this exercises the convert.go decode path too.
	getResp, err := svc.GetUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got := getResp.Msg.Provider.GetDefaultSettings(); got == nil ||
		got.GetTemperature() != temp ||
		got.GetThinking().GetBudgetTokens() != budget {
		t.Errorf("Get round-trip mismatch: %+v", got)
	}

	// Second update — change something else (label) and leave default_settings
	// unset. The previously-stored value must NOT be cleared.
	newLabel := "renamed"
	if _, err := svc.UpdateUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelProviderRequest{
		Id:    prov.ID.String(),
		Label: &newLabel,
	})); err != nil {
		t.Fatalf("Update (label only): %v", err)
	}
	getResp2, err := svc.GetUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.GetUserModelProviderRequest{
		Id: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Get (after label-only update): %v", err)
	}
	if got := getResp2.Msg.Provider.GetDefaultSettings(); got == nil ||
		got.GetTemperature() != temp ||
		got.GetThinking().GetBudgetTokens() != budget {
		t.Errorf("default_settings wiped by unrelated update: %+v", got)
	}
}

// --- DeleteUserModelProvider ---

func TestDeleteUserModelProvider_Success(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	if _, err := svc.DeleteUserModelProvider(ctxAs(user), connect.NewRequest(&reevev1.DeleteUserModelProviderRequest{
		Id: prov.ID.String(),
	})); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	if _, err := q.GetUserModelProvider(context.Background(), prov.ID); err == nil {
		t.Error("provider row should be gone")
	}
}

func TestDeleteUserModelProvider_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	prov := makeProvider(t, q, alice.ID, "fake", "main", nil)

	_, err := svc.DeleteUserModelProvider(ctxAs(bob), connect.NewRequest(&reevev1.DeleteUserModelProviderRequest{
		Id: prov.ID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- DiscoverModels ---

func TestDiscoverModels_FlagsAlreadyEnabled(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	models := []providers.Model{
		{ID: "m1", DisplayName: "Model 1"},
		{ID: "m2", DisplayName: "Model 2"},
	}
	typeName := registerFakeDriver(t, "discover", models, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	// Pre-enable m1.
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "Model 1",
		MetadataSource:      string(modelmeta.SourceDriver),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed UpsertUserModel: %v", err)
	}

	resp, err := svc.DiscoverModels(ctxAs(user), connect.NewRequest(&reevev1.DiscoverModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(resp.Msg.Models) != 2 {
		t.Fatalf("got %d models want 2", len(resp.Msg.Models))
	}
	flags := map[string]bool{}
	for _, m := range resp.Msg.Models {
		flags[m.ModelId] = m.AlreadyEnabled
	}
	if !flags["m1"] {
		t.Error("m1 should be already_enabled")
	}
	if flags["m2"] {
		t.Error("m2 should not be already_enabled")
	}
}

func TestDiscoverModels_DriverError(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "discover-err", nil, errors.New("boom"))
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	_, err := svc.DiscoverModels(ctxAs(user), connect.NewRequest(&reevev1.DiscoverModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	assertCode(t, err, connect.CodeInternal)
}

func TestDiscoverModels_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	typeName := registerFakeDriver(t, "discover-other", nil, nil)
	prov := makeProvider(t, q, alice.ID, typeName, "main", nil)

	_, err := svc.DiscoverModels(ctxAs(bob), connect.NewRequest(&reevev1.DiscoverModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- EnableModels ---

func TestEnableModels_FromCatalog(t *testing.T) {
	t.Parallel()
	svc, q, cat, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	seedCatalog(t, cat, "anthropic", "Anthropic", "https://api.anthropic.com", "claude-foo", "Claude Foo")

	// Use the literal "openai-compatible" driver type so configCatalogProviderID
	// picks the catalog id from the config blob. The driver itself shouldn't
	// be invoked because the catalog has the model — we don't register one.
	prov := makeProvider(t, q, user.ID, "openai-compatible", "main",
		[]byte(`{"catalog_provider_id":"anthropic"}`))

	resp, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"claude-foo"},
	}))
	if err != nil {
		t.Fatalf("EnableModels: %v", err)
	}
	if len(resp.Msg.Enabled) != 1 {
		t.Fatalf("got %d enabled want 1", len(resp.Msg.Enabled))
	}
	got := resp.Msg.Enabled[0]
	if got.ModelId != "claude-foo" {
		t.Errorf("model_id mismatch: %q", got.ModelId)
	}
	if got.MetadataSource != reevev1.MetadataSource_METADATA_SOURCE_CATALOG {
		t.Errorf("expected catalog source, got %v", got.MetadataSource)
	}
	if got.DisplayName != "Claude Foo" {
		t.Errorf("display_name mismatch: %q", got.DisplayName)
	}
}

func TestEnableModels_FromDriverDiscovery(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	models := []providers.Model{
		{
			ID:              "drv-model",
			DisplayName:     "Drv Model",
			ContextWindow:   1024,
			MaxOutputTokens: 256,
			Modalities:      []string{"text"},
			Capabilities:    providers.ModelCapabilities{Streaming: true},
			Pricing:         &providers.Pricing{InputPerMillion: 1.0, OutputPerMillion: 2.0},
		},
	}
	typeName := registerFakeDriver(t, "enable-drv", models, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"drv-model"},
	}))
	if err != nil {
		t.Fatalf("EnableModels: %v", err)
	}
	if len(resp.Msg.Enabled) != 1 {
		t.Fatalf("got %d want 1", len(resp.Msg.Enabled))
	}
	got := resp.Msg.Enabled[0]
	if got.MetadataSource != reevev1.MetadataSource_METADATA_SOURCE_DRIVER {
		t.Errorf("expected driver source, got %v", got.MetadataSource)
	}
	if got.GetContextWindow() != 1024 {
		t.Errorf("context window mismatch: %d", got.GetContextWindow())
	}
}

func TestEnableModels_NotDiscoverable(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "enable-miss", []providers.Model{{ID: "other"}}, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	_, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"missing-model"},
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestEnableModels_Idempotent(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "enable-idem", []providers.Model{{ID: "m1", DisplayName: "M1"}}, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	// First call enables.
	if _, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"m1"},
	})); err != nil {
		t.Fatalf("first Enable: %v", err)
	}
	// Second call must succeed and produce a single row.
	if _, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"m1"},
	})); err != nil {
		t.Fatalf("second Enable: %v", err)
	}
	rows, err := q.ListUserModelsByProvider(context.Background(), prov.ID)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(rows) != 1 {
		t.Errorf("expected 1 row after idempotent enable, got %d", len(rows))
	}
}

func TestEnableModels_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	typeName := registerFakeDriver(t, "enable-other", []providers.Model{{ID: "m1"}}, nil)
	prov := makeProvider(t, q, alice.ID, typeName, "main", nil)

	_, err := svc.EnableModels(ctxAs(bob), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"m1"},
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- DisableModels ---

func TestDisableModels_RemovesRow(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "M1",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if _, err := svc.DisableModels(ctxAs(user), connect.NewRequest(&reevev1.DisableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"m1"},
	})); err != nil {
		t.Fatalf("DisableModels: %v", err)
	}
	rows, err := q.ListUserModelsByProvider(context.Background(), prov.ID)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected 0 rows, got %d", len(rows))
	}
}

func TestDisableModels_Idempotent(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	// Disable a model that was never enabled — should succeed.
	if _, err := svc.DisableModels(ctxAs(user), connect.NewRequest(&reevev1.DisableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"never-existed"},
	})); err != nil {
		t.Fatalf("DisableModels (idempotent): %v", err)
	}
}

func TestDisableModels_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	prov := makeProvider(t, q, alice.ID, "fake", "main", nil)

	_, err := svc.DisableModels(ctxAs(bob), connect.NewRequest(&reevev1.DisableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"x"},
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- ToggleUserModelFavorite ---

func TestToggleUserModelFavorite_SetsTrue(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "M1",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	resp, err := svc.ToggleUserModelFavorite(ctxAs(user), connect.NewRequest(&reevev1.ToggleUserModelFavoriteRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		Favorite:            true,
	}))
	if err != nil {
		t.Fatalf("ToggleUserModelFavorite: %v", err)
	}
	if !resp.Msg.Model.Favorite {
		t.Error("response model should be favorite=true")
	}
	row, err := q.GetUserModel(context.Background(), store.GetUserModelParams{
		UserModelProviderID: prov.ID, ModelID: "m1",
	})
	if err != nil {
		t.Fatalf("GetUserModel: %v", err)
	}
	if !row.Favorite {
		t.Error("DB row should be favorite=true")
	}
}

func TestToggleUserModelFavorite_SetsFalse(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "M1",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := q.SetUserModelFavorite(context.Background(), store.SetUserModelFavoriteParams{
		UserModelProviderID: prov.ID, ModelID: "m1", Favorite: true,
	}); err != nil {
		t.Fatalf("seed favorite: %v", err)
	}

	resp, err := svc.ToggleUserModelFavorite(ctxAs(user), connect.NewRequest(&reevev1.ToggleUserModelFavoriteRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		Favorite:            false,
	}))
	if err != nil {
		t.Fatalf("ToggleUserModelFavorite: %v", err)
	}
	if resp.Msg.Model.Favorite {
		t.Error("response model should be favorite=false")
	}
}

func TestToggleUserModelFavorite_PreservedAcrossUpsert(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	models := []providers.Model{{ID: "m1", DisplayName: "M1 Updated"}}
	typeName := registerFakeDriver(t, "favorite-upsert", models, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	// Enable, then favorite, then re-enable. Favorite must survive the upsert.
	if _, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"m1"},
	})); err != nil {
		t.Fatalf("enable: %v", err)
	}
	if _, err := svc.ToggleUserModelFavorite(ctxAs(user), connect.NewRequest(&reevev1.ToggleUserModelFavoriteRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		Favorite:            true,
	})); err != nil {
		t.Fatalf("favorite: %v", err)
	}
	if _, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"m1"},
	})); err != nil {
		t.Fatalf("re-enable: %v", err)
	}
	row, err := q.GetUserModel(context.Background(), store.GetUserModelParams{
		UserModelProviderID: prov.ID, ModelID: "m1",
	})
	if err != nil {
		t.Fatalf("GetUserModel: %v", err)
	}
	if !row.Favorite {
		t.Error("favorite should be preserved across upsert (re-enable)")
	}
}

func TestToggleUserModelFavorite_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	prov := makeProvider(t, q, alice.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "M1",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, err := svc.ToggleUserModelFavorite(ctxAs(bob), connect.NewRequest(&reevev1.ToggleUserModelFavoriteRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		Favorite:            true,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestToggleUserModelFavorite_ModelNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	_, err := svc.ToggleUserModelFavorite(ctxAs(user), connect.NewRequest(&reevev1.ToggleUserModelFavoriteRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "nonexistent",
		Favorite:            true,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestToggleUserModelFavorite_EmptyModelID(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	_, err := svc.ToggleUserModelFavorite(ctxAs(user), connect.NewRequest(&reevev1.ToggleUserModelFavoriteRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "",
		Favorite:            true,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- UpdateUserModel ---

func TestUpdateUserModel_HappyPath(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "M1",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	topP := 0.7
	want := &reevev1.CallSettings{TopP: &topP}
	resp, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		DefaultSettings:     want,
	}))
	if err != nil {
		t.Fatalf("UpdateUserModel: %v", err)
	}
	if got := resp.Msg.UserModel.GetDefaultSettings(); got == nil || got.GetTopP() != topP {
		t.Errorf("response default_settings mismatch: %+v", got)
	}

	// Confirm via ListUserModels — exercises the read/decode path too.
	listResp, err := svc.ListUserModels(ctxAs(user), connect.NewRequest(&reevev1.ListUserModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("ListUserModels: %v", err)
	}
	if len(listResp.Msg.Models) != 1 {
		t.Fatalf("got %d models want 1", len(listResp.Msg.Models))
	}
	if got := listResp.Msg.Models[0].GetDefaultSettings(); got == nil || got.GetTopP() != topP {
		t.Errorf("list default_settings mismatch: %+v", got)
	}
}

func TestUpdateUserModel_NotEnabled(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	topP := 0.7
	_, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "never-enabled",
		DefaultSettings:     &reevev1.CallSettings{TopP: &topP},
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestUpdateUserModel_CrossUser(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	prov := makeProvider(t, q, alice.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "M1",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	topP := 0.5
	_, err := svc.UpdateUserModel(ctxAs(bob), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		DefaultSettings:     &reevev1.CallSettings{TopP: &topP},
	}))
	// NotFound — don't leak existence to the wrong user.
	assertCode(t, err, connect.CodeNotFound)
}

func TestUpdateUserModel_EmptyModelID(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	_, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// TestUpdateUserModel_FullMetadata exercises the metadata-merge path that
// powers the model edit screen: every metadata field gets a new value and
// the response (plus a follow-up read) reflects them.
func TestUpdateUserModel_FullMetadata(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	cw0 := int32(8192)
	mo0 := int32(2048)
	in0 := 1.0
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID:   prov.ID,
		ModelID:               "m1",
		DisplayName:           "Original",
		ContextWindow:         &cw0,
		MaxOutputTokens:       &mo0,
		InputPricePerMillion:  &in0,
		Modalities:            []string{"text"},
		MetadataSource:        string(modelmeta.SourceManual),
		MetadataSnapshotAt:    time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	newDisplay := "Renamed"
	newCW := int32(128000)
	newMO := int32(16384)
	newKC := "2025-01-15"
	resp, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		DisplayName:         &newDisplay,
		ContextWindow:       &newCW,
		MaxOutputTokens:     &newMO,
		Pricing: &reevev1.ModelPricing{
			InputPerMillionTokens:  ptr(2.5),
			OutputPerMillionTokens: ptr(10.0),
		},
		UpdateModalities: true,
		Modalities:       []string{"text", "image"},
		Capabilities: &reevev1.ModelCapabilities{
			Streaming: true,
			Vision:    true,
		},
		KnowledgeCutoff: &newKC,
	}))
	if err != nil {
		t.Fatalf("UpdateUserModel: %v", err)
	}
	got := resp.Msg.UserModel
	if got.DisplayName != newDisplay {
		t.Errorf("display_name: got %q want %q", got.DisplayName, newDisplay)
	}
	if got.GetContextWindow() != newCW {
		t.Errorf("context_window: got %d want %d", got.GetContextWindow(), newCW)
	}
	if got.GetMaxOutputTokens() != newMO {
		t.Errorf("max_output_tokens: got %d want %d", got.GetMaxOutputTokens(), newMO)
	}
	if got.Pricing.GetInputPerMillionTokens() != 2.5 || got.Pricing.GetOutputPerMillionTokens() != 10 {
		t.Errorf("pricing not applied: %+v", got.Pricing)
	}
	if len(got.Modalities) != 2 || got.Modalities[0] != "text" || got.Modalities[1] != "image" {
		t.Errorf("modalities: got %v", got.Modalities)
	}
	if !got.Capabilities.GetStreaming() || !got.Capabilities.GetVision() {
		t.Errorf("capabilities not applied: %+v", got.Capabilities)
	}
	if got.GetKnowledgeCutoff() != newKC {
		t.Errorf("knowledge_cutoff: got %q want %q", got.GetKnowledgeCutoff(), newKC)
	}
}

// TestUpdateUserModel_SparseMerge sends only display_name; everything else
// must keep its existing value (the merge-then-upsert path must not zero
// out fields whose proto messages weren't sent).
func TestUpdateUserModel_SparseMerge(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	cw0 := int32(8192)
	in0 := 1.0
	capJSON, _ := json.Marshal(modelmeta.Capabilities{Streaming: true, Vision: true})
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID:  prov.ID,
		ModelID:              "m1",
		DisplayName:          "Original",
		ContextWindow:        &cw0,
		InputPricePerMillion: &in0,
		Modalities:           []string{"text", "image"},
		Capabilities:         capJSON,
		MetadataSource:       string(modelmeta.SourceManual),
		MetadataSnapshotAt:   time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	newDisplay := "Renamed"
	resp, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		DisplayName:         &newDisplay,
	}))
	if err != nil {
		t.Fatalf("UpdateUserModel: %v", err)
	}
	got := resp.Msg.UserModel
	if got.DisplayName != newDisplay {
		t.Errorf("display_name: got %q want %q", got.DisplayName, newDisplay)
	}
	if got.GetContextWindow() != cw0 {
		t.Errorf("context_window changed unexpectedly: got %d want %d", got.GetContextWindow(), cw0)
	}
	if got.Pricing.GetInputPerMillionTokens() != in0 {
		t.Errorf("pricing changed unexpectedly: %+v", got.Pricing)
	}
	if len(got.Modalities) != 2 {
		t.Errorf("modalities changed unexpectedly: %v", got.Modalities)
	}
	if !got.Capabilities.GetStreaming() || !got.Capabilities.GetVision() {
		t.Errorf("capabilities changed unexpectedly: %+v", got.Capabilities)
	}
}

// TestUpdateUserModel_ModalitiesFlagGate confirms the update_modalities
// flag really controls the column. Sending an empty array WITHOUT the
// flag must NOT clear the existing value.
func TestUpdateUserModel_ModalitiesFlagGate(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "M1",
		Modalities:          []string{"text", "image"},
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Flag false → existing modalities preserved.
	newDisplay := "Keep"
	resp, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		DisplayName:         &newDisplay,
		// UpdateModalities not set; Modalities ignored.
		Modalities: []string{},
	}))
	if err != nil {
		t.Fatalf("UpdateUserModel (preserve): %v", err)
	}
	if len(resp.Msg.UserModel.Modalities) != 2 {
		t.Errorf("modalities cleared without flag: %v", resp.Msg.UserModel.Modalities)
	}

	// Flag true with empty array → cleared.
	resp2, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		UpdateModalities:    true,
		Modalities:          []string{},
	}))
	if err != nil {
		t.Fatalf("UpdateUserModel (clear): %v", err)
	}
	if len(resp2.Msg.UserModel.Modalities) != 0 {
		t.Errorf("modalities not cleared with flag: %v", resp2.Msg.UserModel.Modalities)
	}
}

// TestUpdateUserModel_EmptyDisplayNameRejected protects against a UI
// bug clearing the user-visible label by mistake.
func TestUpdateUserModel_EmptyDisplayNameRejected(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "m1",
		DisplayName:         "M1",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	empty := "   "
	_, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&reevev1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		DisplayName:         &empty,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- ListUserModels ---

func TestListUserModels_PerInstance(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov1 := makeProvider(t, q, user.ID, "fake", "p1", nil)
	prov2 := makeProvider(t, q, user.ID, "fake", "p2", nil)
	for _, p := range []store.UserModelProvider{prov1, prov2} {
		if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
			UserModelProviderID: p.ID,
			ModelID:             "m",
			DisplayName:         "M",
			MetadataSource:      string(modelmeta.SourceManual),
			MetadataSnapshotAt:  time.Now().UTC(),
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	resp, err := svc.ListUserModels(ctxAs(user), connect.NewRequest(&reevev1.ListUserModelsRequest{
		UserModelProviderId: prov1.ID.String(),
	}))
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(resp.Msg.Models) != 1 {
		t.Errorf("expected 1 model on prov1 only, got %d", len(resp.Msg.Models))
	}
}

func TestListUserModels_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	prov := makeProvider(t, q, alice.ID, "fake", "main", nil)

	_, err := svc.ListUserModels(ctxAs(bob), connect.NewRequest(&reevev1.ListUserModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- ListAllUserModels ---

func TestListAllUserModels_AcrossProviders(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov1 := makeProvider(t, q, user.ID, "fake", "p1", nil)
	prov2 := makeProvider(t, q, user.ID, "fake", "p2", nil)
	for _, p := range []store.UserModelProvider{prov1, prov2} {
		if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
			UserModelProviderID: p.ID,
			ModelID:             "m",
			DisplayName:         "M",
			MetadataSource:      string(modelmeta.SourceManual),
			MetadataSnapshotAt:  time.Now().UTC(),
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	resp, err := svc.ListAllUserModels(ctxAs(user), connect.NewRequest(&reevev1.ListAllUserModelsRequest{}))
	if err != nil {
		t.Fatalf("ListAll: %v", err)
	}
	if len(resp.Msg.Entries) != 2 {
		t.Errorf("expected 2 entries, got %d", len(resp.Msg.Entries))
	}
	for _, e := range resp.Msg.Entries {
		if e.Provider == nil || e.Model == nil {
			t.Errorf("entry missing fields: %+v", e)
		}
	}
}

func TestListAllUserModels_PerUser(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	provA := makeProvider(t, q, alice.ID, "fake", "p1", nil)
	provB := makeProvider(t, q, bob.ID, "fake", "p1", nil)
	for _, p := range []store.UserModelProvider{provA, provB} {
		if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
			UserModelProviderID: p.ID,
			ModelID:             "m",
			DisplayName:         "M",
			MetadataSource:      string(modelmeta.SourceManual),
			MetadataSnapshotAt:  time.Now().UTC(),
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	resp, err := svc.ListAllUserModels(ctxAs(alice), connect.NewRequest(&reevev1.ListAllUserModelsRequest{}))
	if err != nil {
		t.Fatalf("ListAll: %v", err)
	}
	if len(resp.Msg.Entries) != 1 {
		t.Errorf("expected 1 entry for alice, got %d", len(resp.Msg.Entries))
	}
	if resp.Msg.Entries[0].Provider.OwnerUserId != alice.ID.String() {
		t.Error("leaked another user's row")
	}
}

// --- RefreshModelCatalog ---

func TestRefreshModelCatalog_Admin(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := &fakeCatalog{
		status: modelmeta.Status{ProvidersCount: 7, ModelsCount: 42},
	}
	svc := NewService(q, cat, nil)
	admin := mustUser(t, q, "admin", true)

	resp, err := svc.RefreshModelCatalog(ctxAs(admin), connect.NewRequest(&reevev1.RefreshModelCatalogRequest{}))
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	if !cat.refreshed {
		t.Error("Refresh should have been called")
	}
	if resp.Msg.ProvidersCount != 7 || resp.Msg.ModelsCount != 42 {
		t.Errorf("counts mismatch: %+v", resp.Msg)
	}
}

func TestRefreshModelCatalog_NonAdminDenied(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := &fakeCatalog{}
	svc := NewService(q, cat, nil)
	regular := mustUser(t, q, "alice", false)
	_, err := svc.RefreshModelCatalog(ctxAs(regular), connect.NewRequest(&reevev1.RefreshModelCatalogRequest{}))
	assertCode(t, err, connect.CodePermissionDenied)
	if cat.refreshed {
		t.Error("Refresh should not have been called for a non-admin")
	}
}

// --- GetCatalogStatus ---

func TestGetCatalogStatus_Authenticated(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	now := time.Now().UTC()
	cat := &fakeCatalog{
		status: modelmeta.Status{ProvidersCount: 2, ModelsCount: 5, LastRefreshAt: &now},
	}
	svc := NewService(q, cat, nil)
	user := mustUser(t, q, "alice", false)

	resp, err := svc.GetCatalogStatus(ctxAs(user), connect.NewRequest(&reevev1.GetCatalogStatusRequest{}))
	if err != nil {
		t.Fatalf("GetCatalogStatus: %v", err)
	}
	if resp.Msg.ProvidersCount != 2 || resp.Msg.ModelsCount != 5 {
		t.Errorf("counts mismatch: %+v", resp.Msg)
	}
	if resp.Msg.LastRefreshAt == nil {
		t.Error("expected last_refresh_at to be set")
	}
}

func TestGetCatalogStatus_RealCatalog(t *testing.T) {
	t.Parallel()
	svc, q, cat, _ := newTestService(t)
	seedCatalog(t, cat, "anthropic", "Anthropic", "https://api.anthropic.com", "claude-x", "Claude X")
	user := mustUser(t, q, "alice", false)

	resp, err := svc.GetCatalogStatus(ctxAs(user), connect.NewRequest(&reevev1.GetCatalogStatusRequest{}))
	if err != nil {
		t.Fatalf("GetCatalogStatus: %v", err)
	}
	if resp.Msg.ProvidersCount != 1 {
		t.Errorf("providers_count = %d", resp.Msg.ProvidersCount)
	}
	if resp.Msg.ModelsCount != 1 {
		t.Errorf("models_count = %d", resp.Msg.ModelsCount)
	}
}

// fakeCatalog implements modelmeta.Catalog for the Refresh/Status tests where
// we don't want to depend on real catalog data — just verify auth and wiring.
type fakeCatalog struct {
	status     modelmeta.Status
	refreshed  bool
	refreshErr error
}

func (f *fakeCatalog) LookupModel(_ context.Context, _, _ string) (*modelmeta.Model, error) {
	return nil, modelmeta.ErrNotFound
}
func (f *fakeCatalog) LookupProvider(_ context.Context, _ string) (*modelmeta.Provider, error) {
	return nil, modelmeta.ErrNotFound
}
func (f *fakeCatalog) ListProviders(_ context.Context) ([]modelmeta.Provider, error) {
	return nil, nil
}
func (f *fakeCatalog) ListModelsByProvider(_ context.Context, _ string) ([]modelmeta.Model, error) {
	return nil, nil
}
func (f *fakeCatalog) Refresh(_ context.Context) error {
	f.refreshed = true
	return f.refreshErr
}
func (f *fakeCatalog) Status(_ context.Context) (modelmeta.Status, error) {
	return f.status, nil
}

// --- pure helpers ---

func TestConfigCatalogProviderID(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name    string
		driver  string
		config  []byte
		want    string
	}{
		{"anthropic", "anthropic", []byte(`{"api_key":"x"}`), "anthropic"},
		{"openai-compatible-with-id", "openai-compatible", []byte(`{"catalog_provider_id":"groq"}`), "groq"},
		{"openai-compatible-without-id", "openai-compatible", []byte(`{}`), ""},
		{"openai-compatible-empty", "openai-compatible", nil, ""},
		{"openai-compatible-bad-json", "openai-compatible", []byte("not-json"), ""},
		{"unknown", "weird", []byte(`{}`), ""},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := configCatalogProviderID(tc.driver, tc.config)
			if got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
			}
		})
	}
}

func TestHumanizeName(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"anthropic":              "Anthropic",
		"openai-compatible":      "Openai Compatible",
		"claude-code-subprocess": "Claude Code Subprocess",
		"":                       "",
	}
	for in, want := range cases {
		if got := humanizeName(in); got != want {
			t.Errorf("humanizeName(%q)=%q want %q", in, got, want)
		}
	}
}

// --- Rich-metadata round-trip tests (exercise pricing, knowledge_cutoff,
// capabilities, modalities, default_settings end-to-end through both
// snapshot paths and the read conversion helpers). ---

func seedCatalogRich(t *testing.T, cat *modelmeta.LiveCatalog, providerID, modelID string) modelmeta.Model {
	t.Helper()
	now := time.Now().UTC()
	cutoff := time.Date(2024, 10, 1, 0, 0, 0, 0, time.UTC)
	model := modelmeta.Model{
		ProviderID:      providerID,
		ID:              modelID,
		DisplayName:     "Rich Model",
		ContextWindow:   200_000,
		MaxOutputTokens: 8192,
		Pricing: &modelmeta.Pricing{
			InputPerMillion:      3.5,
			OutputPerMillion:     11.0,
			CacheReadPerMillion:  0.35,
			CacheWritePerMillion: 4.4,
		},
		KnowledgeCutoff: &cutoff,
		Modalities:      []string{"text", "image"},
		Capabilities: modelmeta.Capabilities{
			Streaming: true, Thinking: true, ToolUse: true, Vision: true, PromptCaching: true,
		},
		FetchedAt: now,
	}
	snap := modelmeta.Snapshot{
		FetchedAt: now,
		Providers: []modelmeta.ProviderSnapshot{
			{
				Provider: modelmeta.Provider{
					ID: providerID, Name: "Rich Provider", APIBase: "https://rich.example",
					EnvKey: "RICH_KEY", FetchedAt: now,
				},
				RawJSON: []byte(`{}`),
				Models: []modelmeta.ModelSnapshot{
					{Model: model, RawJSON: []byte(`{}`)},
				},
			},
		},
	}
	cat.MergeSnapshot(snap)
	return model
}

func TestEnableModels_FromCatalog_RichMetadata_RoundTrip(t *testing.T) {
	t.Parallel()
	svc, q, cat, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	src := seedCatalogRich(t, cat, "anthropic", "rich-claude")

	prov := makeProvider(t, q, user.ID, "openai-compatible", "main",
		[]byte(`{"catalog_provider_id":"anthropic"}`))

	enableResp, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"rich-claude"},
	}))
	if err != nil {
		t.Fatalf("EnableModels: %v", err)
	}

	listResp, err := svc.ListUserModels(ctxAs(user), connect.NewRequest(&reevev1.ListUserModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("ListUserModels: %v", err)
	}
	if len(listResp.Msg.Models) != 1 {
		t.Fatalf("got %d models want 1", len(listResp.Msg.Models))
	}
	got := listResp.Msg.Models[0]

	// Compare against both the EnableModels return (which goes through the
	// same convert path) and the source catalog model.
	if got.ModelId != src.ID || got.DisplayName != src.DisplayName {
		t.Errorf("identity drift: %+v", got)
	}
	if got.GetContextWindow() != int32(src.ContextWindow) {
		t.Errorf("context_window: got %d want %d", got.GetContextWindow(), src.ContextWindow)
	}
	if got.GetMaxOutputTokens() != int32(src.MaxOutputTokens) {
		t.Errorf("max_output_tokens: got %d want %d", got.GetMaxOutputTokens(), src.MaxOutputTokens)
	}
	if got.Pricing == nil ||
		got.Pricing.GetInputPerMillionTokens() != src.Pricing.InputPerMillion ||
		got.Pricing.GetOutputPerMillionTokens() != src.Pricing.OutputPerMillion ||
		got.Pricing.GetCacheReadPerMillionTokens() != src.Pricing.CacheReadPerMillion ||
		got.Pricing.GetCacheWritePerMillionTokens() != src.Pricing.CacheWritePerMillion {
		t.Errorf("pricing round-trip: got %+v want input=%v out=%v cr=%v cw=%v",
			got.Pricing, src.Pricing.InputPerMillion, src.Pricing.OutputPerMillion,
			src.Pricing.CacheReadPerMillion, src.Pricing.CacheWritePerMillion)
	}
	if got.GetKnowledgeCutoff() != "2024-10-01" {
		t.Errorf("knowledge_cutoff: %q", got.GetKnowledgeCutoff())
	}
	if len(got.Modalities) != 2 || got.Modalities[0] != "text" || got.Modalities[1] != "image" {
		t.Errorf("modalities: %v", got.Modalities)
	}
	if got.Capabilities == nil ||
		!got.Capabilities.Streaming || !got.Capabilities.Thinking ||
		!got.Capabilities.ToolUse || !got.Capabilities.Vision || !got.Capabilities.PromptCaching {
		t.Errorf("capabilities not preserved: %+v", got.Capabilities)
	}
	if got.MetadataSource != reevev1.MetadataSource_METADATA_SOURCE_CATALOG {
		t.Errorf("source: %v", got.MetadataSource)
	}

	// Sanity: EnableModels return should match what ListUserModels returns.
	if e := enableResp.Msg.Enabled; len(e) != 1 || e[0].ModelId != got.ModelId {
		t.Errorf("EnableModels return drifted from ListUserModels")
	}
}

func TestEnableModels_FromDriver_RichMetadata_RoundTrip(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)

	temp := 0.7
	maxOut := 4096
	thinkingOn := true
	thinkingBudget := 2048
	rich := providers.Model{
		ID:              "driver-rich",
		DisplayName:     "Driver Rich",
		ContextWindow:   128_000,
		MaxOutputTokens: 4096,
		Pricing: &providers.Pricing{
			InputPerMillion:      1.5,
			OutputPerMillion:     6.0,
			CacheReadPerMillion:  0.15,
			CacheWritePerMillion: 1.875,
		},
		KnowledgeCutoff: "2025-01",
		Modalities:      []string{"text", "audio"},
		Capabilities: providers.ModelCapabilities{
			Streaming: true, Thinking: true, ToolUse: true,
		},
		DefaultSettings: providers.CallSettings{
			Temperature:     &temp,
			MaxOutputTokens: &maxOut,
			Thinking: &providers.ThinkingSettings{
				Enabled:      &thinkingOn,
				BudgetTokens: &thinkingBudget,
			},
		},
		MetadataSource: modelmeta.SourceDriver,
	}
	typeName := registerFakeDriver(t, "rich-driver", []providers.Model{rich}, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	if _, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&reevev1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"driver-rich"},
	})); err != nil {
		t.Fatalf("EnableModels: %v", err)
	}

	listResp, err := svc.ListUserModels(ctxAs(user), connect.NewRequest(&reevev1.ListUserModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("ListUserModels: %v", err)
	}
	if len(listResp.Msg.Models) != 1 {
		t.Fatalf("got %d models want 1", len(listResp.Msg.Models))
	}
	got := listResp.Msg.Models[0]
	if got.GetContextWindow() != 128_000 || got.GetMaxOutputTokens() != 4096 {
		t.Errorf("limits: ctx=%d out=%d", got.GetContextWindow(), got.GetMaxOutputTokens())
	}
	if got.Pricing == nil || got.Pricing.GetInputPerMillionTokens() != 1.5 {
		t.Errorf("pricing: %+v", got.Pricing)
	}
	if got.GetKnowledgeCutoff() != "2025-01-01" {
		t.Errorf("knowledge_cutoff: %q (dateFromString should normalize 2025-01 to 2025-01-01)",
			got.GetKnowledgeCutoff())
	}
	if got.DefaultSettings == nil ||
		got.DefaultSettings.GetTemperature() != temp ||
		got.DefaultSettings.GetMaxOutputTokens() != int32(maxOut) ||
		got.DefaultSettings.GetThinking() == nil ||
		!got.DefaultSettings.GetThinking().GetEnabled() ||
		got.DefaultSettings.GetThinking().GetBudgetTokens() != int32(thinkingBudget) {
		t.Errorf("default_settings round-trip: %+v", got.DefaultSettings)
	}
	if got.MetadataSource != reevev1.MetadataSource_METADATA_SOURCE_DRIVER {
		t.Errorf("source: %v", got.MetadataSource)
	}
}

func TestDiscoverModels_PassesThroughRichMetadata(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)

	rich := providers.Model{
		ID:              "rich-discovered",
		DisplayName:     "Rich Discovered",
		ContextWindow:   200_000,
		MaxOutputTokens: 8192,
		Pricing: &providers.Pricing{
			InputPerMillion:  3,
			OutputPerMillion: 15,
		},
		KnowledgeCutoff: "2024-08-15",
		Modalities:      []string{"text", "image"},
		Capabilities:    providers.ModelCapabilities{Streaming: true, Vision: true},
		MetadataSource:  modelmeta.SourceCatalog,
	}
	typeName := registerFakeDriver(t, "discover-rich", []providers.Model{rich}, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	resp, err := svc.DiscoverModels(ctxAs(user), connect.NewRequest(&reevev1.DiscoverModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(resp.Msg.Models) != 1 {
		t.Fatalf("got %d want 1", len(resp.Msg.Models))
	}
	d := resp.Msg.Models[0]
	if d.GetContextWindow() != 200_000 || d.GetMaxOutputTokens() != 8192 {
		t.Errorf("limits: %+v", d)
	}
	if d.Pricing == nil || d.Pricing.GetInputPerMillionTokens() != 3 || d.Pricing.GetOutputPerMillionTokens() != 15 {
		t.Errorf("pricing: %+v", d.Pricing)
	}
	if d.GetKnowledgeCutoff() != "2024-08-15" {
		t.Errorf("knowledge_cutoff: %q", d.GetKnowledgeCutoff())
	}
	if d.MetadataSource != reevev1.MetadataSource_METADATA_SOURCE_CATALOG {
		t.Errorf("source: %v", d.MetadataSource)
	}
}

func TestCapabilitiesFromJSON_Malformed(t *testing.T) {
	if got := capabilitiesFromJSON([]byte("not json")); got != nil {
		t.Errorf("expected nil on malformed JSON, got %+v", got)
	}
	if got := capabilitiesFromJSON(nil); got != nil {
		// nil bytes → unmarshal of empty → either error or zero struct; in our
		// caller we guard with len(b) > 0 so this branch shouldn't hit, but the
		// helper itself should be defensive.
		_ = got
	}
}

func TestCallSettingsFromJSON_Malformed(t *testing.T) {
	if got := callSettingsFromJSON([]byte("not json")); got != nil {
		t.Errorf("expected nil on malformed JSON, got %+v", got)
	}
}

// --- AddManualModel ---

func TestAddManualModel_HappyPath(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	cw := int32(128_000)
	maxOut := int32(8_192)
	inputPrice := 1.5
	outputPrice := 6.0
	cutoff := "2025-04-01"
	temp := 0.4

	resp, err := svc.AddManualModel(ctxAs(user), connect.NewRequest(&reevev1.AddManualModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "gpt-mystery",
		DisplayName:         "GPT Mystery",
		ContextWindow:       &cw,
		MaxOutputTokens:     &maxOut,
		Pricing: &reevev1.ModelPricing{
			InputPerMillionTokens:  &inputPrice,
			OutputPerMillionTokens: &outputPrice,
		},
		Modalities:      []string{"text", "image"},
		Capabilities:    &reevev1.ModelCapabilities{Streaming: true, Vision: true},
		KnowledgeCutoff: &cutoff,
		DefaultSettings: &reevev1.CallSettings{Temperature: &temp},
	}))
	if err != nil {
		t.Fatalf("AddManualModel: %v", err)
	}
	got := resp.Msg.GetUserModel()
	if got == nil {
		t.Fatal("nil user_model in response")
	}
	if got.GetModelId() != "gpt-mystery" {
		t.Errorf("model_id: %q", got.GetModelId())
	}
	if got.GetDisplayName() != "GPT Mystery" {
		t.Errorf("display_name: %q", got.GetDisplayName())
	}
	if got.GetContextWindow() != cw {
		t.Errorf("context_window: %d", got.GetContextWindow())
	}
	if got.GetMaxOutputTokens() != maxOut {
		t.Errorf("max_output_tokens: %d", got.GetMaxOutputTokens())
	}
	if p := got.GetPricing(); p == nil {
		t.Errorf("pricing nil")
	} else if p.GetInputPerMillionTokens() != inputPrice || p.GetOutputPerMillionTokens() != outputPrice {
		t.Errorf("pricing: %+v", p)
	}
	if cap := got.GetCapabilities(); cap == nil {
		t.Errorf("capabilities nil")
	} else if !cap.Streaming || !cap.Vision {
		t.Errorf("capabilities: %+v", cap)
	}
	if got.GetKnowledgeCutoff() != cutoff {
		t.Errorf("knowledge_cutoff: %q", got.GetKnowledgeCutoff())
	}
	if ds := got.GetDefaultSettings(); ds == nil || ds.GetTemperature() != temp {
		t.Errorf("default_settings: %+v", ds)
	}
	if got.GetMetadataSource() != reevev1.MetadataSource_METADATA_SOURCE_MANUAL {
		t.Errorf("metadata_source: %v", got.GetMetadataSource())
	}
	if got.GetEnabledAt() == nil || got.GetMetadataSnapshotAt() == nil {
		t.Errorf("missing timestamps")
	}

	// Round-trip: ListUserModels should return the same row.
	listResp, err := svc.ListUserModels(ctxAs(user), connect.NewRequest(&reevev1.ListUserModelsRequest{
		UserModelProviderId: prov.ID.String(),
	}))
	if err != nil {
		t.Fatalf("ListUserModels: %v", err)
	}
	if len(listResp.Msg.Models) != 1 {
		t.Fatalf("got %d models want 1", len(listResp.Msg.Models))
	}
	if listResp.Msg.Models[0].GetMetadataSource() != reevev1.MetadataSource_METADATA_SOURCE_MANUAL {
		t.Errorf("listed metadata_source: %v", listResp.Msg.Models[0].GetMetadataSource())
	}
}

func TestAddManualModel_DuplicateModelID(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "dup",
		DisplayName:         "Original",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, err := svc.AddManualModel(ctxAs(user), connect.NewRequest(&reevev1.AddManualModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "dup",
		DisplayName:         "Replacement",
	}))
	assertCode(t, err, connect.CodeAlreadyExists)
}

func TestAddManualModel_EmptyModelID(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	_, err := svc.AddManualModel(ctxAs(user), connect.NewRequest(&reevev1.AddManualModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "",
		DisplayName:         "Nameless",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestAddManualModel_EmptyDisplayName(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)

	_, err := svc.AddManualModel(ctxAs(user), connect.NewRequest(&reevev1.AddManualModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		DisplayName:         "",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestAddManualModel_CrossUser(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	prov := makeProvider(t, q, alice.ID, "fake", "main", nil)

	_, err := svc.AddManualModel(ctxAs(bob), connect.NewRequest(&reevev1.AddManualModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "m1",
		DisplayName:         "M1",
	}))
	// NotFound — don't leak existence of alice's provider to bob.
	assertCode(t, err, connect.CodeNotFound)
}
