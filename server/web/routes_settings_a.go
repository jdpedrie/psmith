package web

import "net/http"

// mountSettingsA registers the routes for Settings: General, Appearance, Usage, providers and models, users.
//
// Model ids can carry slashes (router-style ids such as
// "anthropic/claude-sonnet-4"), so every model route ends in {model...} and
// puts its verb before it.
func (h *Handler) mountSettingsA(mux *http.ServeMux) {
	h.mountSettingsAWith(mux, h.requireUser)
}

// mountSettingsAWith registers the routes behind u, the sign-in gate. Tests
// pass one that lets a context-borne user through.
func (h *Handler) mountSettingsAWith(mux *http.ServeMux, u func(http.HandlerFunc) http.HandlerFunc) {
	mux.HandleFunc("GET /settings", u(h.handleSettings))
	mux.HandleFunc("GET /settings/general", u(h.handleGeneral))
	mux.HandleFunc("POST /settings/general/warning", u(h.handleWarningSave))
	mux.HandleFunc("POST /settings/general/password", u(h.handlePasswordChange))
	mux.HandleFunc("GET /settings/appearance", u(h.handleAppearancePage))
	mux.HandleFunc("POST /prefs/display", h.handleDisplayPrefs)
	mux.HandleFunc("GET /settings/cost", u(h.handleCost))
	mux.HandleFunc("GET /settings/usage", u(h.handleCost))

	mux.HandleFunc("GET /settings/providers", u(h.handleProviders))
	mux.HandleFunc("GET /settings/providers/new", u(h.handleProviderNew))
	mux.HandleFunc("POST /settings/providers", u(h.handleProviderCreate))
	mux.HandleFunc("POST /settings/catalog/refresh", u(saRequireAdmin(h.handleCatalogRefresh)))
	mux.HandleFunc("GET /settings/providers/{id}", u(h.handleProvider))
	mux.HandleFunc("POST /settings/providers/{id}", u(h.handleProviderSave))
	mux.HandleFunc("POST /settings/providers/{id}/test", u(h.handleProviderTest))
	mux.HandleFunc("POST /settings/providers/{id}/disable", u(h.handleProviderDisable))
	mux.HandleFunc("POST /settings/providers/{id}/delete", u(h.handleProviderDelete))
	mux.HandleFunc("GET /settings/providers/{id}/discover", u(h.handleProviderDiscover))
	mux.HandleFunc("POST /settings/providers/{id}/enable", u(h.handleProviderEnable))
	mux.HandleFunc("GET /settings/providers/{id}/defaults", u(h.handleProviderDefaults))
	mux.HandleFunc("POST /settings/providers/{id}/defaults", u(h.handleProviderDefaultsSave))
	mux.HandleFunc("GET /settings/providers/{id}/add-model", u(h.handleAddModel))
	mux.HandleFunc("POST /settings/providers/{id}/add-model", u(h.handleAddModelSave))
	mux.HandleFunc("GET /settings/providers/{id}/models/{model...}", u(h.handleModel))
	mux.HandleFunc("POST /settings/providers/{id}/models/{model...}", u(h.handleModelSave))
	mux.HandleFunc("POST /settings/providers/{id}/model-op/{op}/{model...}", u(h.handleModelOp))
	mux.HandleFunc("POST /settings/providers/{id}/row-test/{model...}", u(h.handleProviderRowTest))
	mux.HandleFunc("POST /settings/providers/{id}/delete-model/{model...}", u(h.handleModelDelete))
	mux.HandleFunc("GET /settings/providers/{id}/model-defaults/{model...}", u(h.handleModelDefaults))
	mux.HandleFunc("POST /settings/providers/{id}/model-defaults/{model...}", u(h.handleModelDefaultsSave))

	mux.HandleFunc("GET /settings/users", u(saRequireAdmin(h.handleUsers)))
	mux.HandleFunc("POST /settings/users", u(saRequireAdmin(h.handleUserCreate)))
	mux.HandleFunc("POST /settings/users/{uid}/role", u(saRequireAdmin(h.handleUserRole)))
	mux.HandleFunc("POST /settings/users/{uid}/password", u(saRequireAdmin(h.handleUserPassword)))
	mux.HandleFunc("POST /settings/users/{uid}/delete", u(saRequireAdmin(h.handleUserDelete)))
}
