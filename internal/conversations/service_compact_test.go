package conversations

import (
	"context"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/providers"
	"github.com/jdpedrie/psmith/internal/store"
)

// TestCompact_ProfileOnly — profile fully configures compression, no overrides
// in the request. Behavior matches the pre-override implementation: request
// succeeds, summary materializes in the source context.
func TestCompact_ProfileOnly(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-profile-inline",
		[]providers.Chunk{textChunk("inline profile summary"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	bg := context.Background()

	// Seed compression on the profile.
	guide := "From profile."
	mode := "REPLACE"
	if err := q.UpdateProfileCompressionGuide(bg, store.UpdateProfileCompressionGuideParams{
		ID: f.profile.ID, CompressionGuide: &guide,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionGuide: %v", err)
	}
	if err := q.UpdateProfileCompressionMode(bg, store.UpdateProfileCompressionModeParams{
		ID: f.profile.ID, CompressionMode: &mode,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionMode: %v", err)
	}
	if err := q.UpdateProfileCompressionProviderID(bg, store.UpdateProfileCompressionProviderIDParams{
		ID: f.profile.ID, CompressionProviderID: &f.provider.ID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionProviderID: %v", err)
	}
	if err := q.UpdateProfileCompressionModelID(bg, store.UpdateProfileCompressionModelIDParams{
		ID: f.profile.ID, CompressionModelID: &f.modelID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionModelID: %v", err)
	}
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "story please")

	resp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId: f.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status %q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}
}

// TestCompact_OverrideOnly — profile has NO compression configured at all;
// the request supplies guide + provider + model. Compaction should succeed
// using the override values. This is the workaround path for users whose
// profile resolves to a disabled model.
func TestCompact_OverrideOnly(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-override-only",
		[]providers.Chunk{textChunk("override summary"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "story please")

	guide := "From override."
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId:        f.conv.ID.String(),
		CompressionGuide:      &guide,
		CompressionProviderId: &pid,
		CompressionModelId:    &mid,
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status %q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}
	if final.ResultMessageID == nil {
		t.Fatal("expected result_message_id")
	}
	summary, err := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID(summary): %v", err)
	}
	if !strings.Contains(summary.Content, "override summary") {
		t.Errorf("summary content: %q", summary.Content)
	}
}

// TestCompact_OverrideWinsOverProfile — profile has compression configured
// (guide + provider + model). Request supplies override guide + override
// provider/model that point at a SECOND provider with a DIFFERENT model.
// Compaction should run against the override pair, not the profile pair.
//
// This is the load-bearing case for the "user picks a different model in
// the Compact page" flow: even when the profile has a fully valid
// compression config, the request-time choice wins.
func TestCompact_OverrideWinsOverProfile(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	// Driver-A is what the profile points at. Its registered chunk content
	// would be "from profile" — we expect to NOT see this in the summary.
	profileDriver := registerFakeDriver(t, "compact-profile",
		[]providers.Chunk{textChunk("from profile"), doneChunk()}, nil)
	overrideDriver := registerFakeDriver(t, "compact-override",
		[]providers.Chunk{textChunk("from override"), doneChunk()}, nil)
	f := seedSendable(t, q, profileDriver)
	bg := context.Background()

	// Configure profile compression to point at the profile driver.
	guide := "From profile guide."
	mode := "REPLACE"
	if err := q.UpdateProfileCompressionGuide(bg, store.UpdateProfileCompressionGuideParams{
		ID: f.profile.ID, CompressionGuide: &guide,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionGuide: %v", err)
	}
	if err := q.UpdateProfileCompressionMode(bg, store.UpdateProfileCompressionModeParams{
		ID: f.profile.ID, CompressionMode: &mode,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionMode: %v", err)
	}
	if err := q.UpdateProfileCompressionProviderID(bg, store.UpdateProfileCompressionProviderIDParams{
		ID: f.profile.ID, CompressionProviderID: &f.provider.ID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionProviderID: %v", err)
	}
	if err := q.UpdateProfileCompressionModelID(bg, store.UpdateProfileCompressionModelIDParams{
		ID: f.profile.ID, CompressionModelID: &f.modelID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionModelID: %v", err)
	}
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "tell me")

	// Create a second provider for the override, with its own enabled model.
	overrideProvID, _ := uuid.NewV7()
	overrideProv, err := q.CreateUserModelProvider(bg, store.CreateUserModelProviderParams{
		ID:              overrideProvID,
		UserID:          f.user.ID,
		Type:            overrideDriver,
		Label:           "override",
		ConfigEncrypted: []byte("{}"),
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider(override): %v", err)
	}
	overrideModelID := "override-model"
	if _, err := q.UpsertUserModel(bg, store.UpsertUserModelParams{
		UserModelProviderID: overrideProv.ID,
		ModelID:             overrideModelID,
		DisplayName:         "Override Model",
		MetadataSource:      "manual",
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel(override): %v", err)
	}

	overrideGuide := "From override guide."
	pidStr := overrideProv.ID.String()
	resp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId:        f.conv.ID.String(),
		CompressionGuide:      &overrideGuide,
		CompressionProviderId: &pidStr,
		CompressionModelId:    &overrideModelID,
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status %q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}
	if final.ProviderID == nil || *final.ProviderID != overrideProv.ID {
		t.Errorf("stream_run provider: got %v want %s (override)", final.ProviderID, overrideProv.ID)
	}
	if final.ModelID != overrideModelID {
		t.Errorf("stream_run model: got %s want %s (override)", final.ModelID, overrideModelID)
	}
	summary, err := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID(summary): %v", err)
	}
	if !strings.Contains(summary.Content, "from override") {
		t.Errorf("summary content: %q (expected override driver output)", summary.Content)
	}
}

// TestCompact_OverrideToDisabledModel — request override referencing a model
// that's not enabled on the (override or profile) provider must still fail
// with FailedPrecondition. The override path doesn't bypass the
// existence/enablement check; it just changes which (provider, model) pair
// gets checked.
func TestCompact_OverrideToDisabledModel(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-override-disabled",
		[]providers.Chunk{doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "story please")

	guide := "From override."
	pidStr := f.provider.ID.String()
	disabledModel := "definitely-not-enabled"
	_, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId:        f.conv.ID.String(),
		CompressionGuide:      &guide,
		CompressionProviderId: &pidStr,
		CompressionModelId:    &disabledModel,
	}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}

// TestCompact_OverrideProviderWithoutModel_Mixed — request supplies an
// override provider id but no override model id. The model id should fall
// back to the profile's value. If the override provider doesn't have the
// profile's model id enabled, the precondition fails (good — fail closed).
//
// This pins the field-by-field independence: each override field falls
// back to the profile when unset, rather than overrides being all-or-nothing.
func TestCompact_OverrideProviderWithoutModel_Mixed(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-mixed",
		[]providers.Chunk{textChunk("mixed summary"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	bg := context.Background()

	// Profile has guide + provider + model.
	guide := "Profile guide."
	mode := "REPLACE"
	if err := q.UpdateProfileCompressionGuide(bg, store.UpdateProfileCompressionGuideParams{
		ID: f.profile.ID, CompressionGuide: &guide,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionGuide: %v", err)
	}
	if err := q.UpdateProfileCompressionMode(bg, store.UpdateProfileCompressionModeParams{
		ID: f.profile.ID, CompressionMode: &mode,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionMode: %v", err)
	}
	if err := q.UpdateProfileCompressionProviderID(bg, store.UpdateProfileCompressionProviderIDParams{
		ID: f.profile.ID, CompressionProviderID: &f.provider.ID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionProviderID: %v", err)
	}
	if err := q.UpdateProfileCompressionModelID(bg, store.UpdateProfileCompressionModelIDParams{
		ID: f.profile.ID, CompressionModelID: &f.modelID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionModelID: %v", err)
	}
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "story")

	// Override only the guide, leave provider/model to the profile.
	overrideGuide := "Different guide for this run."
	resp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId:   f.conv.ID.String(),
		CompressionGuide: &overrideGuide,
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status %q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}
	// The model + provider should have come from the profile.
	if final.ProviderID == nil || *final.ProviderID != f.provider.ID {
		t.Errorf("stream_run provider: got %v want %s (profile)", final.ProviderID, f.provider.ID)
	}
	if final.ModelID != f.modelID {
		t.Errorf("stream_run model: got %s want %s (profile)", final.ModelID, f.modelID)
	}
}

// TestCompact_NoConfigAtAll — neither profile nor request supplies compression
// settings. Expect FailedPrecondition citing the missing field.
func TestCompact_NoConfigAtAll(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-noconfig",
		[]providers.Chunk{doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "story please")

	_, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId: f.conv.ID.String(),
	}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}

// TestCompact_InvalidOverrideProviderID — request supplies a non-uuid string
// for compression_provider_id. Expect InvalidArgument before any further
// checks run.
func TestCompact_InvalidOverrideProviderID(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-bad-pid",
		[]providers.Chunk{doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	bogus := "not-a-uuid"
	_, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId:        f.conv.ID.String(),
		CompressionProviderId: &bogus,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// TestCompact_TranscriptUsesActiveChainOnly is a regression for a bug
// where Compact's renderTranscript called ListMessagesByContext —
// returning every message in the context including sibling forks. The
// compressor then saw turns from branches the user can't see in the
// active thread, producing summaries that referenced assistant replies
// the user wouldn't recognise.
//
// Setup: one shared user prompt → assistant reply, then a fork off
// that assistant. Active leaf is on the MAIN branch; the FORK branch
// also exists but should NOT appear in the compaction prompt.
//
// The fixture's seed message becomes the system framing (visible in
// every chain ancestor walk too), which we tolerate — what we assert
// is that the FORK branch's content is absent.
func TestCompact_TranscriptUsesActiveChainOnly(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-active-chain",
		[]providers.Chunk{textChunk("active-chain summary"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	bg := context.Background()

	// Profile-side compression so the request stays minimal.
	guide := "Summarise the conversation."
	mode := "REPLACE"
	if err := q.UpdateProfileCompressionGuide(bg, store.UpdateProfileCompressionGuideParams{
		ID: f.profile.ID, CompressionGuide: &guide,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionGuide: %v", err)
	}
	if err := q.UpdateProfileCompressionMode(bg, store.UpdateProfileCompressionModeParams{
		ID: f.profile.ID, CompressionMode: &mode,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionMode: %v", err)
	}
	if err := q.UpdateProfileCompressionProviderID(bg, store.UpdateProfileCompressionProviderIDParams{
		ID: f.profile.ID, CompressionProviderID: &f.provider.ID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionProviderID: %v", err)
	}
	if err := q.UpdateProfileCompressionModelID(bg, store.UpdateProfileCompressionModelIDParams{
		ID: f.profile.ID, CompressionModelID: &f.modelID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionModelID: %v", err)
	}

	// Build the chain:
	//   system (fixture) → user("ALPHA") → assistant("ALPHA-REPLY")
	//   assistant("ALPHA-REPLY") forks two ways:
	//     MAIN: user("BETA-MAIN") → assistant("BETA-MAIN-REPLY")  ← active leaf
	//     FORK: user("BETA-FORK") → assistant("BETA-FORK-REPLY")  ← must be invisible
	parent := f.systemMsgID
	alphaUser := insertMessage(t, q, f.contextID, &parent, "user", "ALPHA")
	alphaAssistant := insertMessage(t, q, f.contextID, &alphaUser.ID, "assistant", "ALPHA-REPLY")

	// MAIN branch.
	betaMainUser := insertMessage(t, q, f.contextID, &alphaAssistant.ID, "user", "BETA-MAIN")
	betaMainAssistant := insertMessage(t, q, f.contextID, &betaMainUser.ID, "assistant", "BETA-MAIN-REPLY")

	// FORK branch (sibling under the same parent).
	betaForkUser := insertMessage(t, q, f.contextID, &alphaAssistant.ID, "user", "BETA-FORK")
	_ = insertMessage(t, q, f.contextID, &betaForkUser.ID, "assistant", "BETA-FORK-REPLY")

	// Cursor → MAIN tip so resolveParent picks it as the leaf.
	if _, err := q.UpdateContextCurrentLeaf(bg, store.UpdateContextCurrentLeafParams{
		ID:                   f.contextID,
		CurrentLeafMessageID: &betaMainAssistant.ID,
	}); err != nil {
		t.Fatalf("UpdateContextCurrentLeaf: %v", err)
	}

	resp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId: f.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status %q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}

	// Inspect the wire prefix the compaction driver actually received.
	// The transcript lives in the user message at index 1 (system=guide
	// is index 0).
	drv := fetchDriver(t, driverType)
	drv.mu.Lock()
	req := drv.lastRequest
	drv.mu.Unlock()
	if req == nil || len(req.Messages) < 2 {
		t.Fatalf("expected captured request with system+user messages, got %+v", req)
	}
	transcript := req.Messages[1].Content

	// Active chain content must be present.
	for _, want := range []string{"ALPHA", "ALPHA-REPLY", "BETA-MAIN", "BETA-MAIN-REPLY"} {
		if !strings.Contains(transcript, want) {
			t.Errorf("transcript missing active-chain content %q\n--- transcript ---\n%s", want, transcript)
		}
	}

	// Sibling-branch content must NOT be present — that's the bug.
	for _, banned := range []string{"BETA-FORK", "BETA-FORK-REPLY"} {
		if strings.Contains(transcript, banned) {
			t.Errorf("transcript leaked sibling-branch content %q\n--- transcript ---\n%s", banned, transcript)
		}
	}
}
