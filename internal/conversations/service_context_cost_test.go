package conversations

import (
	"context"
	"math"
	"strconv"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
)

// The per-context cost aggregate must span EVERY message in the
// context — including branches the user forked away from. The iOS
// cost chip reads this aggregate precisely because a chain-local sum
// undercounts after a fork (user-reported).
func TestListContexts_CumulativeCostSpansAllBranches(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://unused.invalid")
	ctx := context.Background()

	// A user turn, then TWO assistant siblings under it — the fork
	// shape. Only one sibling can be on the "current" chain; the
	// aggregate must count both.
	user, err := q.CreateMessage(ctx, store.CreateMessageParams{
		ID: uuid.New(), ContextID: f.contextID, Role: "user", Content: "fork here",
	})
	if err != nil {
		t.Fatalf("CreateMessage(user): %v", err)
	}
	costs := []float64{0.25, 0.75}
	for i, c := range costs {
		parent := user.ID
		if _, err := q.CreateAssistantMessageWithUsage(ctx, store.CreateAssistantMessageWithUsageParams{
			ID: uuid.New(), ContextID: f.contextID, ParentID: &parent,
			Role: "assistant", Content: "branch " + strconv.Itoa(i),
			TotalCostUsd: testNumeric(t, c),
		}); err != nil {
			t.Fatalf("CreateAssistantMessageWithUsage(%d): %v", i, err)
		}
	}

	resp, err := svc.ListContexts(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListContextsRequest{
		ConversationId: f.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("ListContexts: %v", err)
	}
	var row *psmithv1.Context
	for _, c := range resp.Msg.Contexts {
		if c.Id == f.contextID.String() {
			row = c
		}
	}
	if row == nil {
		t.Fatal("seeded context missing from ListContexts")
	}
	if math.Abs(row.CumulativeCostUsd-1.0) > 1e-9 {
		t.Errorf("cumulative_cost_usd = %v, want 1.0 (both branches summed)", row.CumulativeCostUsd)
	}
}

func testNumeric(t *testing.T, v float64) pgtype.Numeric {
	t.Helper()
	var n pgtype.Numeric
	if err := n.Scan(strconv.FormatFloat(v, 'f', 6, 64)); err != nil {
		t.Fatalf("numeric scan: %v", err)
	}
	return n
}

// cache_savings_usd prices the cache delta from the CURRENT
// user_models row: cache_read_tokens x input price x provider discount
// (0.9 on anthropic). Rows without provider/model attribution
// contribute zero instead of poisoning the aggregate.
func TestListContexts_CacheSavingsAggregate(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://unused.invalid")
	ctx := context.Background()

	// 1M cache-read tokens at input price 3.0/M on anthropic:
	// savings = 1_000_000 * 3.0 / 1e6 * 0.9 = 2.7.
	cacheRead := int32(1_000_000)
	modelID := f.modelID
	if _, err := q.CreateAssistantMessageWithUsage(ctx, store.CreateAssistantMessageWithUsageParams{
		ID: uuid.New(), ContextID: f.contextID,
		Role: "assistant", Content: "cached turn",
		ProviderID:      &f.provider.ID,
		ModelID:         &modelID,
		CacheReadTokens: &cacheRead,
		TotalCostUsd:    testNumeric(t, 0.30),
	}); err != nil {
		t.Fatalf("CreateAssistantMessageWithUsage: %v", err)
	}
	// Unattributed row (no provider/model): must contribute zero.
	if _, err := q.CreateMessage(ctx, store.CreateMessageParams{
		ID: uuid.New(), ContextID: f.contextID, Role: "user", Content: "hi",
	}); err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}

	resp, err := svc.ListContexts(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListContextsRequest{
		ConversationId: f.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("ListContexts: %v", err)
	}
	var row *psmithv1.Context
	for _, c := range resp.Msg.Contexts {
		if c.Id == f.contextID.String() {
			row = c
		}
	}
	if row == nil {
		t.Fatal("seeded context missing from ListContexts")
	}
	if math.Abs(row.CacheSavingsUsd-2.7) > 1e-9 {
		t.Errorf("cache_savings_usd = %v, want 2.7", row.CacheSavingsUsd)
	}
}
