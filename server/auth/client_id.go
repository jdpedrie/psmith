package auth

import "context"

// ClientID identifies one running client instance, not one user and not one
// login. Clients generate it per process and send it on every request as
// `psmith-client-id`.
//
// It exists so a client can recognise the events its own mutations produced.
// Every mutation fans out to every subscriber for the user, the originator
// included, and acting on that echo costs a round trip to learn something the
// client already knew.
//
// Deliberately not a session or device id: it must change when the process
// restarts, because a new process has none of the optimistic state that made
// suppressing the echo safe.
type ClientID string

type clientIDKey struct{}

// ContextWithClientID attaches the caller's client id.
func ContextWithClientID(ctx context.Context, id ClientID) context.Context {
	if id == "" {
		return ctx
	}
	return context.WithValue(ctx, clientIDKey{}, id)
}

// ClientIDFrom returns the caller's client id, or "" when the request carried
// no header. Absence is normal: older clients, curl, the web UI.
func ClientIDFrom(ctx context.Context) string {
	if v, ok := ctx.Value(clientIDKey{}).(ClientID); ok {
		return string(v)
	}
	return ""
}

// ClientIDHeader is the wire name. Lowercase because connect normalises
// header keys and a mismatched case reads as absent.
const ClientIDHeader = "psmith-client-id"
