package conversations

import (
	"testing"

	"github.com/jdpedrie/clark/internal/providers"
)

func TestHashWireMessages_StableForSameInputs(t *testing.T) {
	t.Parallel()
	in := []providers.WireMessage{
		{Role: "system", Content: "you are concise"},
		{Role: "user", Content: "hello"},
	}
	a := hashWireMessages(in)
	b := hashWireMessages(in)
	if len(a) != 2 || len(b) != 2 {
		t.Fatalf("len(a)=%d len(b)=%d want 2", len(a), len(b))
	}
	for i := range a {
		if a[i] != b[i] {
			t.Errorf("hash[%d] not stable: %s vs %s", i, a[i], b[i])
		}
	}
}

func TestHashWireMessages_DifferentRoleSameContentDiffer(t *testing.T) {
	t.Parallel()
	a := hashWireMessages([]providers.WireMessage{{Role: "user", Content: "x"}})
	b := hashWireMessages([]providers.WireMessage{{Role: "assistant", Content: "x"}})
	if a[0] == b[0] {
		t.Error("role should affect hash")
	}
}

// TestHashWireMessages_LengthPrefixDisambiguates ensures that two messages
// where role+content concat to the same byte string produce different
// hashes. Without the length prefix, ("user","ab") and ("use","rab") would
// collide.
func TestHashWireMessages_LengthPrefixDisambiguates(t *testing.T) {
	t.Parallel()
	a := hashWireMessages([]providers.WireMessage{{Role: "user", Content: "ab"}})
	b := hashWireMessages([]providers.WireMessage{{Role: "use", Content: "rab"}})
	if a[0] == b[0] {
		t.Error("role+content split should not collide via concatenation")
	}
}

func TestStablePrefixLength(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name           string
		cur, prev      []string
		wantStableLen  int
	}{
		{"both empty", nil, nil, 0},
		{"prev empty", []string{"a", "b"}, nil, 0},
		{"cur empty", nil, []string{"a", "b"}, 0},
		{"identical", []string{"a", "b", "c"}, []string{"a", "b", "c"}, 3},
		{"diverge at 0", []string{"x", "b"}, []string{"a", "b"}, 0},
		{"diverge at 1", []string{"a", "x"}, []string{"a", "b"}, 1},
		{"diverge at 2", []string{"a", "b", "x"}, []string{"a", "b", "c"}, 2},
		{"cur shorter, full match", []string{"a", "b"}, []string{"a", "b", "c"}, 2},
		{"prev shorter, full match", []string{"a", "b", "c"}, []string{"a", "b"}, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := stablePrefixLength(tc.cur, tc.prev); got != tc.wantStableLen {
				t.Errorf("stablePrefixLength(%v, %v) = %d want %d", tc.cur, tc.prev, got, tc.wantStableLen)
			}
		})
	}
}
