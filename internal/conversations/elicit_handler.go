package conversations

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/elicit"
)

// ElicitHandler returns the http.Handler that receives user responses
// for in-flight elicitation requests. Mounted by cmd/reeved at
// `POST /conversations/{id}/elicitations/{eid}/respond`. The handler:
//
//   - authenticates the caller via the same Bearer-token sessions
//     the Connect RPCs use,
//   - confirms the caller owns the conversation,
//   - parses the elicitation Response payload from the request body,
//   - delivers it to the broker, which wakes the waiting tool call.
//
// Responses are write-once: a second POST for the same elicitation_id
// gets 404 ("not found" — the slot has been drained). The waiting
// tool's timeout (5 minutes) is the upper bound for how long a slot
// stays alive.
func (s *Service) ElicitHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Auth gate — same shape as mcpserver.Handler.
		user, err := auth.AuthenticateBearer(r.Context(), s.queries, r.Header.Get("Authorization"))
		if err != nil {
			if errors.Is(err, auth.ErrUnauthenticated) {
				http.Error(w, err.Error(), http.StatusUnauthorized)
			} else {
				http.Error(w, "auth: "+err.Error(), http.StatusInternalServerError)
			}
			return
		}

		convoID, err := uuid.Parse(r.PathValue("id"))
		if err != nil {
			http.Error(w, "invalid conversation id", http.StatusBadRequest)
			return
		}
		elicitID, err := uuid.Parse(r.PathValue("eid"))
		if err != nil {
			http.Error(w, "invalid elicitation id", http.StatusBadRequest)
			return
		}

		// Confirm the caller owns the conversation. This is cheap (one
		// row lookup) and prevents one authed user from completing an
		// elicitation pending on another user's conversation.
		convo, err := s.queries.GetConversationByID(r.Context(), convoID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				http.Error(w, "conversation not found", http.StatusNotFound)
			} else {
				http.Error(w, "lookup: "+err.Error(), http.StatusInternalServerError)
			}
			return
		}
		if convo.UserID != user.ID {
			// Mirror the cross-user "not found" treatment the
			// Connect handlers use — don't leak the existence of
			// other users' conversations.
			http.Error(w, "conversation not found", http.StatusNotFound)
			return
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
			return
		}
		var resp elicit.Response
		if err := json.Unmarshal(body, &resp); err != nil {
			http.Error(w, "decode body: "+err.Error(), http.StatusBadRequest)
			return
		}
		if resp.Action == "" {
			http.Error(w, "action is required (accept | decline | cancel)", http.StatusBadRequest)
			return
		}

		if err := s.elicit.Respond(convoID, elicitID, resp); err != nil {
			switch {
			case errors.Is(err, ErrElicitationNotFound):
				http.Error(w, "elicitation not found", http.StatusNotFound)
			case errors.Is(err, ErrElicitationCrossConversation):
				// Should be unreachable given the convo-ownership
				// check above, but defense-in-depth.
				http.Error(w, "elicitation not found", http.StatusNotFound)
			default:
				http.Error(w, "respond: "+err.Error(), http.StatusInternalServerError)
			}
			return
		}

		w.WriteHeader(http.StatusNoContent)
	})
}
