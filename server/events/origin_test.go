package events

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/auth"
)

// The origin has to survive the trip to the wire, or a client has nothing to
// compare against and suppression silently never fires.
func TestOrigin_SurvivesToTheWire(t *testing.T) {
	t.Parallel()

	proto := eventToProto(Event{
		Type:           ProfileChanged,
		UserID:         uuid.New(),
		OriginClientID: "client-abc",
		Profile:        ProfilePayload{ProfileID: uuid.New(), Kind: ProfileChangeCreated},
	})
	if proto == nil {
		t.Fatal("expected a wire event")
	}
	if proto.OriginClientId != "client-abc" {
		t.Errorf("origin lost in translation: %q", proto.OriginClientId)
	}
}

// Anything with no originating request must carry an empty origin, which
// clients read as "not mine" and deliver. A supervisor hook that accidentally
// inherited some client's id would be suppressed by that client and the run
// would look like it never finished.
func TestOrigin_EmptyWhenNothingOriginated(t *testing.T) {
	t.Parallel()

	proto := eventToProto(Event{
		Type:         ConversationChanged,
		UserID:       uuid.New(),
		Conversation: ConversationPayload{ConversationID: uuid.New(), Kind: ConversationChangeUpdated},
	})
	if proto.OriginClientId != "" {
		t.Errorf("expected an empty origin, got %q", proto.OriginClientId)
	}
}

// The interceptor reads the header into the context; publishers read it back
// out. Both halves have to agree on the key or attribution silently no-ops.
func TestOrigin_ContextRoundTrip(t *testing.T) {
	t.Parallel()

	if got := auth.ClientIDFrom(context.Background()); got != "" {
		t.Errorf("a bare context should carry no client id, got %q", got)
	}

	ctx := auth.ContextWithClientID(context.Background(), auth.ClientID("abc"))
	if got := auth.ClientIDFrom(ctx); got != "abc" {
		t.Errorf("round trip failed: %q", got)
	}

	// An absent header must not create a bogus attribution, or every client
	// would suppress events it did not cause.
	ctx = auth.ContextWithClientID(context.Background(), auth.ClientID(""))
	if got := auth.ClientIDFrom(ctx); got != "" {
		t.Errorf("empty header should stay empty, got %q", got)
	}
}
