package host

import (
	"context"
	"errors"
)

// ErrNoCompleter is returned by Completer implementations that cannot reach a
// model, so a plugin can tell "the answer was no" from "nobody was listening".
var ErrNoCompleter = errors.New("plugins: no completer available")

// Completer runs one short, synchronous model call and returns the text.
//
// The counterpart to ProviderResolver: that hands a plugin credentials and
// leaves it to speak three upstream APIs itself, which is right for something
// like image generation that needs a specific endpoint, and wrong for "ask a
// cheap model a question and read the answer". Reimplementing driver dispatch
// inside a plugin to get one sentence back is how three copies of the same
// bug get written.
//
// Deliberately not streaming and deliberately not part of a turn. Nothing here
// touches the stream supervisor, materializes a message, or appears in a
// transcript. It is for decisions a plugin needs to make before or around a
// turn: which persona speaks next, whether a summary is needed, how to
// classify something.
//
// Callers must treat failure as normal. The model is remote, the call is
// synchronous, and a plugin blocking a user's turn on it is a bad trade — the
// contract is that every implementation returns promptly and every caller has
// a non-model fallback.
type Completer interface {
	// Complete sends system + user and returns the assembled text.
	//
	// providerID/modelID identify the model the plugin chose (typically from a
	// MODEL_PICKER config field). Empty strings mean "the plugin did not
	// configure one", which implementations report as ErrNoCompleter rather
	// than silently picking something the user did not choose and did not
	// expect to pay for.
	Complete(ctx context.Context, providerID, modelID, system, user string, maxTokens int) (string, error)
}

type completerKey struct{}

// WithCompleter attaches a Completer to ctx. A nil completer is a no-op, so
// the plugin sees the same "not wired" case it would in a test harness.
func WithCompleter(ctx context.Context, c Completer) context.Context {
	if c == nil {
		return ctx
	}
	return context.WithValue(ctx, completerKey{}, c)
}

// CompleterFrom returns the Completer attached to ctx, or nil when the runtime
// did not wire one. Plugins must treat nil as "no model available" and fall
// back rather than failing.
func CompleterFrom(ctx context.Context) Completer {
	v, _ := ctx.Value(completerKey{}).(Completer)
	return v
}
