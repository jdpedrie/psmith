// Package web is the server-rendered web client for psmithd. It is a
// presentation layer over the same services the ConnectRPC handlers expose,
// called in-process, and is served from psmithd's own mux. The UI works as
// plain HTML (forms POST, links navigate) and is progressively enhanced with
// htmx (plus its SSE extension): the conversation streams live over SSE.
package web

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/a-h/templ"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/conversations"
	"github.com/jdpedrie/psmith/internal/embeddersvc"
	"github.com/jdpedrie/psmith/internal/files"
	"github.com/jdpedrie/psmith/internal/langfusesvc"
	"github.com/jdpedrie/psmith/internal/modelproviders"
	"github.com/jdpedrie/psmith/internal/profiles"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/stream"
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
	Files         *files.Service
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
	files      *files.Service
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
		files:      d.Files,
		supervisor: d.Supervisor,
		logger:     d.Logger,
	}
}

// signedImageURL mints a short-lived signed URL for a file, or "" on failure.
func (h *Handler) signedImageURL(ctx context.Context, fileID string) string {
	if h.files == nil {
		return ""
	}
	resp, err := h.files.GetFileURL(ctx, connect.NewRequest(&psmithv1.GetFileURLRequest{FileId: fileID}))
	if err != nil {
		return ""
	}
	return resp.Msg.GetUrl()
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
	mux.HandleFunc("POST /c/{id}/elicit/{eid}", h.requireUser(h.handleElicitRespond))
	mux.HandleFunc("GET /c/{id}/model", h.requireUser(h.handleModelPicker))
	mux.HandleFunc("POST /c/{id}/model", h.requireUser(h.handleSetModel))
	mux.HandleFunc("GET /c/{id}/settings", h.requireUser(h.handleConvSettings))
	mux.HandleFunc("POST /c/{id}/settings", h.requireUser(h.handleConvSettingsSave))
	mux.HandleFunc("POST /c/{id}/plugins/override", h.requireUser(h.handleConvPluginOverride))

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
	mux.HandleFunc("GET /settings/profiles/{id}/plugins", h.requireUser(h.handlePluginsPage))
	mux.HandleFunc("POST /settings/profiles/{id}/plugins", h.requireUser(h.handlePluginsSave))
	mux.HandleFunc("POST /settings/profiles/{id}/plugins/add", h.requireUser(h.handlePluginAdd))
	mux.HandleFunc("POST /settings/profiles/{id}/plugins/remove", h.requireUser(h.handlePluginRemove))

	mux.HandleFunc("GET /settings/mcp-servers", h.requireUser(h.handleMCPServers))
	mux.HandleFunc("GET /settings/mcp-servers/new", h.requireUser(h.handleMCPServerNew))
	mux.HandleFunc("POST /settings/mcp-servers", h.requireUser(h.handleMCPServerSave))
	mux.HandleFunc("GET /settings/mcp-servers/{id}", h.requireUser(h.handleMCPServerEdit))
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

	mux.HandleFunc("GET /settings/cost", h.requireUser(h.handleCost))

	mux.HandleFunc("GET /c/{id}/contexts", h.requireUser(h.handleContexts))
	mux.HandleFunc("GET /c/{id}/context/{cid}", h.requireUser(h.handleContextView))

	mux.HandleFunc("GET /c/{id}/message/{mid}/edit", h.requireUser(h.handleEditForm))
	mux.HandleFunc("POST /c/{id}/message/{mid}/edit", h.requireUser(h.handleEditSave))
	mux.HandleFunc("POST /c/{id}/regenerate", h.requireUser(h.handleRegenerate))
	mux.HandleFunc("POST /c/{id}/message/{mid}/delete", h.requireUser(h.handleMessageDelete))

	mux.HandleFunc("GET /c/{id}/compact", h.requireUser(h.handleCompactPage))
	mux.HandleFunc("POST /c/{id}/compact", h.requireUser(h.handleCompactRun))
	mux.HandleFunc("GET /c/{id}/compact/stream", h.requireUser(h.handleCompactStream))
	mux.HandleFunc("POST /c/{id}/promote", h.requireUser(h.handleCompactPromote))
}

func cacheControl(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		next.ServeHTTP(w, r)
	})
}

// --- view models (decouple templ from the proto types) ---

type convoVM struct {
	ID      string
	Title   string
	Active  bool
	RelTime string // short relative time, e.g. "3h", "Apr 2"
	Group   string // date bucket header for the sidebar, e.g. "Today"
}

type msgVM struct {
	ID       string
	ConvID   string
	ParentID string
	Role     string
	HTML     string   // rendered, sanitized message HTML
	Images   []string // signed URLs for image attachments
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
	resp, err := h.convos.ListConversations(ctx, connect.NewRequest(&psmithv1.ListConversationsRequest{
		PageSize: 100,
	}))
	if err != nil {
		return nil, err
	}
	now := time.Now()
	out := make([]convoVM, 0, len(resp.Msg.GetConversations()))
	var lastGroup string
	for _, c := range resp.Msg.GetConversations() {
		vm := convoVM{ID: c.GetId(), Title: convoTitle(c), Active: c.GetId() == activeID}
		if ts := c.GetUpdatedAt(); ts != nil {
			t := ts.AsTime()
			vm.RelTime = relTime(now, t)
			if g := dateGroup(now, t); g != lastGroup {
				vm.Group = g
				lastGroup = g
			}
		}
		out = append(out, vm)
	}
	return out, nil
}

// relTime renders a compact "time since" label for the sidebar: minutes/hours
// within a day, "d" within a week, then an absolute month/day.
func relTime(now, t time.Time) string {
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	case d < 7*24*time.Hour:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	case t.Year() == now.Year():
		return t.Format("Jan 2")
	default:
		return t.Format("Jan 2006")
	}
}

// dateGroup buckets a conversation's last-activity time into a sidebar section
// header. Conversations arrive newest-first, so equal buckets stay contiguous.
func dateGroup(now, t time.Time) string {
	startOfToday := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	switch {
	case !t.Before(startOfToday):
		return "Today"
	case !t.Before(startOfToday.AddDate(0, 0, -1)):
		return "Yesterday"
	case !t.Before(startOfToday.AddDate(0, 0, -7)):
		return "Previous 7 days"
	case !t.Before(startOfToday.AddDate(0, 0, -30)):
		return "Previous 30 days"
	default:
		return "Older"
	}
}

func convoTitle(c *psmithv1.Conversation) string {
	if t := strings.TrimSpace(c.GetTitle()); t != "" {
		return t
	}
	return "Untitled"
}

func roleClass(r psmithv1.MessageRole) string {
	switch r {
	case psmithv1.MessageRole_MESSAGE_ROLE_USER:
		return "user"
	case psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT, psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY:
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
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{}))
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
	resp, err := h.profiles.ListProfiles(ctx, connect.NewRequest(&psmithv1.ListProfilesRequest{}))
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
