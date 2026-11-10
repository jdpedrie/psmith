package modelproviders

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

// addManual registers a hand-added model with metadata worth losing:
// context window, pricing, capabilities and default settings.
func addManual(t *testing.T, svc *Service, ctx context.Context, providerID, modelID string) *psmithv1.UserModel {
	t.Helper()
	cw := int32(200_000)
	in, out := 2.5, 10.0
	temp := 0.3
	resp, err := svc.AddManualModel(ctx, connect.NewRequest(&psmithv1.AddManualModelRequest{
		UserModelProviderId: providerID,
		ModelId:             modelID,
		DisplayName:         "Private Fine-tune",
		ContextWindow:       &cw,
		Pricing:             &psmithv1.ModelPricing{InputPerMillionTokens: &in, OutputPerMillionTokens: &out},
		Capabilities:        &psmithv1.ModelCapabilities{Streaming: true, ToolUse: true},
		Modalities:          []string{"text"},
		DefaultSettings:     &psmithv1.CallSettings{Temperature: &temp},
	}))
	if err != nil {
		t.Fatalf("AddManualModel: %v", err)
	}
	return resp.Msg.GetUserModel()
}

func assertSameManualMetadata(t *testing.T, got, want *psmithv1.UserModel) {
	t.Helper()
	if got.GetDisplayName() != want.GetDisplayName() {
		t.Errorf("display_name: got %q want %q", got.GetDisplayName(), want.GetDisplayName())
	}
	if got.GetContextWindow() != want.GetContextWindow() {
		t.Errorf("context_window: got %d want %d", got.GetContextWindow(), want.GetContextWindow())
	}
	if got.GetPricing().GetInputPerMillionTokens() != want.GetPricing().GetInputPerMillionTokens() ||
		got.GetPricing().GetOutputPerMillionTokens() != want.GetPricing().GetOutputPerMillionTokens() {
		t.Errorf("pricing: got %+v want %+v", got.GetPricing(), want.GetPricing())
	}
	if !got.GetCapabilities().GetToolUse() || !got.GetCapabilities().GetStreaming() {
		t.Errorf("capabilities: got %+v", got.GetCapabilities())
	}
	if got.GetDefaultSettings().GetTemperature() != want.GetDefaultSettings().GetTemperature() {
		t.Errorf("default_settings: got %+v want %+v", got.GetDefaultSettings(), want.GetDefaultSettings())
	}
	if got.GetMetadataSource() != psmithv1.MetadataSource_METADATA_SOURCE_MANUAL {
		t.Errorf("metadata_source: got %v", got.GetMetadataSource())
	}
}

func TestDisableModels_ManualKeepsRowAndMetadata(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	ctx := ctxAs(user)
	added := addManual(t, svc, ctx, prov.ID.String(), "ft-1")

	if _, err := svc.DisableModels(ctx, connect.NewRequest(&psmithv1.DisableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"ft-1"},
	})); err != nil {
		t.Fatalf("DisableModels: %v", err)
	}

	row, err := q.GetUserModel(context.Background(), store.GetUserModelParams{UserModelProviderID: prov.ID, ModelID: "ft-1"})
	if err != nil {
		t.Fatalf("row should survive disable: %v", err)
	}
	if row.Enabled {
		t.Errorf("row still enabled after disable")
	}

	got, err := svc.GetUserModelProvider(ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: prov.ID.String()}))
	if err != nil {
		t.Fatalf("GetUserModelProvider: %v", err)
	}
	if n := len(got.Msg.GetEnabledModels()); n != 0 {
		t.Errorf("enabled_models: got %d want 0", n)
	}
	if n := len(got.Msg.GetDisabledModels()); n != 1 {
		t.Fatalf("disabled_models: got %d want 1", n)
	}
	assertSameManualMetadata(t, got.Msg.GetDisabledModels()[0], added)

	// A second AddManualModel with the same id still collides: the row is
	// there, just off.
	_, err = svc.AddManualModel(ctx, connect.NewRequest(&psmithv1.AddManualModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "ft-1",
		DisplayName:         "Again",
	}))
	assertCode(t, err, connect.CodeAlreadyExists)
}

func TestDisableModels_ManualExcludedFromPickers(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	ctx := ctxAs(user)
	addManual(t, svc, ctx, prov.ID.String(), "ft-off")
	addManual(t, svc, ctx, prov.ID.String(), "ft-on")

	if _, err := svc.DisableModels(ctx, connect.NewRequest(&psmithv1.DisableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"ft-off"},
	})); err != nil {
		t.Fatalf("DisableModels: %v", err)
	}

	all, err := svc.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{}))
	if err != nil {
		t.Fatalf("ListAllUserModels: %v", err)
	}
	if len(all.Msg.GetEntries()) != 1 || all.Msg.GetEntries()[0].GetModel().GetModelId() != "ft-on" {
		t.Errorf("ListAllUserModels: got %v, want only ft-on", all.Msg.GetEntries())
	}

	list, err := svc.ListUserModels(ctx, connect.NewRequest(&psmithv1.ListUserModelsRequest{UserModelProviderId: prov.ID.String()}))
	if err != nil {
		t.Fatalf("ListUserModels: %v", err)
	}
	if len(list.Msg.GetModels()) != 1 || list.Msg.GetModels()[0].GetModelId() != "ft-on" {
		t.Errorf("ListUserModels: got %v, want only ft-on", list.Msg.GetModels())
	}

	// The send paths resolve the model through GetEnabledUserModel.
	if _, err := q.GetEnabledUserModel(context.Background(), store.GetEnabledUserModelParams{
		UserModelProviderID: prov.ID, ModelID: "ft-off",
	}); !errors.Is(err, pgx.ErrNoRows) {
		t.Errorf("GetEnabledUserModel(ft-off): got err %v, want ErrNoRows", err)
	}
	if _, err := q.GetEnabledUserModel(context.Background(), store.GetEnabledUserModelParams{
		UserModelProviderID: prov.ID, ModelID: "ft-on",
	}); err != nil {
		t.Errorf("GetEnabledUserModel(ft-on): %v", err)
	}
}

