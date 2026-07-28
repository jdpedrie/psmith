package host

import (
	"time"

	"github.com/google/uuid"
)

// SearchOptions narrows the search. UserID is required (every
// search is scoped to one user's history; cross-user results are a
// privacy bug). Limit defaults to defaultLimit.
type SearchOptions struct {
	// UserID scopes the search. Required — there is no
	// cross-user search surface.
	UserID uuid.UUID

	// Limit caps the result count. Default 10, max 50; values
	// above the cap are silently clamped — the model rarely
	// benefits from more than 10-20 historical snippets and
	// asking for hundreds inflates the wire round-trip without
	// helping accuracy.
	Limit int

	// MaxDistance optionally drops hits with cosine distance
	// above the threshold. 0 = no filter (return everything the
	// LIMIT allows). 2.0 = "everything"; 0.4 is a reasonable
	// "definitely relevant" cutoff for nomic-embed-text. Most
	// callers leave this at 0 and apply their own filter on the
	// returned distances.
	MaxDistance float64
}

// Hit is one ranked message result. Distance is cosine — smaller
// is more similar; 0 = identical direction, 2 = opposite. Content
// is the raw message text (no truncation here; the caller decides
// how to summarize).
//
// ContextID + ConversationID travel together because a conversation
// is a sequence of contexts (compression retires an old context and
// opens a new one). The memory plugin uses ContextID to drop hits
// already in the wire prefix; conversation_id is the human-level
// grouping for display.
type Hit struct {
	MessageID         uuid.UUID
	ContextID         uuid.UUID
	ConversationID    uuid.UUID
	ConversationTitle string
	Role              string
	Content           string
	CreatedAt         time.Time
	// Distance is the cosine distance from the query vector.
	// Lower = more similar. Use it to threshold "definitely
	// relevant" (e.g. < 0.4 for nomic-embed-text) or to render a
	// confidence indicator alongside each hit.
	Distance float64
}
