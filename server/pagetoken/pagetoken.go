// Package pagetoken encodes keyset-pagination cursors as opaque page
// tokens. A cursor is the (sort key, row id) tuple of the last row on a
// page; the next page resumes strictly after it. Both the conversations
// and profiles lists page on a (timestamptz, uuid) tuple, so one shape
// covers them.
//
// The token is base64url-encoded JSON rather than something cleverer:
// it round-trips through URLs and proto strings safely, and a mangled
// token fails loudly at Decode instead of silently misparsing.
package pagetoken

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type cursor struct {
	// Key is the row's sort-key timestamp, RFC3339Nano.
	Key time.Time `json:"k"`
	// ID is the row's uuid, breaking sort-key ties.
	ID uuid.UUID `json:"id"`
}

// Encode builds the opaque token for a (sort key, id) cursor.
func Encode(key time.Time, id uuid.UUID) string {
	b, _ := json.Marshal(cursor{Key: key, ID: id})
	return base64.RawURLEncoding.EncodeToString(b)
}

// Decode parses a token back into its cursor. An empty token returns
// zero values and ok=false (first page); a malformed token errors.
func Decode(token string) (key time.Time, id uuid.UUID, ok bool, err error) {
	if token == "" {
		return time.Time{}, uuid.Nil, false, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return time.Time{}, uuid.Nil, false, fmt.Errorf("pagetoken: %w", err)
	}
	var c cursor
	if err := json.Unmarshal(b, &c); err != nil {
		return time.Time{}, uuid.Nil, false, fmt.Errorf("pagetoken: %w", err)
	}
	return c.Key, c.ID, true, nil
}
