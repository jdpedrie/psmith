package google

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/internal/providers"
)

// TestUserPartsFromWire_EmptyContentFallback verifies the placeholder
// the user-parts builder emits when there's truly nothing to send is
// non-empty enough to survive `json:"text,omitempty"` — otherwise the
// wire serialises as `{}` and Gemini rejects with HTTP 400 "parts[*].data:
// required oneof field 'data' must have one initialized field."
func TestUserPartsFromWire_EmptyContentFallback(t *testing.T) {
	t.Parallel()
	parts := userPartsFromWire(providers.WireMessage{Role: "user"})
	if len(parts) != 1 {
		t.Fatalf("expected exactly one placeholder part; got %d", len(parts))
	}
	body, err := json.Marshal(parts[0])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Reject the failure mode: an empty `{}` part with no oneof set.
	if string(body) == "{}" {
		t.Errorf("placeholder serialized as empty object %s — Gemini would reject this", string(body))
	}
	// Confirm the text field landed on the wire.
	if !strings.Contains(string(body), `"text"`) {
		t.Errorf("placeholder must carry the text field; got %s", string(body))
	}
}

func TestAssistantPartsFromWire_EmptyContentFallback(t *testing.T) {
	t.Parallel()
	parts := assistantPartsFromWire(providers.WireMessage{Role: "assistant"})
	if len(parts) != 1 {
		t.Fatalf("expected exactly one placeholder part; got %d", len(parts))
	}
	body, err := json.Marshal(parts[0])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(body) == "{}" {
		t.Errorf("placeholder serialized as empty object — Gemini would reject this")
	}
	if !strings.Contains(string(body), `"text"`) {
		t.Errorf("placeholder must carry the text field; got %s", string(body))
	}
}

// TestUserPartsFromWire_TextContentSerialisesFine sanity check —
// regular non-empty content should still hit the wire normally.
func TestUserPartsFromWire_TextContentSerialisesFine(t *testing.T) {
	t.Parallel()
	parts := userPartsFromWire(providers.WireMessage{Role: "user", Content: "hello"})
	if len(parts) != 1 {
		t.Fatalf("expected one part; got %d", len(parts))
	}
	if parts[0].Text != "hello" {
		t.Errorf("text content: got %q", parts[0].Text)
	}
}
