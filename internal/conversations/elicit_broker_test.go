package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/internal/elicit"
)

func TestElicitBroker_RoundTrip(t *testing.T) {
	t.Parallel()
	b := newElicitBroker()
	convoID := uuid.New()

	emitted := make(chan uuid.UUID, 1)
	c := newElicitClient(b, convoID, func(id uuid.UUID, _ elicit.Request) {
		emitted <- id
	})

	done := make(chan elicit.Response, 1)
	go func() {
		resp, err := c.Elicit(context.Background(), elicit.Request{
			Message:         "test",
			RequestedSchema: json.RawMessage(`{"type":"object"}`),
		})
		if err != nil {
			t.Errorf("Elicit: %v", err)
			return
		}
		done <- resp
	}()

	id := <-emitted
	if err := b.Respond(convoID, id, elicit.Response{
		Action:  elicit.ActionAccept,
		Content: json.RawMessage(`{"api_key":"sk-x"}`),
	}); err != nil {
		t.Fatalf("Respond: %v", err)
	}

	select {
	case got := <-done:
		if got.Action != elicit.ActionAccept {
			t.Errorf("action: %q", got.Action)
		}
		if string(got.Content) != `{"api_key":"sk-x"}` {
			t.Errorf("content: %s", string(got.Content))
		}
	case <-time.After(time.Second):
		t.Fatal("Elicit didn't return")
	}
}

func TestElicitBroker_RespondTwiceSecondNotFound(t *testing.T) {
	t.Parallel()
	b := newElicitBroker()
	convoID := uuid.New()

	emitted := make(chan uuid.UUID, 1)
	c := newElicitClient(b, convoID, func(id uuid.UUID, _ elicit.Request) {
		emitted <- id
	})
	done := make(chan struct{})
	go func() {
		_, _ = c.Elicit(context.Background(), elicit.Request{Message: "x"})
		close(done)
	}()

	id := <-emitted
	if err := b.Respond(convoID, id, elicit.Response{Action: elicit.ActionAccept}); err != nil {
		t.Fatalf("first Respond: %v", err)
	}
	<-done

	if err := b.Respond(convoID, id, elicit.Response{Action: elicit.ActionAccept}); !errors.Is(err, ErrElicitationNotFound) {
		t.Errorf("expected ErrElicitationNotFound on second Respond; got %v", err)
	}
}

func TestElicitBroker_CrossConversationRejected(t *testing.T) {
	t.Parallel()
	b := newElicitBroker()
	convoID := uuid.New()
	wrongConvo := uuid.New()

	emitted := make(chan uuid.UUID, 1)
	c := newElicitClient(b, convoID, func(id uuid.UUID, _ elicit.Request) {
		emitted <- id
	})
	done := make(chan struct{})
	go func() {
		// Use a short ctx so the goroutine exits even if Respond is rejected.
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_, _ = c.Elicit(ctx, elicit.Request{Message: "x"})
		close(done)
	}()

	id := <-emitted
	if err := b.Respond(wrongConvo, id, elicit.Response{Action: elicit.ActionAccept}); !errors.Is(err, ErrElicitationCrossConversation) {
		t.Errorf("expected ErrElicitationCrossConversation; got %v", err)
	}
	// Correct convo still works.
	if err := b.Respond(convoID, id, elicit.Response{Action: elicit.ActionDecline}); err != nil {
		t.Errorf("second Respond from correct convo: %v", err)
	}
	<-done
}

func TestElicitBroker_ContextCancelUnblocks(t *testing.T) {
	t.Parallel()
	b := newElicitBroker()
	convoID := uuid.New()
	c := newElicitClient(b, convoID, func(_ uuid.UUID, _ elicit.Request) {})

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	_, err := c.Elicit(ctx, elicit.Request{Message: "x"})
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("expected error when ctx canceled")
	}
	if elapsed > time.Second {
		t.Errorf("Elicit took too long to unblock on cancel: %v", elapsed)
	}
}
