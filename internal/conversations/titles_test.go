package conversations

import (
	"context"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/clark/fakellm"
	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/internal/store"
)

// --- sanitizeTitle pure tests ---------------------------------------------

func TestSanitizeTitle(t *testing.T) {
	t.Parallel()
	cases := []struct {
		in, want string
	}{
		{"  Hello World  ", "Hello World"},
		{`"Quoted Title"`, "Quoted Title"},
		{`'Single Quoted'`, "Single Quoted"},
		{"Multiple   Spaces\t\nbetween", "Multiple Spaces between"},
		{"", ""},
		{strings.Repeat("a", 100), strings.Repeat("a", 80)},                                    // hard-cut at maxTitleLen when no word boundary
		{"a a a " + strings.Repeat("b", 90), "a a a " + strings.Repeat("b", 74)},               // last space is too early (pos < maxTitleLen/2): don't trim back, keep the cut
		// 20 × "word " is 100 chars; cut to 80 lands exactly on a trailing
		// space (16 "word "s = 80 chars). Trim back to the last space drops
		// it, leaving 16 words separated by 15 spaces = 79 chars.
		{strings.Repeat("word ", 20), strings.TrimRight(strings.Repeat("word ", 16), " ")},
	}
	for _, tc := range cases {
		got := sanitizeTitle(tc.in)
		if got != tc.want {
			t.Errorf("sanitizeTitle(%q) = %q want %q", tc.in, got, tc.want)
		}
	}
}

// --- end-to-end title generation via fakellm ------------------------------

// configureProfileTitle sets the title_* fields on the profile to the
// provider+model used by the fixture's fake driver.
func configureProfileTitle(t *testing.T, q *store.Queries, profileID uuid.UUID, providerID uuid.UUID, modelID string, guide *string) {
	t.Helper()
	bg := context.Background()
	if err := q.UpdateProfileTitleProviderID(bg, store.UpdateProfileTitleProviderIDParams{
		ID: profileID, TitleProviderID: &providerID,
	}); err != nil {
		t.Fatalf("UpdateProfileTitleProviderID: %v", err)
	}
	mid := modelID
	if err := q.UpdateProfileTitleModelID(bg, store.UpdateProfileTitleModelIDParams{
		ID: profileID, TitleModelID: &mid,
	}); err != nil {
		t.Fatalf("UpdateProfileTitleModelID: %v", err)
	}
	if guide != nil {
		if err := q.UpdateProfileTitleGuide(bg, store.UpdateProfileTitleGuideParams{
			ID: profileID, TitleGuide: guide,
		}); err != nil {
			t.Fatalf("UpdateProfileTitleGuide: %v", err)
		}
	}
}

