package modelproviders

import (
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/events"
)

// Provider and model mutations must publish ProviderChanged onto the
// account bus — that push is what makes a provider added on one client
// appear on the others without a screen re-entry.

func recvProviderEvent(t *testing.T, ch <-chan events.Event) events.Event {
	t.Helper()
	select {
	case ev := <-ch:
		return ev
	case <-time.After(2 * time.Second):
		t.Fatalf("expected an event, got none within 2s")
		return events.Event{}
	}
}

func assertProviderEvent(t *testing.T, ev events.Event, userID, providerID uuid.UUID, kind events.ProviderChangeKind) {
	t.Helper()
	if ev.Type != events.ProviderChanged {
		t.Fatalf("event type = %v, want ProviderChanged", ev.Type)
	}
	if ev.UserID != userID {
		t.Errorf("event user = %s, want %s", ev.UserID, userID)
	}
	if ev.Provider.ProviderID != providerID {
		t.Errorf("event provider = %s, want %s", ev.Provider.ProviderID, providerID)
	}
	if ev.Provider.Kind != kind {
		t.Errorf("event kind = %v, want %v", ev.Provider.Kind, kind)
	}
}

func TestProviderEvents_LifecycleEmits(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	bus := events.New(nil)
	svc = svc.WithBus(bus)
	user := mustUser(t, q, "alice", false)
	ch, cancel := bus.Subscribe(user.ID)
	defer cancel()
	typeName := registerFakeDriver(t, "events-lifecycle", nil, nil)

	// Create → CREATED.
	created, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{
		Type:   typeName,
		Label:  "main",
		Config: []byte(`{"api_key":"sk-x"}`),
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	providerID := uuid.MustParse(created.Msg.Provider.Id)
	assertProviderEvent(t, recvProviderEvent(t, ch), user.ID, providerID, events.ProviderChangeCreated)

	// Config update → UPDATED.
	if _, err := svc.UpdateUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.UpdateUserModelProviderRequest{
		Id:    created.Msg.Provider.Id,
		Label: ptr("renamed"),
	})); err != nil {
		t.Fatalf("UpdateUserModelProvider: %v", err)
	}
	assertProviderEvent(t, recvProviderEvent(t, ch), user.ID, providerID, events.ProviderChangeUpdated)

	// Model-level mutation → UPDATED reporting the OWNING provider.
	// AddManualModel is the lightest model write that doesn't need
	// driver discovery.
	added, err := svc.AddManualModel(ctxAs(user), connect.NewRequest(&psmithv1.AddManualModelRequest{
		UserModelProviderId: created.Msg.Provider.Id,
		ModelId:             "manual-model-1",
		DisplayName:         "Manual Model 1",
	}))
	if err != nil {
		t.Fatalf("AddManualModel: %v", err)
	}
	assertProviderEvent(t, recvProviderEvent(t, ch), user.ID, providerID, events.ProviderChangeUpdated)

	// Favorite toggle → UPDATED.
	if _, err := svc.ToggleUserModelFavorite(ctxAs(user), connect.NewRequest(&psmithv1.ToggleUserModelFavoriteRequest{
		UserModelProviderId: created.Msg.Provider.Id,
		ModelId:             added.Msg.UserModel.ModelId,
	})); err != nil {
		t.Fatalf("ToggleUserModelFavorite: %v", err)
	}
	assertProviderEvent(t, recvProviderEvent(t, ch), user.ID, providerID, events.ProviderChangeUpdated)

	// Disable → UPDATED.
	if _, err := svc.DisableModels(ctxAs(user), connect.NewRequest(&psmithv1.DisableModelsRequest{
		UserModelProviderId: created.Msg.Provider.Id,
		ModelIds:            []string{added.Msg.UserModel.ModelId},
	})); err != nil {
		t.Fatalf("DisableModels: %v", err)
	}
	assertProviderEvent(t, recvProviderEvent(t, ch), user.ID, providerID, events.ProviderChangeUpdated)

	// Delete → DELETED.
	if _, err := svc.DeleteUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.DeleteUserModelProviderRequest{
		Id: created.Msg.Provider.Id,
	})); err != nil {
		t.Fatalf("DeleteUserModelProvider: %v", err)
	}
	assertProviderEvent(t, recvProviderEvent(t, ch), user.ID, providerID, events.ProviderChangeDeleted)
}

