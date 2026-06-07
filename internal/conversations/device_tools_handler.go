package conversations

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/devicetools"
)

// DeviceToolsHandler returns the http.Handler that receives a
// client's response for an in-flight device-tool call. Mounted by
// cmd/reeved at `POST /conversations/{id}/device-tools/{call_id}/respond`.
// Mirrors ElicitHandler's shape — same auth gate, same convo-
// ownership check, same write-once semantics on the broker side.
//
// Body shape (matches devicetools.Response):
//
//	{
//	  "output": <model-visible JSON>,
//	  "error":  "optional error message"
//	}
//
// Either `output` or `error` is non-empty. Errors are surfaced to
// the waiting server-side ExecuteTool as ordinary tool failures —
// the model sees the error text on the next round.
func (s *Service) DeviceToolsHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

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
		callID, err := uuid.Parse(r.PathValue("call_id"))
		if err != nil {
			http.Error(w, "invalid call id", http.StatusBadRequest)
			return
		}

		// Mirror ElicitHandler: cross-user "not found" rather than
		// leaking other users' conversation ids.
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
			http.Error(w, "conversation not found", http.StatusNotFound)
			return
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
			return
		}
		var resp devicetools.Response
		if err := json.Unmarshal(body, &resp); err != nil {
			http.Error(w, "decode body: "+err.Error(), http.StatusBadRequest)
			return
		}
		// Either output OR error must be present. A blank Response
		// would silently complete the call with empty output, which
		// is rarely what the client meant.
		if len(resp.Output) == 0 && resp.Error == "" {
			http.Error(w, "response must include either output or error",
				http.StatusBadRequest)
			return
		}

		if err := s.deviceToolBroker.Respond(convoID, callID, resp); err != nil {
			switch {
			case errors.Is(err, devicetools.ErrCallNotFound):
				http.Error(w, "device-tool call not found", http.StatusNotFound)
			case errors.Is(err, devicetools.ErrCallCrossConversation):
				http.Error(w, "device-tool call not found", http.StatusNotFound)
			default:
				http.Error(w, "respond: "+err.Error(), http.StatusInternalServerError)
			}
			return
		}

		w.WriteHeader(http.StatusNoContent)
	})
}
