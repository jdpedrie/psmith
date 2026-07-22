package stream

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"math"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"

	"github.com/jdpedrie/psmith/internal/providers"
)

// Tiered pricing at the cost-recording boundary: a prompt past the
// threshold prices the WHOLE request at the tier's rates; below it the
// base columns apply; tier subfields left nil inherit the base.
func TestBuildUsageParams_TieredPricing(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	bg := context.Background()

	userID := mustUUID(t)
	user, err := q.CreateUser(bg, store.CreateUserParams{
		ID: userID, Username: "u-" + userID.String()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	provID := mustUUID(t)
	prov, err := q.CreateUserModelProvider(bg, store.CreateUserModelProviderParams{
		ID: provID, UserID: user.ID, Type: "openai-compatible", Label: "t", ConfigEncrypted: []byte(`{}`),
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}

	base := 3.0
	outP := 15.0
	tiers, _ := json.Marshal([]map[string]any{
		// Input doubles past 128k; output inherits the base column.
		{"threshold_tokens": 128_000, "input_per_million": 6.0},
	})
	if _, err := q.UpsertUserModel(bg, store.UpsertUserModelParams{
		UserModelProviderID:   prov.ID,
		ModelID:               "tiered-model",
		DisplayName:           "Tiered",
		InputPricePerMillion:  &base,
		OutputPricePerMillion: &outP,
		PricingTiers:          tiers,
		MetadataSource:        "manual",
		MetadataSnapshotAt:    time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	iTok := func(v int) *int { return &v }

	// Below the threshold: base rates. 100k * 3.0 / 1M = 0.3 input.
	below := buildUsageParams(bg, q, prov.ID, "tiered-model", &providers.Usage{
		InputTokens: iTok(100_000), OutputTokens: iTok(1_000),
	}, nil, logger)
	if got := numericFloat(t, below.InputCostUsd); !almost(got, 0.3) {
		t.Errorf("below-threshold input cost = %v, want 0.3", got)
	}

	// Past the threshold (input alone): tier input rate, base output
	// rate (tier leaves output nil). 200k * 6.0 / 1M = 1.2; output
	// 1k * 15 / 1M = 0.015.
	above := buildUsageParams(bg, q, prov.ID, "tiered-model", &providers.Usage{
		InputTokens: iTok(200_000), OutputTokens: iTok(1_000),
	}, nil, logger)
	if got := numericFloat(t, above.InputCostUsd); !almost(got, 1.2) {
		t.Errorf("above-threshold input cost = %v, want 1.2", got)
	}
	if got := numericFloat(t, above.OutputCostUsd); !almost(got, 0.015) {
		t.Errorf("above-threshold output cost = %v, want 0.015 (base rate)", got)
	}

	// Cache reads count toward the tier key: 60k input + 100k cache
	// read = 160k prompt → tier rate on the input component.
	cached := buildUsageParams(bg, q, prov.ID, "tiered-model", &providers.Usage{
		InputTokens: iTok(60_000), CacheReadTokens: iTok(100_000),
	}, nil, logger)
	if got := numericFloat(t, cached.InputCostUsd); !almost(got, 0.36) {
		t.Errorf("cache-inclusive tier key: input cost = %v, want 0.36 (60k at 6.0)", got)
	}
}

func numericFloat(t *testing.T, n pgtype.Numeric) float64 {
	t.Helper()
	if !n.Valid {
		t.Fatal("numeric not valid")
	}
	f, err := n.Float64Value()
	if err != nil || !f.Valid {
		t.Fatalf("float64 value: %v", err)
	}
	return f.Float64
}

func almost(a, b float64) bool { return math.Abs(a-b) < 1e-9 }
