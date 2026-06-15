// Package web is the server-rendered web client for reeved. It is a
// presentation layer over the same services the ConnectRPC handlers expose,
// called in-process, and is served from reeved's own mux. The UI works as
// plain HTML (forms POST, links navigate) and is progressively enhanced with
// Datastar: the conversation streams live over SSE.
package web

import (
	"context"
	"embed"
	"io/fs"
	"log/slog"
	"net/http"
	"strings"

	"connectrpc.com/connect"
	"github.com/a-h/templ"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/conversations"
	"github.com/jdpedrie/reeve/internal/embeddersvc"
	"github.com/jdpedrie/reeve/internal/langfusesvc"
	"github.com/jdpedrie/reeve/internal/modelproviders"
	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
)

//go:embed assets
var assetsFS embed.FS

// Deps are the services the web handler calls in-process. Pass the same
// instances main() built for the ConnectRPC handlers. Fields a given page
// does not touch may be nil (handy in tests).
type Deps struct {
	Queries       *store.Queries
	Auth          *auth.Service
	Conversations *conversations.Service
	Models        *modelproviders.Service
	Profiles      *profiles.Service
	Embedder      *embeddersvc.Service
	Langfuse      *langfusesvc.Service
	Supervisor    *stream.Supervisor
	Logger        *slog.Logger
}

// Handler serves the web UI.
type Handler struct {
	queries    *store.Queries
	auth       *auth.Service
	convos     *conversations.Service
	models     *modelproviders.Service
	profiles   *profiles.Service
	embedder   *embeddersvc.Service
	langfuse   *langfusesvc.Service
	supervisor *stream.Supervisor
	logger     *slog.Logger
}

// New constructs the web handler from its dependencies.
func New(d Deps) *Handler {
	if d.Logger == nil {
		d.Logger = slog.Default()
	}
	return &Handler{
		queries:    d.Queries,
		auth:       d.Auth,
		convos:     d.Conversations,
		models:     d.Models,
		profiles:   d.Profiles,
		embedder:   d.Embedder,
		langfuse:   d.Langfuse,
		supervisor: d.Supervisor,
		logger:     d.Logger,
	}
}

// Mount registers the web routes on mux. The paths are distinct from the
// ConnectRPC service paths and the other non-RPC endpoints, so they coexist.
func (h *Handler) Mount(mux *http.ServeMux) {
	sub, _ := fs.Sub(assetsFS, "assets")
	mux.Handle("GET /web-assets/", http.StripPrefix("/web-assets/", cacheControl(http.FileServer(http.FS(sub)))))

	mux.HandleFunc("GET /{$}", h.handleHome)
	mux.HandleFunc("GET /login", h.handleLoginForm)
	mux.HandleFunc("POST /login", h.handleLogin)
	mux.HandleFunc("POST /logout", h.handleLogout)
	mux.HandleFunc("GET /chats", h.requireUser(h.handleChats))
	mux.HandleFunc("GET /new", h.requireUser(h.handleNewForm))
	mux.HandleFunc("POST /new", h.requireUser(h.handleNewCreate))
	mux.HandleFunc("GET /c/{id}", h.requireUser(h.handleConversation))
	mux.HandleFunc("POST /c/{id}/send", h.requireUser(h.handleSend))
	mux.HandleFunc("GET /c/{id}/stream", h.requireUser(h.handleStream))

	mux.HandleFunc("GET /settings", h.requireUser(h.handleSettings))
	mux.HandleFunc("GET /settings/providers", h.requireUser(h.handleProviders))
	mux.HandleFunc("GET /settings/providers/new", h.requireUser(h.handleProviderNew))
	mux.HandleFunc("POST /settings/providers", h.requireUser(h.handleProviderCreate))
	mux.HandleFunc("GET /settings/providers/{id}", h.requireUser(h.handleProvider))
	mux.HandleFunc("POST /settings/providers/{id}/discover", h.requireUser(h.handleProviderDiscover))
	mux.HandleFunc("POST /settings/providers/{id}/enable", h.requireUser(h.handleProviderEnable))
	mux.HandleFunc("POST /settings/providers/{id}/test", h.requireUser(h.handleProviderTest))
	mux.HandleFunc("POST /settings/providers/{id}/delete", h.requireUser(h.handleProviderDelete))

	mux.HandleFunc("GET /settings/profiles", h.requireUser(h.handleProfiles))
	mux.HandleFunc("GET /settings/profiles/new", h.requireUser(h.handleProfileNew))
	mux.HandleFunc("POST /settings/profiles", h.requireUser(h.handleProfileCreate))
	mux.HandleFunc("GET /settings/profiles/{id}", h.requireUser(h.handleProfileEdit))
	mux.HandleFunc("POST /settings/profiles/{id}", h.requireUser(h.handleProfileUpdate))
	mux.HandleFunc("POST /settings/profiles/{id}/delete", h.requireUser(h.handleProfileDelete))

	mux.HandleFunc("GET /settings/embedder", h.requireUser(h.handleEmbedder))
	mux.HandleFunc("POST /settings/embedder", h.requireUser(h.handleEmbedderSave))
	mux.HandleFunc("POST /settings/embedder/test", h.requireUser(h.handleEmbedderTest))
	mux.HandleFunc("POST /settings/embedder/delete", h.requireUser(h.handleEmbedderDelete))

	mux.HandleFunc("GET /settings/langfuse", h.requireUser(h.handleLangfuse))
	mux.HandleFunc("POST /settings/langfuse", h.requireUser(h.handleLangfuseSave))
	mux.HandleFunc("POST /settings/langfuse/test", h.requireUser(h.handleLangfuseTest))
	mux.HandleFunc("POST /settings/langfuse/delete", h.requireUser(h.handleLangfuseDelete))
}

