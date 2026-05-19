package events

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
)

// Service implements reeve.v1.EventsService. Each subscription opens
// a per-user channel on the bus and translates internal Event values
// into wire-shaped AccountEvent messages.
type Service struct {
	bus *Bus
}

// NewService wires the handler against the shared bus. The same bus
// must be the one ProfileService publishes into; otherwise events
// won't reach subscribers.
func NewService(bus *Bus) *Service {
	if bus == nil {
		// Defensive: a nil bus would silently swallow every publish
		// and starve every subscriber. Fail fast at composition time.
		panic("events.NewService: bus must not be nil")
	}
	return &Service{bus: bus}
}

// SubscribeAccountEvents opens a server-streaming subscription for
// the calling user. Runs until the client closes the stream or the
// connection drops. Each event read from the bus is translated to
// proto and written to the stream; loss-of-translation (unknown
// event type) is silently skipped so a server-side enum that the
// proto doesn't model yet doesn't crash the connection.
func (s *Service) SubscribeAccountEvents(
	ctx context.Context,
	req *connect.Request[reevev1.SubscribeAccountEventsRequest],
	stream *connect.ServerStream[reevev1.AccountEvent],
) error {
	caller, ok := auth.FromContext(ctx)
	if !ok {
		return connect.NewError(connect.CodeUnauthenticated, errors.New("auth required"))
	}

	ch, cancel := s.bus.Subscribe(caller.ID)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return nil
		case ev, ok := <-ch:
			if !ok {
				// Bus closed our channel (subscriber was cancelled
				// out from under us). Close the stream cleanly.
				return nil
			}
			proto := eventToProto(ev)
			if proto == nil {
				continue
			}
			if err := stream.Send(proto); err != nil {
				// Client disconnected mid-send. Propagate; the
				// deferred cancel() detaches from the bus.
				return err
			}
		}
	}
}

// eventToProto translates an internal Event into the wire shape.
// Returns nil for event types the proto doesn't model — caller skips
// those, so a forward-compatible server can publish new types without
// breaking old clients.
func eventToProto(ev Event) *reevev1.AccountEvent {
	switch ev.Type {
	case ProfileChanged:
		return &reevev1.AccountEvent{
			Kind: &reevev1.AccountEvent_ProfileChanged{
				ProfileChanged: &reevev1.ProfileChanged{
					ProfileId: ev.Profile.ProfileID.String(),
					Kind:      profileChangeKindToProto(ev.Profile.Kind),
				},
			},
		}
	default:
		return nil
	}
}

func profileChangeKindToProto(k ProfileChangeKind) reevev1.ProfileChangeKind {
	switch k {
	case ProfileChangeCreated:
		return reevev1.ProfileChangeKind_PROFILE_CHANGE_KIND_CREATED
	case ProfileChangeUpdated:
		return reevev1.ProfileChangeKind_PROFILE_CHANGE_KIND_UPDATED
	case ProfileChangeDeleted:
		return reevev1.ProfileChangeKind_PROFILE_CHANGE_KIND_DELETED
	default:
		return reevev1.ProfileChangeKind_PROFILE_CHANGE_KIND_UNSPECIFIED
	}
}