// A service without a bus must not panic on any publish path — the
// optional-wiring contract every fixture and older test relies on.
func TestProviderEvents_NilBusIsSilent(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "events-nilbus", nil, nil)

	created, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{
		Type:  typeName,
		Label: "main",
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	if _, err := svc.DeleteUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.DeleteUserModelProviderRequest{
		Id: created.Msg.Provider.Id,
	})); err != nil {
		t.Fatalf("DeleteUserModelProvider: %v", err)
	}
}

// --- RefreshUserModelMetadata ---

func TestRefreshUserModelMetadata_RestoresCatalogSnapshot(t *testing.T) {
	t.Parallel()
	svc, q, cat, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	src := seedCatalogRich(t, cat, "anthropic", "rich-claude")
	prov := makeProvider(t, q, user.ID, "openai-compatible", "main",
		[]byte(`{"catalog_provider_id":"anthropic"}`))

	if _, err := svc.EnableModels(ctxAs(user), connect.NewRequest(&psmithv1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"rich-claude"},
	})); err != nil {
		t.Fatalf("EnableModels: %v", err)
	}
	// Hand-edit the snapshot AND set a per-model default-settings layer;
	// the refresh must revert the former and preserve the latter.
	temp := 0.3
	if _, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&psmithv1.UpdateUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "rich-claude",
		DisplayName:         ptr("Hand Edited"),
		ContextWindow:       ptr(int32(1234)),
		DefaultSettings:     &psmithv1.CallSettings{Temperature: &temp},
	})); err != nil {
		t.Fatalf("UpdateUserModel: %v", err)
	}
	if _, err := svc.ToggleUserModelFavorite(ctxAs(user), connect.NewRequest(&psmithv1.ToggleUserModelFavoriteRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "rich-claude",
		Favorite:            true,
	})); err != nil {
		t.Fatalf("ToggleUserModelFavorite: %v", err)
	}

	resp, err := svc.RefreshUserModelMetadata(ctxAs(user), connect.NewRequest(&psmithv1.RefreshUserModelMetadataRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "rich-claude",
	}))
	if err != nil {
		t.Fatalf("RefreshUserModelMetadata: %v", err)
	}
	if !resp.Msg.Refreshed {
		t.Fatalf("refreshed = false, want true")
	}
	got := resp.Msg.UserModel
	if got.DisplayName != src.DisplayName {
		t.Errorf("display_name = %q, want catalog %q", got.DisplayName, src.DisplayName)
	}
	if got.GetContextWindow() != int32(src.ContextWindow) {
		t.Errorf("context_window = %d, want catalog %d", got.GetContextWindow(), src.ContextWindow)
	}
	if got.DefaultSettings == nil || got.DefaultSettings.Temperature == nil || *got.DefaultSettings.Temperature != temp {
		t.Errorf("default_settings not preserved through refresh: %+v", got.DefaultSettings)
	}
	if !got.Favorite {
		t.Errorf("favorite not preserved through refresh")
	}
	if got.MetadataSource != psmithv1.MetadataSource_METADATA_SOURCE_CATALOG {
		t.Errorf("metadata_source = %v, want catalog", got.MetadataSource)
	}
}

