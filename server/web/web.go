// Package web is the server-rendered web client for psmithd. It is a
// presentation layer over the same services the ConnectRPC handlers expose,
// called in-process, and is served from psmithd's own mux. The UI works as
// plain HTML (forms POST, links navigate) and is progressively enhanced with
// htmx (plus its SSE extension): the conversation streams live over SSE.
package web

import (
	"context"
	"embed"
	"io/fs"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/a-h/templ"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/conversations"
	"github.com/jdpedrie/psmith/server/embeddersvc"
	"github.com/jdpedrie/psmith/server/events"
	"github.com/jdpedrie/psmith/server/files"
	"github.com/jdpedrie/psmith/server/langfusesvc"
	"github.com/jdpedrie/psmith/server/modelproviders"
	"github.com/jdpedrie/psmith/server/preferencessvc"
	"github.com/jdpedrie/psmith/server/profiles"
	"github.com/jdpedrie/psmith/server/speechsvc"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
	"github.com/jdpedrie/psmith/server/streamsvc"
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
	Preferences   *preferencessvc.Service
	Speech        *speechsvc.Service
	Streams       *streamsvc.Service
	// Bus may be nil — the /events SSE bridge then reports 404 and
	// pages simply never receive push triggers (htmx SSE fails quietly).
	Bus    *events.Bus
	Logger *slog.Logger
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
	prefs      *preferencessvc.Service
	speech     *speechsvc.Service
	streams    *streamsvc.Service
	bus        *events.Bus
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
		prefs:      d.Preferences,
		speech:     d.Speech,
		streams:    d.Streams,
		bus:        d.Bus,
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
	mux.HandleFunc("POST /prefs/appearance", h.handleAppearance)
	mux.HandleFunc("POST /login", h.handleLogin)
	mux.HandleFunc("POST /logout", h.handleLogout)
	mux.HandleFunc("GET /events", h.requireUser(h.handleEvents))

	h.mountList(mux)
	h.mountConversation(mux)
	h.mountInspector(mux)
	h.mountSettingsA(mux)
	h.mountSettingsB(mux)
}

func cacheControl(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		next.ServeHTTP(w, r)
	})
}

// --- view models (decouple templ from the proto types) ---

// harnessVM is what a conversation is committed to, in the shape the templates
// want. See docs/design/providers.md; the constraints all follow from the
// harness owning the transcript.
type harnessVM struct {
	ProviderID    string
	ProviderLabel string
	DriverType    string
	FrozenPrompt  bool
	NoAttachments bool
}

func harnessVMFrom(b *psmithv1.HarnessBinding) *harnessVM {
	if b == nil {
		return nil
	}
	return &harnessVM{
		ProviderID:    b.GetProviderId(),
		ProviderLabel: b.GetProviderLabel(),
		DriverType:    b.GetDriverType(),
		FrozenPrompt:  b.GetSystemPromptFrozen(),
		NoAttachments: !b.GetAcceptsAttachments(),
	}
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

func (h *Handler) render(w http.ResponseWriter, r *http.Request, status int, c templ.Component) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := c.Render(withPrefs(r.Context(), readPrefs(r)), w); err != nil {
		h.logger.Warn("web: render failed", "err", err)
	}
}

// pinTitle labels the sidebar pin toggle for its current state.
func pinTitle(pinned bool) string {
	if pinned {
		return "Unpin"
	}
	return "Pin"
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
