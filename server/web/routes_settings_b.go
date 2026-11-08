package web

import "net/http"

// mountSettingsB registers the routes for Settings: profiles, plugins, MCP servers, embedder, Langfuse, speech.
func (h *Handler) mountSettingsB(mux *http.ServeMux) {
	mux.HandleFunc("GET /settings/profiles", h.requireUser(h.handleProfiles))
	mux.HandleFunc("GET /settings/profiles/new", h.requireUser(h.handleProfileNew))
	mux.HandleFunc("POST /settings/profiles", h.requireUser(h.handleProfileCreate))
	mux.HandleFunc("GET /settings/profiles/import", h.requireUser(h.handleProfileImportPage))
	mux.HandleFunc("POST /settings/profiles/import", h.requireUser(h.handleProfileImport))
	mux.HandleFunc("GET /settings/profiles/{id}", h.requireUser(h.handleProfileEdit))
	mux.HandleFunc("POST /settings/profiles/{id}", h.requireUser(h.handleProfileUpdate))
	mux.HandleFunc("POST /settings/profiles/{id}/default", h.requireUser(h.handleProfileMakeDefault))
	mux.HandleFunc("POST /settings/profiles/{id}/delete", h.requireUser(h.handleProfileDelete))
	mux.HandleFunc("GET /settings/profiles/{id}/models", h.requireUser(h.handleProfileModels))
	mux.HandleFunc("POST /settings/profiles/{id}/models", h.requireUser(h.handleProfileModelsSave))
	mux.HandleFunc("GET /settings/profiles/{id}/plugins", h.requireUser(h.handlePluginsPage))
	mux.HandleFunc("POST /settings/profiles/{id}/plugins", h.requireUser(h.handlePluginsSave))
	mux.HandleFunc("POST /settings/profiles/{id}/plugins/add", h.requireUser(h.handlePluginAdd))
	mux.HandleFunc("POST /settings/profiles/{id}/plugins/remove", h.requireUser(h.handlePluginRemove))
	mux.HandleFunc("GET /settings/profiles/{id}/share", h.requireUser(h.handleProfileShare))
	mux.HandleFunc("GET /settings/profiles/{id}/export", h.requireUser(h.handleProfileExport))

	mux.HandleFunc("GET /settings/plugins", h.requireUser(h.handleGlobalPlugins))
	mux.HandleFunc("GET /settings/plugins/{name}", h.requireUser(h.handleGlobalPluginConfig))
	mux.HandleFunc("POST /settings/plugins/{name}", h.requireUser(h.handleGlobalPluginConfigSave))

	mux.HandleFunc("GET /settings/mcp-servers", h.requireUser(h.handleMCPServers))
	mux.HandleFunc("GET /settings/mcp-servers/new", h.requireUser(h.handleMCPServerNew))
	mux.HandleFunc("POST /settings/mcp-servers", h.requireUser(h.handleMCPServerSave))
	mux.HandleFunc("GET /settings/mcp-servers/{id}", h.requireUser(h.handleMCPServerDetail))
	mux.HandleFunc("GET /settings/mcp-servers/{id}/edit", h.requireUser(h.handleMCPServerEdit))
	mux.HandleFunc("POST /settings/mcp-servers/{id}/test", h.requireUser(h.handleMCPServerTest))
	mux.HandleFunc("POST /settings/mcp-servers/{id}/delete", h.requireUser(h.handleMCPServerDelete))

	mux.HandleFunc("GET /settings/embedder", h.requireUser(h.handleEmbedder))
	mux.HandleFunc("POST /settings/embedder", h.requireUser(h.handleEmbedderSave))
	mux.HandleFunc("POST /settings/embedder/test", h.requireUser(h.handleEmbedderTest))
	mux.HandleFunc("POST /settings/embedder/delete", h.requireUser(h.handleEmbedderDelete))
	mux.HandleFunc("GET /settings/langfuse", h.requireUser(h.handleLangfuse))
	mux.HandleFunc("POST /settings/langfuse", h.requireUser(h.handleLangfuseSave))
	mux.HandleFunc("POST /settings/langfuse/test", h.requireUser(h.handleLangfuseTest))
	mux.HandleFunc("POST /settings/langfuse/delete", h.requireUser(h.handleLangfuseDelete))
	mux.HandleFunc("GET /settings/speech", h.requireUser(h.handleSpeech))
	mux.HandleFunc("POST /settings/speech", h.requireUser(h.handleSpeechSave))
	mux.HandleFunc("POST /settings/speech/test", h.requireUser(h.handleSpeechTest))
	mux.HandleFunc("POST /settings/speech/key/delete", h.requireUser(h.handleSpeechKeyDelete))
	mux.HandleFunc("POST /settings/speech/delete", h.requireUser(h.handleSpeechDelete))
}
