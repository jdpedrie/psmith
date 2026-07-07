package pagetoken

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestRoundTrip(t *testing.T) {
	key := time.Date(2026, 7, 7, 12, 34, 56, 789_000_000, time.UTC)
	id := uuid.New()

	tok := Encode(key, id)
	gotKey, gotID, ok, err := Decode(tok)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if !ok {
		t.Fatal("ok=false for a non-empty token")
	}
	if !gotKey.Equal(key) || gotID != id {
		t.Errorf("round trip: got (%v, %v) want (%v, %v)", gotKey, gotID, key, id)
	}
}

func TestDecode_Empty(t *testing.T) {
	_, _, ok, err := Decode("")
	if err != nil || ok {
		t.Errorf("empty token: want (ok=false, err=nil), got (ok=%v, err=%v)", ok, err)
	}
}

func TestDecode_Garbage(t *testing.T) {
	for _, tok := range []string{"not base64 ???", "bm90IGpzb24", "eyJrIjoibm90LWEtdGltZSJ9"} {
		if _, _, _, err := Decode(tok); err == nil {
			t.Errorf("Decode(%q): want error, got nil", tok)
		}
	}
}