func cacheControl(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=3600")
		next.ServeHTTP(w, r)
	})
}

// --- view models (decouple templ from the proto types) ---

type convoVM struct {
	ID     string
	Title  string
	Active bool
}

type msgVM struct {
	ID   string
	Role string
	HTML string // rendered, sanitized message HTML
}

type modelVM struct {
	Value    string // "providerID|modelID"
	Label    string
	Selected bool
}

type profileVM struct {
	ID          string
	Name        string
	Description string
}

func (h *Handler) render(w http.ResponseWriter, r *http.Request, status int, c templ.Component) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := c.Render(r.Context(), w); err != nil {
		h.logger.Warn("web: render failed", "err", err)
	}
}

// listConvos loads the caller's conversations for the sidebar, marking
// activeID as current.
func (h *Handler) listConvos(ctx context.Context, activeID string) ([]convoVM, error) {
	resp, err := h.convos.ListConversations(ctx, connect.NewRequest(&reevev1.ListConversationsRequest{
		PageSize: 100,
	}))
	if err != nil {
		return nil, err
	}
	out := make([]convoVM, 0, len(resp.Msg.GetConversations()))
	for _, c := range resp.Msg.GetConversations() {
		out = append(out, convoVM{ID: c.GetId(), Title: convoTitle(c), Active: c.GetId() == activeID})
	}
	return out, nil
}

func convoTitle(c *reevev1.Conversation) string {
	if t := strings.TrimSpace(c.GetTitle()); t != "" {
		return t
	}
	return "Untitled"
}

func roleClass(r reevev1.MessageRole) string {
	switch r {
	case reevev1.MessageRole_MESSAGE_ROLE_USER:
		return "user"
	case reevev1.MessageRole_MESSAGE_ROLE_ASSISTANT, reevev1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY:
		return "assistant"
	default:
		return "system"
	}
}

// modelValue is the composite the model picker carries: "providerID|modelID".
func modelValue(providerID, modelID string) string {
	return providerID + "|" + modelID
}

// splitModelValue parses a picker value back into provider and model ids.
func splitModelValue(v string) (providerID, modelID string, ok bool) {
	i := strings.IndexByte(v, '|')
	if i < 0 {
		return "", "", false
	}
	return v[:i], v[i+1:], v[:i] != "" && v[i+1:] != ""
}

// listModels returns the caller's enabled models for the picker, marking the
// one matching selected ("providerID|modelID") as current. Favorites sort
// first, then by label.
func (h *Handler) listModels(ctx context.Context, selected string) []modelVM {
	if h.models == nil {
		return nil
	}
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&reevev1.ListAllUserModelsRequest{}))
	if err != nil {
		h.logger.Warn("web: list models failed", "err", err)
		return nil
	}
	entries := resp.Msg.GetEntries()
	out := make([]modelVM, 0, len(entries))
	for _, e := range entries {
		val := modelValue(e.GetProvider().GetId(), e.GetModel().GetModelId())
		label := e.GetModel().GetDisplayName()
		if label == "" {
			label = e.GetModel().GetModelId()
		}
		if pl := e.GetProvider().GetLabel(); pl != "" {
			label = label + " (" + pl + ")"
		}
		out = append(out, modelVM{Value: val, Label: label, Selected: val == selected})
	}
	return out
}

// listProfiles returns the caller's directly-usable profiles for the
// new-conversation picker. Parent-only profiles are templates, not chat
// personas, so they are excluded.
func (h *Handler) listProfiles(ctx context.Context) []profileVM {
	if h.profiles == nil {
		return nil
	}
	resp, err := h.profiles.ListProfiles(ctx, connect.NewRequest(&reevev1.ListProfilesRequest{}))
	if err != nil {
		h.logger.Warn("web: list profiles failed", "err", err)
		return nil
	}
	out := make([]profileVM, 0, len(resp.Msg.GetProfiles()))
	for _, p := range resp.Msg.GetProfiles() {
		if p.GetParentOnly() {
			continue
		}
		out = append(out, profileVM{ID: p.GetId(), Name: p.GetName(), Description: p.GetDescription()})
	}
	return out
}

// currentModelValue resolves the conversation's selected model: its stored
// default if set, else the first available model (favoring favorites).
func currentModelValue(conv *reevev1.Conversation, models []modelVM) string {
	if s := conv.GetSettings(); s != nil && s.GetDefaultProviderId() != "" && s.GetDefaultModelId() != "" {
		return modelValue(s.GetDefaultProviderId(), s.GetDefaultModelId())
	}
	if len(models) > 0 {
		return models[0].Value
	}
	return ""
}
