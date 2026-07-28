package plugins

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/google/uuid"
)

// ErrNoPluginState is returned by PluginStateStore.LoadNearest when no snapshot
// exists anywhere on the branch — the normal signal for "this campaign
// hasn't been initialized yet", not an error condition.
var ErrNoPluginState = errors.New("plugins: no game state on this branch")

// PluginStateStore is the runtime-injected persistence dependency for stateful
// plugins that key their state to a message rather than a conversation.
// Same context-injection pattern as Searcher and ProviderResolver: the
// conversations service attaches a user- and conversation-scoped
// instance right before ExecuteTool, and the plugin reads it via
// PluginStateStoreFrom(ctx).
//
// Deliberately narrow and expressed in domain terms — uuid.UUID and raw
// JSON, never store or pgx types — so plugin tests can stub it without
// standing up Postgres, and so the plugins package keeps its convention
// of not importing internal/store.
//
// Scoping is the implementation's job, not the caller's: the concrete
// instance is built per send with the owner's id baked in, and refuses
// to read or write rows belonging to anyone else. A plugin cannot widen
// its own scope by passing different ids.
type PluginStateStore interface {
	// LoadNearest walks the message parent chain upward from THIS turn's
	// leaf — baked into the store at construction, not passed by the
	// caller — and returns the first snapshot found along with the
	// message it was bound to. Returns ErrNoPluginState when the branch
	// carries none, which is the normal "new campaign" signal.
	//
	// The walk is what makes forks work: two branches off the same
	// parent each find their own lineage and neither can see the
	// other's. Regenerating a turn walks from the same user message and
	// so inherits the same parent state while writing to a new branch.
	// It also absorbs stitch deletes and interleaved non-game messages,
	// which a strict "parent's row" lookup would not.
	LoadNearest(ctx context.Context) (state json.RawMessage, version int64, foundAt uuid.UUID, err error)

	// Save binds a snapshot to a specific message. Idempotent, so a
	// retried bind overwrites rather than failing. Callers pass the
	// version they computed; the store does not interpret the blob.
	Save(ctx context.Context, messageID uuid.UUID, state json.RawMessage, version int64) error
}

type pluginStateStoreKey struct{}

// WithPluginStateStore attaches a PluginStateStore to ctx. Called by the dispatch site
// right before invoking the owning plugin's ExecuteTool. A nil store is
// a no-op — ctx comes back unchanged so PluginStateStoreFrom can report the
// unwired case and the plugin can surface a clean tool error.
func WithPluginStateStore(ctx context.Context, s PluginStateStore) context.Context {
	if s == nil {
		return ctx
	}
	return context.WithValue(ctx, pluginStateStoreKey{}, s)
}

// PluginStateStoreFrom returns the PluginStateStore attached to ctx, or nil when the
// runtime didn't wire one. Plugins must treat nil as "persistence is not
// available" and return a friendly tool error rather than panicking.
func PluginStateStoreFrom(ctx context.Context) PluginStateStore {
	v, _ := ctx.Value(pluginStateStoreKey{}).(PluginStateStore)
	return v
}