// waitForTitlePopulated polls until conversation.Title is non-nil or
// timeout. Title generation is async (background goroutine).
func waitForTitlePopulated(t *testing.T, q *store.Queries, convID uuid.UUID, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		row, err := q.GetConversationByID(context.Background(), convID)
		if err != nil {
			t.Fatalf("GetConversationByID: %v", err)
		}
		if row.Title != nil && *row.Title != "" {
			return *row.Title
		}
		if time.Now().After(deadline) {
			t.Fatalf("title not populated within %s", timeout)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func waitForContextTitle(t *testing.T, q *store.Queries, cxID uuid.UUID, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		row, err := q.GetContextByID(context.Background(), cxID)
		if err != nil {
			t.Fatalf("GetContextByID: %v", err)
		}
		if row.Title != nil && *row.Title != "" {
			return *row.Title
		}
		if time.Now().After(deadline) {
			t.Fatalf("context title not populated within %s", timeout)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestTitle_E2E_GeneratesConversationAndContextTitles — the very first
// assistant turn triggers a single LLM call whose output populates both
// the conversation title (was NULL) and the active context title (was NULL).
func TestTitle_E2E_GeneratesConversationAndContextTitles(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	// First script: the assistant reply.
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Sure, here's an outline."}}})
	// Second script: the title-generation call (synchronous, fired post-materialization).
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Outline Discussion"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	// Wire the title hook — newFullSvc doesn't do this since it pre-dates the feature.
	sup.SetOnAssistantMaterialized(svc.MaybeGenerateTitle)
	configureProfileTitle(t, q, f.profile.ID, f.provider.ID, f.modelID, nil)

	_, _ = runOneTurn(t, svc, sup, q, f, "help me outline a talk")

	title := waitForTitlePopulated(t, q, f.conv.ID, 3*time.Second)
	if title != "Outline Discussion" {
		t.Errorf("conversation title = %q want %q", title, "Outline Discussion")
	}
	cxTitle := waitForContextTitle(t, q, f.contextID, 3*time.Second)
	if cxTitle != "Outline Discussion" {
		t.Errorf("context title = %q want %q", cxTitle, "Outline Discussion")
	}
}

// TestTitle_E2E_SkippedWhenAppleFoundationKind — profile has the
// "apple_foundation" sentinel set on title_provider_kind. The server skips
// title generation entirely (the Mac client owns it via on-device Foundation
// Models). Title remains NULL on the server side; the client persists it via
// UpdateConversation when it lands. Even if the cloud title fields are
// also configured, the kind sentinel takes precedence.
func TestTitle_E2E_SkippedWhenAppleFoundationKind(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	// Only the assistant reply — NO title call should be made.
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	sup.SetOnAssistantMaterialized(svc.MaybeGenerateTitle)
	// Configure the cloud title fields AND the apple_foundation kind. The
	// kind sentinel must short-circuit cloud generation.
	configureProfileTitle(t, q, f.profile.ID, f.provider.ID, f.modelID, nil)
	kind := "apple_foundation"
	if err := q.UpdateProfileTitleProviderKind(context.Background(), store.UpdateProfileTitleProviderKindParams{
		ID: f.profile.ID, TitleProviderKind: &kind,
	}); err != nil {
		t.Fatalf("UpdateProfileTitleProviderKind: %v", err)
	}

	_, _ = runOneTurn(t, svc, sup, q, f, "hi")

	// Wait briefly to give the (suppressed) title goroutine a chance.
	time.Sleep(200 * time.Millisecond)
	row, _ := q.GetConversationByID(context.Background(), f.conv.ID)
	if row.Title != nil {
		t.Errorf("title should remain NULL when title_provider_kind is set; got %+v", row.Title)
	}
	cx, _ := q.GetContextByID(context.Background(), f.contextID)
	if cx.Title != nil {
		t.Errorf("context title should remain NULL; got %+v", cx.Title)
	}
	// Only the assistant request should have hit the fake server — no
	// follow-up title call.
	if reqs := fake.Requests(); len(reqs) != 1 {
		t.Errorf("expected 1 fake request (assistant only); got %d", len(reqs))
	}
}

// TestTitle_E2E_SkippedWhenProfileNotConfigured — profile has no title_*
// fields; the hook fires but does nothing. Title remains NULL.
func TestTitle_E2E_SkippedWhenProfileNotConfigured(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	sup.SetOnAssistantMaterialized(svc.MaybeGenerateTitle)
	// No configureProfileTitle call.

	_, _ = runOneTurn(t, svc, sup, q, f, "hi")

	// Wait briefly; ensure title stays NULL.
	time.Sleep(200 * time.Millisecond)
	row, _ := q.GetConversationByID(context.Background(), f.conv.ID)
	if row.Title != nil {
		t.Errorf("title should remain NULL when profile not configured; got %+v", row.Title)
	}
	cx, _ := q.GetContextByID(context.Background(), f.contextID)
	if cx.Title != nil {
		t.Errorf("context title should remain NULL; got %+v", cx.Title)
	}
}

// TestTitle_E2E_NotRegeneratedOnSubsequentTurns — once the conversation has
// a title, subsequent turns don't trigger title calls. We verify this by
// enqueueing only the assistant scripts (no title scripts); if the hook
// fired a title call, the fake server would have nothing to return and
// the test would error in title generation (logged but doesn't fail).
// We assert the title doesn't change across turns instead.
func TestTitle_E2E_NotRegeneratedOnSubsequentTurns(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	// First assistant + first title.
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "first reply"}}})
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Initial Title"}}})
	// Second assistant only (no title — confirming no second title call is made).
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "second reply"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	sup.SetOnAssistantMaterialized(svc.MaybeGenerateTitle)
	configureProfileTitle(t, q, f.profile.ID, f.provider.ID, f.modelID, nil)

	_, _ = runOneTurn(t, svc, sup, q, f, "first")
	_ = waitForTitlePopulated(t, q, f.conv.ID, 3*time.Second)

	_, _ = runOneTurn(t, svc, sup, q, f, "second")
	// Wait briefly to give any (errantly fired) title goroutine a chance.
	time.Sleep(200 * time.Millisecond)

	row, _ := q.GetConversationByID(context.Background(), f.conv.ID)
	if row.Title == nil || *row.Title != "Initial Title" {
		t.Errorf("title changed across turns: %+v want %q", row.Title, "Initial Title")
	}
	// The fake server should still have one unused script (the unused
	// "title" slot we deliberately didn't enqueue).
	reqs := fake.Requests()
	// Two assistant calls + one title call = 3 requests total.
	if len(reqs) != 3 {
		t.Errorf("expected 3 fake requests (2 asst + 1 title); got %d", len(reqs))
	}
}

