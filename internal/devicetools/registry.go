package devicetools

import (
	"sync"
	"time"

	"github.com/google/uuid"
)

// Registry tracks which device-tools the connected client(s)
// for each (user, conversation) currently advertise. Populated by
// the RegisterCapabilities RPC on every StreamSubscriber connect;
// queried by the `app_tools` plugin's Tools() filter so the model
// never sees a tool the connected device can't fulfill.
//
// In-memory and per-process: a server restart drops everything
// (matches the existing elicit broker's semantics). Clients
// re-register on reconnect.
type Registry struct {
	mu      sync.RWMutex
	entries map[registryKey]registryEntry
}

type registryKey struct {
	userID         uuid.UUID
	conversationID uuid.UUID
}

type registryEntry struct {
	supported    map[string]struct{}
	attributes   map[string]string
	registeredAt time.Time
}

// NewRegistry constructs an empty registry.
func NewRegistry() *Registry {
	return &Registry{entries: map[registryKey]registryEntry{}}
}

// Register replaces the supported-set for (user, conversation). The
// last writer wins — when iOS + Mac both publish, the most
// recently-connected client's set is the active one. Multi-client
// routing knobs can land later if anyone cares.
func (r *Registry) Register(
	userID, conversationID uuid.UUID,
	supportedNames []string,
	attributes map[string]string,
) {
	supported := make(map[string]struct{}, len(supportedNames))
	for _, n := range supportedNames {
		supported[n] = struct{}{}
	}
	// Copy attributes so callers can't mutate behind our back.
	attrs := make(map[string]string, len(attributes))
	for k, v := range attributes {
		if v != "" {
			attrs[k] = v
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entries[registryKey{userID: userID, conversationID: conversationID}] = registryEntry{
		supported:    supported,
		attributes:   attrs,
		registeredAt: time.Now(),
	}
}

// Supports reports whether the client for this (user, conversation)
// has advertised `toolName`. Returns false when no client has
// registered yet — the safe default ("no device tools available")
// so the model doesn't get tool defs that would just fail.
func (r *Registry) Supports(userID, conversationID uuid.UUID, toolName string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[registryKey{userID: userID, conversationID: conversationID}]
	if !ok {
		return false
	}
	_, has := e.supported[toolName]
	return has
}

// SupportedSet returns a copy of the supported names for (user,
// conversation). Empty when no client has registered. Callers use
// this for "filter the plugin's Tools() to this intersection."
func (r *Registry) SupportedSet(userID, conversationID uuid.UUID) map[string]struct{} {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[registryKey{userID: userID, conversationID: conversationID}]
	if !ok {
		return nil
	}
	out := make(map[string]struct{}, len(e.supported))
	for k := range e.supported {
		out[k] = struct{}{}
	}
	return out
}

// Attributes returns the client's free-form attribute map
// (os, os_version, app_version, …) — empty when none registered.
// Used by the server-side catalog for "tool requires iOS 26+"
// gates.
func (r *Registry) Attributes(userID, conversationID uuid.UUID) map[string]string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[registryKey{userID: userID, conversationID: conversationID}]
	if !ok {
		return nil
	}
	out := make(map[string]string, len(e.attributes))
	for k, v := range e.attributes {
		out[k] = v
	}
	return out
}

// Clear drops the entry for (user, conversation) — call on
// disconnect to free memory, though leaking is harmless since
// re-register overwrites and the table is small.
func (r *Registry) Clear(userID, conversationID uuid.UUID) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.entries, registryKey{userID: userID, conversationID: conversationID})
}
