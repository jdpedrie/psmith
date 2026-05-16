package mcpserver

import (
	"errors"
	"io"
	"net/http"

	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/store"
)

// Handler returns the http.Handler that serves the MCP JSON-RPC
// endpoint at whatever path the caller mounts it under (recommended:
// `/mcp`). The handler enforces Bearer-token auth using the same
// session table the Connect interceptor reads, then dispatches the
// request body to Server.HandleRPC.
//
// Transport mode: Streamable HTTP, JSON-only response. We don't emit
// SSE responses — every tool here completes synchronously, no
// long-lived streams. Clients that prefer SSE still negotiate via
// `Accept: text/event-stream`; we ignore the preference and return
// `application/json` regardless. Reeve's own mcp client handles both
// shapes (see plugins/mcp.go::readRPCResponse).
//
// Notifications (no `id`) get 202 Accepted with an empty body, per
// the MCP HTTP transport spec.
func Handler(server *Server, queries *store.Queries) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		user, err := auth.AuthenticateBearer(r.Context(), queries, r.Header.Get("Authorization"))
		if err != nil {
			if errors.Is(err, auth.ErrUnauthenticated) {
				http.Error(w, err.Error(), http.StatusUnauthorized)
			} else {
				http.Error(w, "auth: "+err.Error(), http.StatusInternalServerError)
			}
			return
		}
		ctx := auth.ContextWithUser(r.Context(), user)

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
			return
		}

		respBody, err := server.HandleRPC(ctx, body)
		if err != nil {
			// HandleRPC returns errors only for unrecoverable internal
			// failures — everything user-driven (bad JSON, unknown
			// tool) becomes an in-band JSON-RPC error response with
			// nil error. So this path should be rare.
			http.Error(w, "internal: "+err.Error(), http.StatusInternalServerError)
			return
		}

		// Notification → 202 Accepted, no body. Per MCP HTTP transport spec.
		if respBody == nil {
			w.WriteHeader(http.StatusAccepted)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(respBody)
	})
}