// TestTitle_E2E_PostCompactionContextTitle — after promoting a compaction,
// the new context's first assistant turn triggers context-title generation
// (conversation.title was already set, so it stays unchanged).
func TestTitle_E2E_PostCompactionContextTitle(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	// 1. First assistant
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "reply 1"}}})
	// 2. First title (covers conversation + initial context)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Original Title"}}})
	// 3. Compaction summary
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "compaction summary"}}})
	// 4. Post-promote assistant
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "reply post-promote"}}})
	// 5. Context title for the new context
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "New Phase"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	sup.SetOnAssistantMaterialized(svc.MaybeGenerateTitle)
	configureProfileTitle(t, q, f.profile.ID, f.provider.ID, f.modelID, nil)
	// Compression knobs.
	guide := "Summarize."
	mode := "REPLACE"
	bg := context.Background()
	_ = q.UpdateProfileCompressionGuide(bg, store.UpdateProfileCompressionGuideParams{ID: f.profile.ID, CompressionGuide: &guide})
	_ = q.UpdateProfileCompressionMode(bg, store.UpdateProfileCompressionModeParams{ID: f.profile.ID, CompressionMode: &mode})
	_ = q.UpdateProfileCompressionProviderID(bg, store.UpdateProfileCompressionProviderIDParams{ID: f.profile.ID, CompressionProviderID: &f.provider.ID})
	_ = q.UpdateProfileCompressionModelID(bg, store.UpdateProfileCompressionModelIDParams{ID: f.profile.ID, CompressionModelID: &f.modelID})

	// Turn 1 + initial title.
	_, _ = runOneTurn(t, svc, sup, q, f, "first")
	_ = waitForTitlePopulated(t, q, f.conv.ID, 3*time.Second)

	// Compact + Promote.
	cresp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&clarkv1.CompactRequest{ConversationId: f.conv.ID.String()}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	cRunID, _ := uuid.Parse(cresp.Msg.StreamRun.Id)
	cFinal := waitForTerminal(t, sup, cRunID)
	if cFinal.ResultMessageID == nil {
		t.Fatal("compact: no summary id")
	}
	pResp, err := svc.PromoteCompactionToNewContext(ctxAsUser(f.user), connect.NewRequest(&clarkv1.PromoteCompactionToNewContextRequest{
		MessageId: cFinal.ResultMessageID.String(),
	}))
	if err != nil {
		t.Fatalf("Promote: %v", err)
	}
	newCxID, _ := uuid.Parse(pResp.Msg.Context.Id)

	// New context title is NULL initially.
	cxRow, _ := q.GetContextByID(bg, newCxID)
	if cxRow.Title != nil {
		t.Errorf("new context title should start NULL; got %+v", cxRow.Title)
	}

	// Send a turn into the new context — first assistant there triggers
	// new-context title generation. Conversation title is already set, so
	// the title model is still called (one call), but only the context
	// gets updated.
	_, _ = runOneTurn(t, svc, sup, q, f, "in new context")

	cxTitle := waitForContextTitle(t, q, newCxID, 3*time.Second)
	if cxTitle != "New Phase" {
		t.Errorf("new context title = %q want %q", cxTitle, "New Phase")
	}

	// Conversation title unchanged.
	convRow, _ := q.GetConversationByID(bg, f.conv.ID)
	if convRow.Title == nil || *convRow.Title != "Original Title" {
		t.Errorf("conversation title changed across compaction: %+v", convRow.Title)
	}
}

// --- UpdateContext --------------------------------------------------------

func TestUpdateContext_SetTitle(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "update-context-set", nil, nil)
	f := seedSendable(t, q, driverType)

	title := "Custom Title"
	resp, err := svc.UpdateContext(ctxAsUser(f.user), connect.NewRequest(&clarkv1.UpdateContextRequest{
		ContextId: f.contextID.String(),
		Title:     &title,
	}))
	if err != nil {
		t.Fatalf("UpdateContext: %v", err)
	}
	if got := resp.Msg.Context.GetTitle(); got != "Custom Title" {
		t.Errorf("response title = %q want %q", got, "Custom Title")
	}
	row, _ := q.GetContextByID(context.Background(), f.contextID)
	if row.Title == nil || *row.Title != "Custom Title" {
		t.Errorf("DB title = %+v", row.Title)
	}
}

func TestUpdateContext_ClearTitle(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "update-context-clear", nil, nil)
	f := seedSendable(t, q, driverType)
	pre := "Pre-existing"
	_ = q.UpdateContextTitle(context.Background(), store.UpdateContextTitleParams{
		ID: f.contextID, Title: &pre,
	})

	empty := ""
	if _, err := svc.UpdateContext(ctxAsUser(f.user), connect.NewRequest(&clarkv1.UpdateContextRequest{
		ContextId: f.contextID.String(),
		Title:     &empty,
	})); err != nil {
		t.Fatalf("UpdateContext: %v", err)
	}
	row, _ := q.GetContextByID(context.Background(), f.contextID)
	if row.Title != nil {
		t.Errorf("title should be cleared (NULL); got %+v", row.Title)
	}
}

func TestUpdateContext_CrossUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "update-context-cross", nil, nil)
	f := seedSendable(t, q, driverType)
	bob, _ := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: uuid.New(), Username: "bob-" + t.Name(), PasswordHash: "x",
	})
	title := "x"
	_, err := svc.UpdateContext(ctxAsUser(bob), connect.NewRequest(&clarkv1.UpdateContextRequest{
		ContextId: f.contextID.String(), Title: &title,
	}))
	assertCode(t, err, connect.CodeNotFound)
}