func TestEnableModels_RestoresDisabledManual(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	// The provider's listing does not offer the hand-added model, which is
	// what made EnableModels refuse it before.
	typeName := registerFakeDriver(t, "manual-reenable", []providers.Model{{ID: "listed", DisplayName: "Listed"}}, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)
	ctx := ctxAs(user)
	added := addManual(t, svc, ctx, prov.ID.String(), "ft-1")

	if _, err := svc.DisableModels(ctx, connect.NewRequest(&psmithv1.DisableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"ft-1"},
	})); err != nil {
		t.Fatalf("DisableModels: %v", err)
	}
	resp, err := svc.EnableModels(ctx, connect.NewRequest(&psmithv1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"ft-1"},
	}))
	if err != nil {
		t.Fatalf("EnableModels: %v", err)
	}
	if len(resp.Msg.GetEnabled()) != 1 {
		t.Fatalf("enabled: got %d want 1", len(resp.Msg.GetEnabled()))
	}
	assertSameManualMetadata(t, resp.Msg.GetEnabled()[0], added)

	got, err := svc.GetUserModelProvider(ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: prov.ID.String()}))
	if err != nil {
		t.Fatalf("GetUserModelProvider: %v", err)
	}
	if len(got.Msg.GetDisabledModels()) != 0 || len(got.Msg.GetEnabledModels()) != 1 {
		t.Fatalf("after enable: %d enabled, %d disabled; want 1, 0", len(got.Msg.GetEnabledModels()), len(got.Msg.GetDisabledModels()))
	}
	assertSameManualMetadata(t, got.Msg.GetEnabledModels()[0], added)

	all, err := svc.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{}))
	if err != nil {
		t.Fatalf("ListAllUserModels: %v", err)
	}
	if len(all.Msg.GetEntries()) != 1 {
		t.Errorf("ListAllUserModels after enable: got %d entries want 1", len(all.Msg.GetEntries()))
	}
}

// A hand-added model that the listing does offer: discovery reports it as
// not enabled while it's off, and turning it on keeps the hand-typed
// metadata rather than re-snapshotting from the listing.
func TestDiscoverModels_DisabledManualNotFlaggedEnabled(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerFakeDriver(t, "manual-listed", []providers.Model{{ID: "ft-1", DisplayName: "Listed Name"}}, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)
	ctx := ctxAs(user)
	added := addManual(t, svc, ctx, prov.ID.String(), "ft-1")

	if _, err := svc.DisableModels(ctx, connect.NewRequest(&psmithv1.DisableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"ft-1"},
	})); err != nil {
		t.Fatalf("DisableModels: %v", err)
	}
	disc, err := svc.DiscoverModels(ctx, connect.NewRequest(&psmithv1.DiscoverModelsRequest{UserModelProviderId: prov.ID.String()}))
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(disc.Msg.GetModels()) != 1 || disc.Msg.GetModels()[0].GetAlreadyEnabled() {
		t.Errorf("discovery: got %v, want ft-1 not already_enabled", disc.Msg.GetModels())
	}

	resp, err := svc.EnableModels(ctx, connect.NewRequest(&psmithv1.EnableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"ft-1"},
	}))
	if err != nil {
		t.Fatalf("EnableModels: %v", err)
	}
	assertSameManualMetadata(t, resp.Msg.GetEnabled()[0], added)
}

func TestDisableModels_DeleteManualRemovesRow(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	prov := makeProvider(t, q, user.ID, "fake", "main", nil)
	ctx := ctxAs(user)
	addManual(t, svc, ctx, prov.ID.String(), "ft-1")

	if _, err := svc.DisableModels(ctx, connect.NewRequest(&psmithv1.DisableModelsRequest{
		UserModelProviderId: prov.ID.String(),
		ModelIds:            []string{"ft-1"},
		DeleteManual:        true,
	})); err != nil {
		t.Fatalf("DisableModels: %v", err)
	}
	if _, err := q.GetUserModel(context.Background(), store.GetUserModelParams{UserModelProviderID: prov.ID, ModelID: "ft-1"}); !errors.Is(err, pgx.ErrNoRows) {
		t.Errorf("row after delete_manual: got err %v, want ErrNoRows", err)
	}
}
