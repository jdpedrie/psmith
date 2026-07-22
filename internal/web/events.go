package web

import (
	"net/http"
	"time"

	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/events"
)

// handleEvents bridges the in-process account-events bus onto SSE for
// htmx's SSE extension. Event names double as htmx triggers:
//
//   - "conversation-changed" (data: conversation id) — the sidebar
//     refreshes its list on any of these.
//   - "conversation-changed-<id>" — the open conversation's messages
//     region listens for exactly its own id, so a busy account doesn't
//     re-fetch the transcript for every unrelated mutation.
//   - "provider-changed" / "profile-changed" — no page consumes these
//     yet; emitted so future settings surfaces can subscribe without a
//     server change.
//
// Same no-replay contract as the RPC subscription: events are hints to
// refresh, and a missed one is recovered by the next full page load.
func (h *Handler) handleEvents(w http.ResponseWriter, r *http.Request) {
	if h.bus == nil {
		http.NotFound(w, r)
		return
	}
	u := auth.MustFromContext(r.Context())
	sse, ok := newSSE(w)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	ch, cancel := h.bus.Subscribe(u.ID)
	defer cancel()

	// Keep-alive comments defeat idle timeouts in proxies and the
	// browser's connection reaper during quiet stretches.
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ping.C:
			sse.comment("ping")
		case ev, open := <-ch:
			if !open {
				return
			}
			switch ev.Type {
			case events.ConversationChanged:
				id := ev.Conversation.ConversationID.String()
				sse.event("conversation-changed", id)
				sse.event("conversation-changed-"+id, id)
			case events.ProviderChanged:
				sse.event("provider-changed", ev.Provider.ProviderID.String())
			case events.ProfileChanged:
				sse.event("profile-changed", ev.Profile.ProfileID.String())
			}
		}
	}
}
