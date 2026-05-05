package crypto

import "encoding/json"

// Secret wraps a sensitive byte slice (API key, password, token) with
// formatters that refuse to print it. The underlying bytes are still
// reachable via Reveal() — Go gives no real way to hide them from a
// determined caller, and a sealed-envelope-in-memory pattern doesn't
// pay off when the official provider SDKs hold the key as a plain
// string anyway. The point is twofold:
//
//  1. Default String/Format/MarshalJSON paths can't accidentally
//     leak the value into a slog.Info, fmt.Errorf, or RPC response.
//  2. Reading the value is loud — Reveal() is greppable in code
//     review; cfg.APIKey + " token" is not.
//
// Use Secret in long-lived in-process types (driver config structs,
// cached pipeline state). DO NOT use it for the bytes you're about
// to hand to an SDK constructor — that needs a string and the SDK
// keeps it anyway.
type Secret []byte

// Reveal returns the underlying bytes. The verb is deliberately blunt
// so call sites read as "this line touches a secret" in review.
func (s Secret) Reveal() []byte { return []byte(s) }

// RevealString returns the underlying bytes as a string. Same caveat
// as Reveal: the returned string is now reachable through every
// channel a string can flow through, so use sparingly.
func (s Secret) RevealString() string { return string(s) }

// String renders "[REDACTED]" regardless of contents — even for an
// empty Secret, so the redacted form is uniform and there's no
// length-leak side channel.
func (Secret) String() string { return "[REDACTED]" }

// Format implements fmt.Formatter so %v / %+v / %#v / %s / %q all
// produce "[REDACTED]" instead of dumping the bytes. Without this,
// %#v on a struct embedding Secret would print the byte slice in full.
func (s Secret) Format(f interface {
	Write([]byte) (int, error)
}, _ rune) {
	_, _ = f.Write([]byte("[REDACTED]"))
}

// MarshalJSON makes Secret JSON-encode as the string "[REDACTED]"
// rather than exposing the base64 default for byte slices. Callers
// that need the actual value in JSON (e.g., the encrypt path before
// hitting the DB) reach for Reveal first.
func (Secret) MarshalJSON() ([]byte, error) { return json.Marshal("[REDACTED]") }

// IsZero reports whether the Secret is empty / unset. Useful for the
// "user didn't supply an api_key in the partial update — keep the
// existing one" branch on the model-providers update path.
func (s Secret) IsZero() bool { return len(s) == 0 }
