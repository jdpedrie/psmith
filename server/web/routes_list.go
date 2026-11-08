package web

import "net/http"

// mountList registers the routes for the list column, new conversations,
// row actions, search and commands, shortcuts, and first-run setup.
func (h *Handler) mountList(mux *http.ServeMux) {
	mux.HandleFunc("GET /chats", h.requireUser(h.handleChats))
	mux.HandleFunc("POST /chats/bulk", h.requireUser(h.handleBulk))
	mux.HandleFunc("GET /new", h.requireUser(h.handleNewForm))
	mux.HandleFunc("POST /new", h.requireUser(h.handleNewCreate))
	mux.HandleFunc("POST /c/{id}/pin", h.requireUser(h.handlePinToggle))
	mux.HandleFunc("POST /c/{id}/archive", h.requireUser(h.handleArchive))
	mux.HandleFunc("POST /c/{id}/unarchive", h.requireUser(h.handleUnarchive))
	mux.HandleFunc("POST /c/{id}/delete", h.requireUser(h.handleConversationDelete))
	mux.HandleFunc("POST /chats/{id}/rename", h.requireUser(h.handleListRename))
	mux.HandleFunc("POST /chats/{id}/title", h.requireUser(h.handleListGenerateTitle))
	mux.HandleFunc("GET /archived", h.requireUser(h.handleArchivedList))
	mux.HandleFunc("GET /shortcuts", h.requireUser(h.handleShortcuts))
	mux.HandleFunc("GET /partials/list", h.requireUser(h.handleListPartial))
	mux.HandleFunc("GET /partials/list/rows", h.requireUser(h.handleListRowsPartial))
	mux.HandleFunc("GET /partials/list/row/{id}", h.requireUser(h.handleRowPartial))
	mux.HandleFunc("GET /partials/command", h.requireUser(h.handleCommand))
	mux.HandleFunc("GET /setup", h.requireUser(h.handleSetup))
	mux.HandleFunc("GET /setup/key", h.requireUser(h.handleSetupKeyForm))
	mux.HandleFunc("POST /setup/key", h.requireUser(h.handleSetupKey))
	mux.HandleFunc("GET /setup/models", h.requireUser(h.handleSetupModelsForm))
	mux.HandleFunc("POST /setup/models", h.requireUser(h.handleSetupModels))
}
