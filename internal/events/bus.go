// Package events implements an in-memory, per-user pub/sub bus for
// account-scoped server push (profile mutations today; conversation
// + provider mutations are likely follow-ups).
//
// Design notes:
//   - In-memory only. Events are lost on server restart. Clients are
//     expected to re-fetch state on every entry path; a missed push
//     just means "next user action sees the change."
//   - One channel per active subscriber. Per-user fanout: every active
//     subscriber for a user receives every event for that user.
//   - Channels are buffered (16 events). A subscriber that doesn't
//     drain in time loses events (best-effort delivery; same recovery
//     story as restart). The drop is logged once per overflow.
//   - Sync.RWMutex protects the subscriber map. Publishes use a read
//     lock for fanout — no contention during writes.
package events

import (
	"sync"

	"github.com/google/uuid"
)

// Event is the typed payload pushed to subscribers. EventType +
// payload form a tiny tagged union — the wire-format conversion to
// the proto oneof happens at the streaming-RPC boundary.
type Event struct {
	Type   EventType
	UserID uuid.UUID
	// Profile carries data for ProfileChanged events. Zero-valued
	// for other types.
	Profile ProfilePayload
}

// EventType discriminates the union. New types append.
type EventType int

const (
	// ProfileChanged fires when a profile owned by UserID was created,
	// updated, or deleted via any server-side path.
	ProfileChanged EventType = iota + 1
)

// ProfileChangeKind mirrors the proto enum so callers don't need to
// import the gen package just to publish.
type ProfileChangeKind int

const (
	ProfileChangeUnspecified ProfileChangeKind = iota
	ProfileChangeCreated
	ProfileChangeUpdated
	ProfileChangeDeleted
)

type ProfilePayload struct {
	ProfileID uuid.UUID
	Kind      ProfileChangeKind
}

// Logger is the minimal interface the bus needs for overflow warnings.
// Matches *slog.Logger but avoids importing slog so this package stays
// dep-free.
type Logger interface {
	Warn(msg string, args ...any)
}

// Bus is the per-process in-memory event bus.
type Bus struct {
	mu          sync.RWMutex
	subscribers map[uuid.UUID][]chan Event
	logger      Logger
}

// New constructs a Bus. logger may be nil — overflow warnings are
// silent in that case.
func New(logger Logger) *Bus {
	return &Bus{
		subscribers: make(map[uuid.UUID][]chan Event),
		logger:      logger,
	}
}

// subscriberBufferSize is the per-subscriber channel buffer. Sized to
// absorb a small burst of mutations (e.g., reordering plugins in a
// profile fires several updates in quick succession) without dropping;
// a sustained flood is dropped with logging so the publisher isn't
// blocked by a slow client.
const subscriberBufferSize = 16

// Subscribe opens a channel for the given user. The returned cancel
// func detaches the subscriber and closes the channel — call it from
// a deferred close in the handler so disconnects don't leak.
//
// Multiple subscribers per user are supported (e.g., the same user on
// iOS + Mac simultaneously); every Publish fans out to all of them.
func (b *Bus) Subscribe(userID uuid.UUID) (<-chan Event, func()) {
	ch := make(chan Event, subscriberBufferSize)
	b.mu.Lock()
	b.subscribers[userID] = append(b.subscribers[userID], ch)
	b.mu.Unlock()

	cancel := func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		subs := b.subscribers[userID]
		for i, c := range subs {
			if c == ch {
				b.subscribers[userID] = append(subs[:i], subs[i+1:]...)
				if len(b.subscribers[userID]) == 0 {
					delete(b.subscribers, userID)
				}
				close(ch)
				return
			}
		}
	}
	return ch, cancel
}

// Publish fans the event out to every subscriber for e.UserID.
// Non-blocking on a per-subscriber basis — a full buffer means that
// subscriber drops this event and the publisher continues.
//
// No-op when there are no subscribers (rare in practice — most
// running users have at least one active client).
func (b *Bus) Publish(e Event) {
	b.mu.RLock()
	subs := b.subscribers[e.UserID]
	// Snapshot the slice so we don't hold the lock during fanout.
	// Channel sends below could block briefly; lock-during-send would
	// starve concurrent Subscribe/cancel calls.
	snapshot := make([]chan Event, len(subs))
	copy(snapshot, subs)
	b.mu.RUnlock()

	for _, ch := range snapshot {
		select {
		case ch <- e:
		default:
			if b.logger != nil {
				b.logger.Warn(
					"events: subscriber buffer full, dropping event",
					"user_id", e.UserID,
					"event_type", e.Type,
				)
			}
		}
	}
}

// SubscriberCount returns the number of active subscriptions for
// userID. Used in tests; not load-bearing.
func (b *Bus) SubscriberCount(userID uuid.UUID) int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.subscribers[userID])
}
