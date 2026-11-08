package web

import "net/http"

// mountConversation registers the routes for the conversation: transcript, sending, streaming, message actions.
func (h *Handler) mountConversation(mux *http.ServeMux) {
	mux.HandleFunc("GET /c/{id}", h.requireUser(h.handleConversation))
	mux.HandleFunc("GET /c/{id}/partials/messages", h.requireUser(h.handleMessagesPartial))
	mux.HandleFunc("GET /c/{id}/head", h.requireUser(h.handleHead))
	mux.HandleFunc("POST /c/{id}/rename", h.requireUser(h.handleRename))
	mux.HandleFunc("POST /c/{id}/title/generate", h.requireUser(h.handleGenerateTitle))
	mux.HandleFunc("POST /c/{id}/send", h.requireUser(h.handleSend))
	mux.HandleFunc("POST /c/{id}/upload", h.requireUser(h.handleUpload))
	mux.HandleFunc("GET /c/{id}/stream", h.requireUser(h.handleStream))
	mux.HandleFunc("POST /c/{id}/stop", h.requireUser(h.handleStop))
	mux.HandleFunc("POST /c/{id}/branch", h.requireUser(h.handleBranch))
	mux.HandleFunc("POST /c/{id}/continue", h.requireUser(h.handleContinue))
	mux.HandleFunc("POST /c/{id}/choice", h.requireUser(h.handleChoice))
	mux.HandleFunc("POST /c/{id}/regenerate", h.requireUser(h.handleRegenerate))
	mux.HandleFunc("GET /c/{id}/file/{fid}", h.requireUser(h.handleFilePage))
	mux.HandleFunc("GET /c/{id}/message/{mid}", h.requireUser(h.handleMessageRow))
	mux.HandleFunc("GET /c/{id}/message/{mid}/edit", h.requireUser(h.handleRowStatePage("edit")))
	mux.HandleFunc("POST /c/{id}/message/{mid}/edit", h.requireUser(h.handleEditSave))
	mux.HandleFunc("GET /c/{id}/message/{mid}/delete", h.requireUser(h.handleRowStatePage("delete")))
	mux.HandleFunc("POST /c/{id}/message/{mid}/delete", h.requireUser(h.handleMessageDelete))
}
