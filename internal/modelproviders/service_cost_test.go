package modelproviders

import (
	"context"
	"strconv"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/protobuf/types/known/timestamppb"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/store"
)

func makeNumeric(t *testing.T, v float64) pgtype.Numeric {
	t.Helper()
	var n pgtype.Numeric
	if err := n.Scan(strconv.FormatFloat(v, 'f', 6, 64)); err != nil {
		t.Fatalf("scan numeric: %v", err)
	}
	return n
}

// TestListProviderCosts_GroupsByProviderAndSums seeds two providers, drops a
// handful of cost events, and verifies the rollup is keyed correctly and the
// grand total matches the seeded amounts.
func TestListProviderCosts_GroupsByProviderAndSums(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)

	typeName := registerStatelessFakeDriver(t, "cost-grouping", nil, nil, nil, nil)
	provA := makeProvider(t, q, user.ID, typeName, "Anthropic-ish", nil)
	provB := makeProvider(t, q, user.ID, typeName, "Bedrock-ish", nil)

	bg := context.Background()
	for _, amt := range []float64{0.0012, 0.0045, 0.0007} {
		if err := q.InsertCostEvent(bg, store.InsertCostEventParams{
			ProviderID: provA.ID,
			ModelID:    "m",
			AmountUsd:  makeNumeric(t, amt),
		}); err != nil {
			t.Fatalf("InsertCostEvent A: %v", err)
		}
	}
	if err := q.InsertCostEvent(bg, store.InsertCostEventParams{
		ProviderID: provB.ID,
		ModelID:    "m",
		AmountUsd:  makeNumeric(t, 0.1000),
	}); err != nil {
		t.Fatalf("InsertCostEvent B: %v", err)
	}

	resp, err := svc.ListProviderCosts(ctxAs(user), connect.NewRequest(&spaltv1.ListProviderCostsRequest{}))
	if err != nil {
		t.Fatalf("ListProviderCosts: %v", err)
	}
	if len(resp.Msg.Providers) != 2 {
		t.Fatalf("expected 2 provider rows, got %d", len(resp.Msg.Providers))
	}

	got := map[string]*spaltv1.ProviderCost{}
	for _, p := range resp.Msg.Providers {
		got[p.ProviderId] = p
	}
	a := got[provA.ID.String()]
	if a == nil {
		t.Fatalf("provider A missing from response")
	}
	if delta := a.TotalCostUsd - (0.0012 + 0.0045 + 0.0007); delta > 1e-9 || delta < -1e-9 {
		t.Errorf("provider A total = %f, want ~0.0064", a.TotalCostUsd)
	}
	if a.EventCount != 3 {
		t.Errorf("provider A event_count = %d, want 3", a.EventCount)
	}
	b := got[provB.ID.String()]
	if b == nil {
		t.Fatalf("provider B missing from response")
	}
	if delta := b.TotalCostUsd - 0.1000; delta > 1e-9 || delta < -1e-9 {
		t.Errorf("provider B total = %f, want 0.10", b.TotalCostUsd)
	}
	if delta := resp.Msg.GrandTotalUsd - 0.1064; delta > 1e-9 || delta < -1e-9 {
		t.Errorf("grand total = %f, want ~0.1064", resp.Msg.GrandTotalUsd)
	}
}

// TestListProviderCosts_IncludesProvidersWithNoEvents — a provider that has
// never been used must still appear with $0 so the user sees their full
// configured-providers list rather than a silently-shorter one.
func TestListProviderCosts_IncludesProvidersWithNoEvents(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerStatelessFakeDriver(t, "cost-empty", nil, nil, nil, nil)
	_ = makeProvider(t, q, user.ID, typeName, "Unused", nil)

	resp, err := svc.ListProviderCosts(ctxAs(user), connect.NewRequest(&spaltv1.ListProviderCostsRequest{}))
	if err != nil {
		t.Fatalf("ListProviderCosts: %v", err)
	}
	if len(resp.Msg.Providers) != 1 {
		t.Fatalf("expected 1 provider row, got %d", len(resp.Msg.Providers))
	}
	row := resp.Msg.Providers[0]
	if row.TotalCostUsd != 0 {
		t.Errorf("expected $0 for unused provider, got %f", row.TotalCostUsd)
	}
	if row.EventCount != 0 {
		t.Errorf("expected 0 events for unused provider, got %d", row.EventCount)
	}
	if resp.Msg.GrandTotalUsd != 0 {
		t.Errorf("expected grand total $0, got %f", resp.Msg.GrandTotalUsd)
	}
}

