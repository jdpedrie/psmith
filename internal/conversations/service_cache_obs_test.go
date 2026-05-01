package conversations

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/fakellm"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/plugins"
)

// TestCacheObs_FirstTurnRecordsHashesNullsMetrics — the very first send for
// a context records prefix_hashes + prefix_length but leaves
// stable_prefix_length / trailing_depth NULL because there's nothing to
// compare against.
func TestCacheObs_FirstTurnRecordsHashesNullsMetrics(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "hi"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hello",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	_ = waitForTerminal(t, sup, runID)

	row, _ := q.GetStreamRunByID(context.Background(), runID)
	if row.PrefixLength == nil || *row.PrefixLength <= 0 {
		t.Errorf("prefix_length should be set; got %+v", row.PrefixLength)
	}
	if row.CacheStablePrefixLength != nil {
		t.Errorf("cache_stable_prefix_length should be NULL on first turn; got %d", *row.CacheStablePrefixLength)
	}
	if row.CacheTrailingDepth != nil {
		t.Errorf("cache_trailing_depth should be NULL on first turn; got %d", *row.CacheTrailingDepth)
	}
	if len(row.PrefixHashes) == 0 {
		t.Error("prefix_hashes should be set on first turn")
	}
}

// TestCacheObs_SecondTurnNoPluginsFullStable — second turn with no plugin
// pipeline. The previous prefix is fully present in the new one (just the
// new turn appended), so stable_prefix_length should equal the previous
// prefix length and trailing_depth should be 0.
func TestCacheObs_SecondTurnNoPluginsFullStable(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a1", "a2"} {
		fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}}})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	_, _ = runOneTurn(t, svc, sup, q, f, "first")
	_, _ = runOneTurn(t, svc, sup, q, f, "second")

	// Second turn's stream_run has the diagnostics.
	runs, _ := q.ListStreamRunsByConversation(context.Background(), f.conv.ID)
	if len(runs) < 2 {
		t.Fatalf("expected >=2 runs, got %d", len(runs))
	}
	// runs is started_at DESC; runs[0] is the second turn.
	second := runs[0]
	first := runs[1]
	if second.CacheStablePrefixLength == nil {
		t.Fatal("second turn missing cache_stable_prefix_length")
	}
	if second.CacheTrailingDepth == nil {
		t.Fatal("second turn missing cache_trailing_depth")
	}
	// First turn's prefix should be entirely contained in the second's, so
	// stable equals first turn's prefix_length and trailing_depth = 0.
	if first.PrefixLength == nil {
		t.Fatal("first turn missing prefix_length")
	}
	if *second.CacheStablePrefixLength != *first.PrefixLength {
		t.Errorf("stable_prefix_length = %d want %d (= first turn's prefix_length)",
			*second.CacheStablePrefixLength, *first.PrefixLength)
	}
	if *second.CacheTrailingDepth != 0 {
		t.Errorf("trailing_depth = %d want 0 (no plugin invalidation)", *second.CacheTrailingDepth)
	}
}

// TestCacheObs_LetteredChoicesShiftsTrailingByOne — with KeepLastN=1, when
// the second send happens, the previously-most-recent assistant turn ages
// out of the keep window and gets stripped. Its bytes therefore differ
// between turn 1 and turn 2 → trailing depth should be > 0.
//
// Because the strip only kicks in when there's an assistant turn that JUST
// aged out, this test runs three turns to make sure a1 has been around
// long enough for the strip to bite at turn 3's send.
func TestCacheObs_LetteredChoicesShiftsTrailingByOne(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a1 <choices>A) one</choices>", "a2 <choices>X) other</choices>", "a3 <choices>P) p</choices>"} {
		fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}}})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID:  f.profile.ID,
		Ordinal:    0,
		PluginName: plugins.LetteredChoicesName,
		Config:     []byte(`{"keep_last_n": 1}`),
	}); err != nil {
		t.Fatalf("InsertProfilePlugin: %v", err)
	}

	_, _ = runOneTurn(t, svc, sup, q, f, "first")
	_, _ = runOneTurn(t, svc, sup, q, f, "second")
	_, _ = runOneTurn(t, svc, sup, q, f, "third")

	runs, _ := q.ListStreamRunsByConversation(context.Background(), f.conv.ID)
	if len(runs) < 3 {
		t.Fatalf("expected 3 runs, got %d", len(runs))
	}
	third := runs[0]
	if third.CacheStablePrefixLength == nil || third.CacheTrailingDepth == nil {
		t.Fatal("third turn missing cache fields")
	}
	// At turn 3, a1 (most-recent assistant in turn 2) is now 1-back, so a2
	// is the latest and a1 gets its choices stripped. That means a1's bytes
	// changed between the second and third sends → trailing > 0.
	if *third.CacheTrailingDepth == 0 {
		t.Errorf("expected trailing_depth > 0 (lettered_choices invalidates a1's bytes); got 0")
	}
}

// TestCacheObs_ForkProducesShortPrefixDivergesEarly — a fork from the
// system message produces a brand-new short prefix that should diverge
// early from the previous turn's longer one.
func TestCacheObs_ForkProducesShortPrefixDivergesEarly(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a1", "fork-asst"} {
		fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}}})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	_, _ = runOneTurn(t, svc, sup, q, f, "first")

	// Fork off the system message — produces a 2-message prefix
	// (system + new user) instead of the 4-message one (system + first user
	// + asst + new user) the no-fork case would produce.
	pid := f.provider.ID.String()
	mid := f.modelID
	sysStr := f.systemMsgID.String()
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &sysStr,
		Content:         "fork",
		ProviderId:      &pid,
		ModelId:         &mid,
	}))
	if err != nil {
		t.Fatalf("fork SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	_ = waitForTerminal(t, sup, runID)

	row, _ := q.GetStreamRunByID(context.Background(), runID)
	if row.CacheStablePrefixLength == nil || row.CacheTrailingDepth == nil {
		t.Fatal("fork turn missing cache fields")
	}
	// stable_prefix_length should be 1 (just the system message) — the user
	// message at index 1 is brand-new content, diverges from turn 1's user.
	if *row.CacheStablePrefixLength != 1 {
		t.Errorf("fork stable_prefix_length = %d want 1 (just the system message)",
			*row.CacheStablePrefixLength)
	}
	// trailing_depth = previous turn's prefix_length - 1.
	if *row.CacheTrailingDepth <= 0 {
		t.Errorf("fork trailing_depth = %d want > 0 (most of previous prefix invalidated)",
			*row.CacheTrailingDepth)
	}
}

// TestCacheObs_StreamRunProtoExposesFields — confirms the wire-shape
// converter actually populates the new optional fields. Catches drift if
// someone adds a column but forgets to wire it through.
func TestCacheObs_StreamRunProtoExposesFields(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a1", "a2"} {
		fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}}})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	_, _ = runOneTurn(t, svc, sup, q, f, "first")

	// Second turn — the response carries the diagnostics for it directly.
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "second",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	_ = waitForTerminal(t, sup, runID)

	// Re-fetch the persisted row's proto via supervisor.Get → streamsvc-style
	// conversion (we use the conversations-package converter, but the fields
	// are the same in both).
	row, _ := q.GetStreamRunByID(context.Background(), runID)
	proto := streamRunToProto(row)
	if proto.PrefixLength == nil {
		t.Error("proto.PrefixLength should be set")
	}
	if proto.CacheStablePrefixLength == nil {
		t.Error("proto.CacheStablePrefixLength should be set on second turn")
	}
	if proto.CacheTrailingDepth == nil {
		t.Error("proto.CacheTrailingDepth should be set on second turn")
	}
}
