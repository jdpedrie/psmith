package events

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// recordingStream stands in for connect's ServerStream. The real type is a
// struct, not an interface, so the handler is exercised through a tiny local
// sink shaped the same way.
type recordingStream struct {
	mu     sync.Mutex
	sent   []*psmithv1.AccountEvent
	failAt int // send number (1-based) that returns an error; 0 never fails
	n      int
	gotErr chan struct{}
	once   sync.Once
}

func newRecordingStream(failAt int) *recordingStream {
	return &recordingStream{failAt: failAt, gotErr: make(chan struct{})}
}

func (r *recordingStream) Send(e *psmithv1.AccountEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.n++
	if r.failAt != 0 && r.n == r.failAt {
		r.once.Do(func() { close(r.gotErr) })
		return errors.New("client gone")
	}
	r.sent = append(r.sent, e)
	return nil
}

func (r *recordingStream) snapshot() []*psmithv1.AccountEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*psmithv1.AccountEvent, len(r.sent))
	copy(out, r.sent)
	return out
}

func (r *recordingStream) countHeartbeats() int {
	n := 0
	for _, e := range r.snapshot() {
		if e.GetHeartbeat() != nil {
			n++
		}
	}
	return n
}

func withShortHeartbeat(t *testing.T, d time.Duration) {
	t.Helper()
	prev := HeartbeatInterval
	HeartbeatInterval = d
	t.Cleanup(func() { HeartbeatInterval = prev })
}

// A subscription with no activity at all must still put bytes on the wire.
// This is the whole point: silence is indistinguishable from a dead
// connection, and something between here and the client will reap it.
func TestHeartbeat_QuietSubscriptionStillSends(t *testing.T) {
	withShortHeartbeat(t, 10*time.Millisecond)

	bus := New(nil)
	out := newRecordingStream(0)
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan error, 1)
	go func() { done <- runSubscription(ctx, bus, uuid.New(), out) }()

	// Long enough for several intervals, short enough not to drag the suite.
	time.Sleep(120 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("loop returned: %v", err)
	}

	if got := out.countHeartbeats(); got < 3 {
		t.Errorf("expected repeated heartbeats on an idle stream, got %d", got)
	}
}

// A failed heartbeat send is the signal the feature exists to produce: it is
// how the server learns a client that published nothing has gone away.
func TestHeartbeat_SendFailureEndsTheSubscription(t *testing.T) {
	withShortHeartbeat(t, 10*time.Millisecond)

	bus := New(nil)
	out := newRecordingStream(1) // first send fails
	done := make(chan error, 1)
	go func() { done <- runSubscription(context.Background(), bus, uuid.New(), out) }()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("a failed heartbeat send must end the subscription")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("loop did not return after the send failed")
	}
}

// Heartbeats must not crowd out or reorder real events.
func TestHeartbeat_DoesNotDisplaceRealEvents(t *testing.T) {
	withShortHeartbeat(t, 5*time.Millisecond)

	bus := New(nil)
	userID := uuid.New()
	out := newRecordingStream(0)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runSubscription(ctx, bus, userID, out) }()

	// Wait until the loop has actually subscribed. Publishing straight after
	// starting the goroutine raced bus.Subscribe and silently lost the first
	// event, because a publish with no subscriber goes nowhere. The first
	// heartbeat is proof the loop is running.
	waitForHeartbeat(t, out)

	profileID := uuid.New()
	for range 5 {
		bus.Publish(Event{
			Type:    ProfileChanged,
			UserID:  userID,
			Profile: ProfilePayload{ProfileID: profileID, Kind: ProfileChangeCreated},
		})
		time.Sleep(8 * time.Millisecond)
	}

	// Wait for delivery rather than sleeping a fixed span and asserting.
	// Cancelling while an event is still buffered drops it, because the loop
	// takes ctx.Done() over a pending read — correct on disconnect, but it
	// made this test depend on scheduling.
	real := 0
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		real = 0
		for _, e := range out.snapshot() {
			if e.GetProfileChanged() != nil {
				real++
			}
		}
		if real == 5 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done

	if real != 5 {
		t.Errorf("expected all 5 real events delivered alongside heartbeats, got %d", real)
	}
	if out.countHeartbeats() == 0 {
		t.Error("expected heartbeats interleaved with real events")
	}
}

// The interval is a contract with the client, which derives its liveness
// deadline from it. A change here without a matching change there reopens
// the failure this closes, so pin it.
func TestHeartbeat_IntervalIsTheDocumentedValue(t *testing.T) {
	prev := HeartbeatInterval
	t.Cleanup(func() { HeartbeatInterval = prev })
	// Read the package default rather than whatever a parallel test left.
	if prev != 20*time.Second {
		t.Errorf("HeartbeatInterval is %v; clients size their idle deadline off 20s "+
			"(RPCTimeouts.serverStreamIdleTimeout). Change both or neither.", prev)
	}
}

// The handler delegates to runSubscription, so the loop the tests above drive
// is the one production runs. What that delegation needs is for connect's
// ServerStream to satisfy eventSink; if its Send signature ever changes this
// stops compiling, which is the earliest possible warning.
var _ eventSink = (*connect.ServerStream[psmithv1.AccountEvent])(nil)

// waitForHeartbeat blocks until at least one heartbeat has been recorded.
func waitForHeartbeat(t *testing.T, out *recordingStream) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if out.countHeartbeats() > 0 {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("no heartbeat arrived; the subscription never started")
}
