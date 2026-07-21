package conversations

import (
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/events"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/stream"
	"github.com/jdpedrie/psmith/internal/testutil"
)

// Conversation mutations must publish ConversationChanged onto the
// account bus — that push is what keeps a second client (Mac while
// iOS mutates, and vice versa) live without polling.

func newBusSvc(t *testing.T) (*Service, *store.Queries, *events.Bus) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	bus := events.New(nil)
	svc := NewService(q, pool, nil, nil, nil, nil, nil).WithBus(bus)
	return svc, q, bus
}

// recvEvent drains one event with a timeout so a missing publish fails
// fast instead of hanging the suite.
func recvEvent(t *testing.T, ch <-chan events.Event) events.Event {
	t.Helper()
	select {
	case ev := <-ch:
		return ev
	case <-time.After(2 * time.Second):
		t.Fatalf("expected an event, got none within 2s")
		return events.Event{}
	}
}

func assertConvEvent(t *testing.T, ev events.Event, userID, convID uuid.UUID, kind events.ConversationChangeKind) {
	t.Helper()
	if ev.Type != events.ConversationChanged {
		t.Fatalf("event type = %v, want ConversationChanged", ev.Type)
	}
	if ev.UserID != userID {
		t.Errorf("event user = %s, want %s", ev.UserID, userID)
	}
	if ev.Conversation.ConversationID != convID {
		t.Errorf("event conversation = %s, want %s", ev.Conversation.ConversationID, convID)
	}
	if ev.Conversation.Kind != kind {
		t.Errorf("event kind = %v, want %v", ev.Conversation.Kind, kind)
	}
}

func TestConversationEvents_LifecycleEmits(t *testing.T) {
	svc, q, bus := newBusSvc(t)
	user := mustCreateUser(t, q, "events-user")
	profile := makeProfile(t, q, user.ID, nil, nil, nil)
	ctx := ctxAs(user)

	ch, cancel := bus.Subscribe(user.ID)
	defer cancel()

	created, err := svc.CreateConversation(ctx, connect.NewRequest(&psmithv1.CreateConversationRequest{
		ProfileId: profile.ID.String(),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	convID := uuid.MustParse(created.Msg.Conversation.Id)
	assertConvEvent(t, recvEvent(t, ch), user.ID, convID, events.ConversationChangeCreated)

	title := "renamed"
	if _, err := svc.UpdateConversation(ctx, connect.NewRequest(&psmithv1.UpdateConversationRequest{
		Id:    convID.String(),
		Title: &title,
	})); err != nil {
		t.Fatalf("UpdateConversation: %v", err)
	}
	assertConvEvent(t, recvEvent(t, ch), user.ID, convID, events.ConversationChangeUpdated)

	if _, err := svc.ArchiveConversation(ctx, connect.NewRequest(&psmithv1.ArchiveConversationRequest{
		Id: convID.String(),
	})); err != nil {
		t.Fatalf("ArchiveConversation: %v", err)
	}
	assertConvEvent(t, recvEvent(t, ch), user.ID, convID, events.ConversationChangeUpdated)

	if _, err := svc.DeleteConversation(ctx, connect.NewRequest(&psmithv1.DeleteConversationRequest{
		Id: convID.String(),
	})); err != nil {
		t.Fatalf("DeleteConversation: %v", err)
	}
	assertConvEvent(t, recvEvent(t, ch), user.ID, convID, events.ConversationChangeDeleted)
}

func TestConversationEvents_NoBusIsSilentNoop(t *testing.T) {
	// The bus is optional — fixtures without WithBus must not panic.
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "nobus-user")
	profile := makeProfile(t, q, user.ID, nil, nil, nil)

	if _, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&psmithv1.CreateConversationRequest{
		ProfileId: profile.ID.String(),
	})); err != nil {
		t.Fatalf("CreateConversation without bus: %v", err)
	}
}

func TestConversationEvents_OnRunMaterializedPublishes(t *testing.T) {
	// The supervisor hook path: any terminal materialization publishes
	// an Updated event attributed via StartParams.UserID.
	bus := events.New(nil)
	svc := (&Service{}).WithBus(bus)

	userID := uuid.New()
	convID := uuid.New()
	ch, cancel := bus.Subscribe(userID)
	defer cancel()

	svc.OnRunMaterialized(stream.StartParams{
		ConversationID: convID,
		UserID:         userID,
	})
	assertConvEvent(t, recvEvent(t, ch), userID, convID, events.ConversationChangeUpdated)
}
