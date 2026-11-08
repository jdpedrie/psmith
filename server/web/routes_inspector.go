package web

import "net/http"

// mountInspector registers the routes for the inspector and the composer slot: settings, plugins, model, contexts, compression, elicitation.
func (h *Handler) mountInspector(mux *http.ServeMux) {
	mux.HandleFunc("POST /c/{id}/elicit/{eid}", h.requireUser(h.handleElicitRespond))

	mux.HandleFunc("GET /c/{id}/model", h.requireUser(h.handleModelPicker))
	mux.HandleFunc("POST /c/{id}/model", h.requireUser(h.handleSetModel))

	mux.HandleFunc("GET /c/{id}/settings", h.requireUser(h.handleConvSettings))
	mux.HandleFunc("POST /c/{id}/settings", h.requireUser(h.handleConvSettingsSave))
	mux.HandleFunc("POST /c/{id}/plugins", h.requireUser(h.handleConvPluginsSave))
	mux.HandleFunc("POST /c/{id}/plugins/override", h.requireUser(h.handleConvPluginOverride))
	mux.HandleFunc("GET /c/{id}/plugin/{name}", h.requireUser(h.handlePluginConfig))
	mux.HandleFunc("POST /c/{id}/plugin/{name}", h.requireUser(h.handlePluginConfigSave))
	mux.HandleFunc("GET /c/{id}/panel/{name}", h.requireUser(h.handlePluginPanel))
	mux.HandleFunc("POST /c/{id}/panel/{name}", h.requireUser(h.handlePluginAction))

	mux.HandleFunc("GET /c/{id}/contexts", h.requireUser(h.handleContexts))
	mux.HandleFunc("GET /c/{id}/context/{cid}", h.requireUser(h.handleContextView))
	mux.HandleFunc("POST /c/{id}/context/{cid}/activate", h.requireUser(h.handleContextActivate))
	mux.HandleFunc("POST /c/{id}/context/{cid}/rename", h.requireUser(h.handleContextRename))
	mux.HandleFunc("POST /c/{id}/context/{cid}/delete", h.requireUser(h.handleContextDelete))

	mux.HandleFunc("GET /c/{id}/compact", h.requireUser(h.handleCompactPage))
	mux.HandleFunc("POST /c/{id}/compact", h.requireUser(h.handleCompactRun))
	mux.HandleFunc("GET /c/{id}/compact/stream", h.requireUser(h.handleCompactStream))
	mux.HandleFunc("POST /c/{id}/compact/stop", h.requireUser(h.handleCompactStop))
	mux.HandleFunc("POST /c/{id}/promote", h.requireUser(h.handleCompactPromote))
	mux.HandleFunc("POST /c/{id}/summary", h.requireUser(h.handleSummarySave))
	mux.HandleFunc("POST /c/{id}/summary/discard", h.requireUser(h.handleSummaryDiscard))

	mux.HandleFunc("POST /c/{id}/title", h.requireUser(h.handleTitleSave))
	mux.HandleFunc("POST /c/{id}/info/title/generate", h.requireUser(h.handleTitleGenerate))
	mux.HandleFunc("POST /c/{id}/info/delete", h.requireUser(h.handleInfoDelete))
}