func TestRefreshUserModelMetadata_NoCatalogEntry_LeavesRowUntouched(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "refresh-nocat", nil, nil)
	created, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{
		Type:  typeName,
		Label: "main",
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	if _, err := svc.AddManualModel(ctxAs(user), connect.NewRequest(&psmithv1.AddManualModelRequest{
		UserModelProviderId: created.Msg.Provider.Id,
		ModelId:             "my-finetune",
		DisplayName:         "My Finetune",
	})); err != nil {
		t.Fatalf("AddManualModel: %v", err)
	}

	resp, err := svc.RefreshUserModelMetadata(ctxAs(user), connect.NewRequest(&psmithv1.RefreshUserModelMetadataRequest{
		UserModelProviderId: created.Msg.Provider.Id,
		ModelId:             "my-finetune",
	}))
	if err != nil {
		t.Fatalf("RefreshUserModelMetadata: %v", err)
	}
	if resp.Msg.Refreshed {
		t.Fatalf("refreshed = true for a manual model with no catalog entry")
	}
	if resp.Msg.UserModel.DisplayName != "My Finetune" {
		t.Errorf("row mutated on a no-op refresh: %+v", resp.Msg.UserModel)
	}
	if resp.Msg.UserModel.MetadataSource != psmithv1.MetadataSource_METADATA_SOURCE_MANUAL {
		t.Errorf("metadata_source = %v, want manual", resp.Msg.UserModel.MetadataSource)
	}
}

// Tiered pricing round-trips through the manual-add + update surface:
// tiers persist as JSONB and come back on the proto pricing block;
// an update whose pricing is UNSET preserves them.
func TestPricingTiers_RoundTripAndPreserve(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "tiers-rt", nil, nil)
	created, err := svc.CreateUserModelProvider(ctxAs(user), connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{
		Type: typeName, Label: "main",
	}))
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}

	in := 3.0
	tierIn := 6.0
	added, err := svc.AddManualModel(ctxAs(user), connect.NewRequest(&psmithv1.AddManualModelRequest{
		UserModelProviderId: created.Msg.Provider.Id,
		ModelId:             "tiered",
		DisplayName:         "Tiered",
		Pricing: &psmithv1.ModelPricing{
			InputPerMillionTokens: &in,
			Tiers: []*psmithv1.PricingTier{
				{ThresholdTokens: 128_000, InputPerMillionTokens: &tierIn},
			},
		},
	}))
	if err != nil {
		t.Fatalf("AddManualModel: %v", err)
	}
	got := added.Msg.UserModel.GetPricing()
	if got == nil || len(got.Tiers) != 1 {
		t.Fatalf("tiers didn't round-trip: %+v", got)
	}
	if got.Tiers[0].ThresholdTokens != 128_000 || got.Tiers[0].GetInputPerMillionTokens() != 6.0 {
		t.Errorf("tier content drift: %+v", got.Tiers[0])
	}

	// Metadata-only update (pricing unset) must PRESERVE the tiers.
	updated, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&psmithv1.UpdateUserModelRequest{
		UserModelProviderId: created.Msg.Provider.Id,
		ModelId:             "tiered",
		DisplayName:         ptr("Tiered v2"),
	}))
	if err != nil {
		t.Fatalf("UpdateUserModel: %v", err)
	}
	if p := updated.Msg.UserModel.GetPricing(); p == nil || len(p.Tiers) != 1 {
		t.Errorf("tiers lost on metadata-only update: %+v", p)
	}

	// Pricing replace-block WITHOUT tiers clears them.
	cleared, err := svc.UpdateUserModel(ctxAs(user), connect.NewRequest(&psmithv1.UpdateUserModelRequest{
		UserModelProviderId: created.Msg.Provider.Id,
		ModelId:             "tiered",
		Pricing:             &psmithv1.ModelPricing{InputPerMillionTokens: &in},
	}))
	if err != nil {
		t.Fatalf("UpdateUserModel(clear tiers): %v", err)
	}
	if p := cleared.Msg.UserModel.GetPricing(); p != nil && len(p.Tiers) != 0 {
		t.Errorf("tiers survived a tier-less pricing replace: %+v", p)
	}
}