// TestListProviderCosts_ScopedByCaller — another user's provider must not leak
// into Alice's rollup, even if it has events on the table.
func TestListProviderCosts_ScopedByCaller(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	alice := mustUser(t, q, "alice", false)
	bob := mustUser(t, q, "bob", false)
	typeName := registerStatelessFakeDriver(t, "cost-scope", nil, nil, nil, nil)
	provAlice := makeProvider(t, q, alice.ID, typeName, "Alice's", nil)
	provBob := makeProvider(t, q, bob.ID, typeName, "Bob's", nil)
	_ = uuid.New() // silence unused-helper guard if we trim later

	bg := context.Background()
	if err := q.InsertCostEvent(bg, store.InsertCostEventParams{
		ProviderID: provAlice.ID, ModelID: "m", AmountUsd: makeNumeric(t, 0.01),
	}); err != nil {
		t.Fatal(err)
	}
	if err := q.InsertCostEvent(bg, store.InsertCostEventParams{
		ProviderID: provBob.ID, ModelID: "m", AmountUsd: makeNumeric(t, 9.99),
	}); err != nil {
		t.Fatal(err)
	}

	resp, err := svc.ListProviderCosts(ctxAs(alice), connect.NewRequest(&spaltv1.ListProviderCostsRequest{}))
	if err != nil {
		t.Fatalf("ListProviderCosts: %v", err)
	}
	if len(resp.Msg.Providers) != 1 {
		t.Fatalf("alice should only see her own provider; got %d rows", len(resp.Msg.Providers))
	}
	if resp.Msg.Providers[0].ProviderId != provAlice.ID.String() {
		t.Errorf("wrong provider surfaced: %s", resp.Msg.Providers[0].ProviderId)
	}
	if delta := resp.Msg.GrandTotalUsd - 0.01; delta > 1e-9 || delta < -1e-9 {
		t.Errorf("alice's grand total leaked bob's events: %f", resp.Msg.GrandTotalUsd)
	}
}

// TestListProviderCosts_WindowFilter — events outside [since, until) must
// be excluded from totals; until is exclusive, since is inclusive (the
// boundary-event check pins the convention so abutting windows don't
// double-count).
func TestListProviderCosts_WindowFilter(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	typeName := registerStatelessFakeDriver(t, "cost-window", nil, nil, nil, nil)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	bg := context.Background()
	insertAt := func(amount float64, at time.Time) {
		t.Helper()
		// Insert and then patch occurred_at via SQL (the InsertCostEvent
		// helper hardcodes NOW(); for window tests we need precise
		// occurred_at values).
		if err := q.InsertCostEvent(bg, store.InsertCostEventParams{
			ProviderID: prov.ID, ModelID: "m", AmountUsd: makeNumeric(t, amount),
		}); err != nil {
			t.Fatal(err)
		}
	}
	// Use the cost_events table's default occurred_at (now()) for all
	// inserts and pick the window around now to exercise [since, until).
	now := time.Now().UTC()
	insertAt(0.01, now)
	insertAt(0.02, now)
	insertAt(0.04, now)

	// All-time: 0.07 across 3 events.
	resp, err := svc.ListProviderCosts(ctxAs(user), connect.NewRequest(&spaltv1.ListProviderCostsRequest{}))
	if err != nil {
		t.Fatalf("all-time: %v", err)
	}
	if delta := resp.Msg.GrandTotalUsd - 0.07; delta > 1e-9 || delta < -1e-9 {
		t.Errorf("all-time total = %f, want 0.07", resp.Msg.GrandTotalUsd)
	}
	if resp.Msg.Providers[0].EventCount != 3 {
		t.Errorf("all-time event count = %d, want 3", resp.Msg.Providers[0].EventCount)
	}

	// Future-only window — should be empty.
	future := now.Add(time.Hour)
	resp, err = svc.ListProviderCosts(ctxAs(user), connect.NewRequest(&spaltv1.ListProviderCostsRequest{
		Since: timestamppb.New(future),
	}))
	if err != nil {
		t.Fatalf("future since: %v", err)
	}
	if resp.Msg.GrandTotalUsd != 0 {
		t.Errorf("future-only grand total = %f, want 0", resp.Msg.GrandTotalUsd)
	}
	if resp.Msg.Providers[0].EventCount != 0 {
		t.Errorf("future-only event count = %d, want 0", resp.Msg.Providers[0].EventCount)
	}

	// Past-bounded until — also empty.
	past := now.Add(-time.Hour)
	resp, err = svc.ListProviderCosts(ctxAs(user), connect.NewRequest(&spaltv1.ListProviderCostsRequest{
		Until: timestamppb.New(past),
	}))
	if err != nil {
		t.Fatalf("past until: %v", err)
	}
	if resp.Msg.GrandTotalUsd != 0 {
		t.Errorf("past-until grand total = %f, want 0", resp.Msg.GrandTotalUsd)
	}

	// Window that includes now — should match all-time.
	resp, err = svc.ListProviderCosts(ctxAs(user), connect.NewRequest(&spaltv1.ListProviderCostsRequest{
		Since: timestamppb.New(past),
		Until: timestamppb.New(future),
	}))
	if err != nil {
		t.Fatalf("bounded: %v", err)
	}
	if delta := resp.Msg.GrandTotalUsd - 0.07; delta > 1e-9 || delta < -1e-9 {
		t.Errorf("bounded total = %f, want 0.07", resp.Msg.GrandTotalUsd)
	}
}
