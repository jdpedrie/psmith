package anthropic

import (
	"context"
	"testing"
	"time"

	"github.com/jdpedrie/psmith/internal/providers"
)

// TestExplicitCache_InterfaceConformance — compile-time check is in
// the production file; this is the runtime equivalent so a renamed
// interface method gets caught at test time too.
func TestExplicitCache_InterfaceConformance(t *testing.T) {
	var d providers.ExplicitCacheProvider = &Driver{}
	_ = d // satisfies linter
}

// TestExplicitCache_CreateReturnsSentinel — Anthropic has no upstream
// create call, so CreateExplicitCacheRef should return a stable
// sentinel + ~1h-from-now expiry without touching the network. We
// verify the network-not-touched path implicitly: the call should
// return immediately even with a nil http client.
func TestExplicitCache_CreateReturnsSentinel(t *testing.T) {
	d := &Driver{}
	ref, exp, err := d.CreateExplicitCacheRef(context.Background(), "claude-test", nil)
	if err != nil {
		t.Fatalf("CreateExplicitCacheRef: %v", err)
	}
	if ref == "" {
		t.Errorf("ref is empty")
	}
	if dur := time.Until(exp); dur < 50*time.Minute || dur > 70*time.Minute {
		t.Errorf("expiry %v not ~1h from now", dur)
	}
}

// TestExplicitCache_ApplyForcesTTL1h — the toggle's whole purpose for
// Anthropic is bumping the cache_control TTL from 5m to 1h. Verify
// ApplyExplicitCacheRef sets that on the request's Anthropic extras
// regardless of any prior CacheTTL value.
func TestExplicitCache_ApplyForcesTTL1h(t *testing.T) {
	d := &Driver{}
	cases := []struct {
		name    string
		extras  *providers.AnthropicExtras
		wantTTL providers.CacheTTL
	}{
		{
			name:    "nil extras → set TTL=1h on freshly-allocated extras",
			extras:  nil,
			wantTTL: providers.CacheTTL1h,
		},
		{
			name:    "5m → upgraded to 1h",
			extras:  &providers.AnthropicExtras{CacheTTL: providers.CacheTTL5m},
			wantTTL: providers.CacheTTL1h,
		},
		{
			name:    "unspecified → set to 1h",
			extras:  &providers.AnthropicExtras{},
			wantTTL: providers.CacheTTL1h,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := &providers.SendRequest{Settings: providers.CallSettings{Anthropic: c.extras}}
			d.ApplyExplicitCacheRef(req, "ref", 0)
			if req.Settings.Anthropic == nil {
				t.Fatal("extras nil after Apply")
			}
			if req.Settings.Anthropic.CacheTTL != c.wantTTL {
				t.Errorf("CacheTTL=%v want %v", req.Settings.Anthropic.CacheTTL, c.wantTTL)
			}
		})
	}
}

// TestExplicitCache_DeleteIsNoop — no upstream resource to delete
// means the call should return nil regardless of input.
func TestExplicitCache_DeleteIsNoop(t *testing.T) {
	d := &Driver{}
	if err := d.DeleteExplicitCacheRef(context.Background(), "any-ref"); err != nil {
		t.Errorf("Delete should be a noop, got %v", err)
	}
}

// TestExplicitCache_ApplyDoesNotTrim — Anthropic always sends the
// full wire prefix (cache is byte-keyed; the server matches the
// prefix against its cache). Verify ApplyExplicitCacheRef leaves
// req.Messages untouched even when prefixMessageCount > 0.
func TestExplicitCache_ApplyDoesNotTrim(t *testing.T) {
	d := &Driver{}
	req := &providers.SendRequest{
		Messages: []providers.WireMessage{
			{Role: "system", Content: "be terse"},
			{Role: "user", Content: "hi"},
			{Role: "assistant", Content: "hello"},
			{Role: "user", Content: "again"},
		},
	}
	original := len(req.Messages)
	d.ApplyExplicitCacheRef(req, "ref", 3)
	if len(req.Messages) != original {
		t.Errorf("Apply trimmed messages: %d → %d (Anthropic must keep the full prefix)", original, len(req.Messages))
	}
}
