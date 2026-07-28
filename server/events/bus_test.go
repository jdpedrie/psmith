package events

import (
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestBus_PublishFansOutToAllSubscribersForUser(t *testing.T) {
	bus := New(nil)
	user := uuid.New()

	chA, cancelA := bus.Subscribe(user)
	defer cancelA()
	chB, cancelB := bus.Subscribe(user)
	defer cancelB()

	if got := bus.SubscriberCount(user); got != 2 {
		t.Fatalf("subscriber count = %d want 2", got)
	}

	pid := uuid.New()
	bus.Publish(Event{
		Type:    ProfileChanged,
		UserID:  user,
		Profile: ProfilePayload{ProfileID: pid, Kind: ProfileChangeUpdated},
	})

	for _, ch := range []<-chan Event{chA, chB} {
		select {
		case ev := <-ch:
			if ev.Profile.ProfileID != pid {
				t.Errorf("got profile_id %v want %v", ev.Profile.ProfileID, pid)
			}
			if ev.Profile.Kind != ProfileChangeUpdated {
				t.Errorf("got kind %v want %v", ev.Profile.Kind, ProfileChangeUpdated)
			}
		case <-time.After(50 * time.Millisecond):
			t.Errorf("subscriber didn't receive event")
		}
	}
}

func TestBus_PublishIgnoresOtherUsers(t *testing.T) {
	bus := New(nil)
	aliceID, bobID := uuid.New(), uuid.New()

	aliceCh, cancel := bus.Subscribe(aliceID)
	defer cancel()

	bus.Publish(Event{Type: ProfileChanged, UserID: bobID})

	select {
	case ev := <-aliceCh:
		t.Errorf("alice should not have received bob's event: %+v", ev)
	case <-time.After(20 * time.Millisecond):
		// ok
	}
}

func TestBus_CancelRemovesSubscriberAndClosesChannel(t *testing.T) {
	bus := New(nil)
	user := uuid.New()

	ch, cancel := bus.Subscribe(user)
	if bus.SubscriberCount(user) != 1 {
		t.Fatalf("expected 1 subscriber pre-cancel")
	}
	cancel()
	if bus.SubscriberCount(user) != 0 {
		t.Errorf("expected 0 subscribers post-cancel; got %d", bus.SubscriberCount(user))
	}
	// Channel must be closed (recv returns zero value + !ok).
	if _, ok := <-ch; ok {
		t.Errorf("channel should be closed after cancel")
	}
}

// Slow subscriber blocks fanout? Pin the contract: full buffer drops
// events without blocking the publisher or other subscribers.
func TestBus_FullBufferDropsRatherThanBlocks(t *testing.T) {
	logger := &captureLogger{}
	bus := New(logger)
	user := uuid.New()

	_, cancel := bus.Subscribe(user)
	defer cancel()

	// Fill the buffer + one overflow without anyone draining.
	for i := 0; i < subscriberBufferSize+1; i++ {
		bus.Publish(Event{Type: ProfileChanged, UserID: user})
	}

	if logger.warnCount == 0 {
		t.Errorf("expected at least one overflow warning, got none")
	}
}

type captureLogger struct {
	mu        sync.Mutex
	warnCount int
}

func (c *captureLogger) Warn(_ string, _ ...any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.warnCount++
}
