package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// First-run setup: an account with no provider can't chat, so /chats sends
// it here. Three steps, each its own page: pick a provider template, give it
// a key (and test it), turn on models. It calls the same modelproviders
// service methods the Settings provider pages do.

type setupVM struct {
	Templates  []tplVM
	Template   tplVM
	ProviderID string
	Label      string
	BaseURL    string
	Key        string
	Test       *testVM
	Models     []setupModelVM
	Error      string
	ShowFocus  bool // draw the key field focused (fixtures)
}

func (s setupVM) onCount() int {
	n := 0
	for _, m := range s.Models {
		if m.On {
			n++
		}
	}
	return n
}

// tplVM is a provider template as a choice.
type tplVM struct {
	ID       string
	Name     string
	Mono     string // the letter on its tile
	Kind     string // "Native driver", "OpenAI-compatible"
	Base     string // default API base URL
	Driver   string
	Preset   string
	NeedsURL bool
}

type setupModelVM struct {
	Name, ID, Context, Cost string
	Caps                    []string
	On                      bool
}

const customTemplate = "custom"

// hostSuffix is " · host" for a base URL, "" without one.
func hostSuffix(base string) string {
	u, err := url.Parse(base)
	if err != nil || u.Host == "" {
		return ""
	}
	return " · " + u.Host
}

// needsSetup reports an account with no provider at all.
func (h *Handler) needsSetup(ctx context.Context) bool {
	if h.models == nil {
		return false
	}
	resp, err := h.models.ListUserModelProviders(ctx, connect.NewRequest(&psmithv1.ListUserModelProvidersRequest{}))
	return err == nil && len(resp.Msg.GetProviders()) == 0
}

// templates lists the provider templates as choices, plus Custom for any
// OpenAI-compatible URL.
func (h *Handler) templates(ctx context.Context) []tplVM {
	var out []tplVM
	if h.models != nil {
		if resp, err := h.models.ListProviderTemplates(ctx, connect.NewRequest(&psmithv1.ListProviderTemplatesRequest{})); err == nil {
			for _, t := range resp.Msg.GetTemplates() {
				out = append(out, tplFrom(t))
			}
		}
	}
	return append(out, tplVM{ID: customTemplate, Name: "Custom", Mono: "C", Kind: "Any OpenAI-compatible URL", Driver: "openai-compatible", NeedsURL: true})
}

func tplFrom(t *psmithv1.ProviderTemplate) tplVM {
	v := tplVM{ID: t.GetCatalogProviderId(), Name: t.GetName(), Base: t.GetApiBase(), Driver: t.GetDriverType(), Preset: t.GetPresetId(), Kind: "OpenAI-compatible"}
	if v.Driver != "openai-compatible" {
		v.Kind = "Native driver"
	}
	if strings.Contains(v.Base, "localhost") || strings.Contains(v.Base, "127.0.0.1") {
		v.Kind, v.NeedsURL = "Local, OpenAI-compatible", true
		v.Name = strings.TrimSpace(strings.TrimSuffix(v.Name, "(local)"))
	}
	if v.Name != "" {
		v.Mono = strings.ToUpper(v.Name[:1])
	}
	if v.ID == "openrouter" {
		v.Mono = "R" // OpenAI already wears the O
	}
	return v
}

func pickTemplate(all []tplVM, id string) tplVM {
	for _, t := range all {
		if t.ID == id {
			return t
		}
	}
	if len(all) > 0 {
		return all[0]
	}
	return tplVM{}
}

// templateFor finds the template a saved provider came from.
func templateFor(all []tplVM, p *psmithv1.UserModelProvider) tplVM {
	var cfg struct {
		PresetID string `json:"preset_id"`
	}
	_ = json.Unmarshal(p.GetConfig(), &cfg)
	for _, t := range all {
		if t.Driver == p.GetType() && (t.Driver != "openai-compatible" || (cfg.PresetID != "" && t.Preset == cfg.PresetID)) {
			return t
		}
	}
	return pickTemplate(all, customTemplate)
}

// GET /setup: step 1.
func (h *Handler) handleSetup(w http.ResponseWriter, r *http.Request) {
	all := h.templates(r.Context())
	h.render(w, r, http.StatusOK, setupProviderScreen(setupVM{Templates: all, Template: pickTemplate(all, r.URL.Query().Get("t"))}))
}

// GET /setup/key: step 2, for template ?t or the provider ?p already made.
func (h *Handler) handleSetupKeyForm(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	all := h.templates(ctx)
	s := setupVM{Template: pickTemplate(all, r.URL.Query().Get("t"))}
	s.Label = s.Template.Name
	s.BaseURL = s.Template.Base
	if pid := r.URL.Query().Get("p"); pid != "" && h.models != nil {
		if resp, err := h.models.GetUserModelProvider(ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: pid})); err == nil {
			p := resp.Msg.GetProvider()
			s.ProviderID, s.Label = p.GetId(), p.GetLabel()
			if r.URL.Query().Get("t") == "" {
				s.Template = templateFor(all, p)
			}
		}
	}
	h.render(w, r, http.StatusOK, setupKeyScreen(s))
}

// POST /setup/key: save the provider (create, or update the one made on an
// earlier pass), then test it or move on to models.
func (h *Handler) handleSetupKey(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	_ = r.ParseForm()
	all := h.templates(ctx)
	s := setupVM{
		Template:   pickTemplate(all, r.PostFormValue("t")),
		ProviderID: r.PostFormValue("p"),
		Label:      strings.TrimSpace(r.PostFormValue("label")),
		BaseURL:    strings.TrimSpace(r.PostFormValue("base_url")),
		Key:        strings.TrimSpace(r.PostFormValue("api_key")),
	}
	if s.Label == "" {
		s.Label = s.Template.Name
	}
	if err := h.saveSetupProvider(ctx, &s); err != nil {
		s.Test = &testVM{Message: friendlyError(err)}
		h.render(w, r, http.StatusOK, setupKeyScreen(s))
		return
	}
	if r.PostFormValue("action") != "test" {
		http.Redirect(w, r, "/setup/models?p="+url.QueryEscape(s.ProviderID)+"&t="+url.QueryEscape(s.Template.ID), http.StatusSeeOther)
		return
	}
	resp, err := h.models.TestUserModelProvider(ctx, connect.NewRequest(&psmithv1.TestUserModelProviderRequest{UserModelProviderId: s.ProviderID}))
	switch {
	case err != nil:
		s.Test = &testVM{Message: friendlyError(err)}
	case !resp.Msg.GetOk():
		s.Test = &testVM{Message: orDefault(resp.Msg.GetErrorMessage(), "The provider didn't answer.")}
	default:
		s.Test = &testVM{OK: true, ModelCount: resp.Msg.GetModelCount(),
			Message: fmt.Sprintf("Connected in %d ms. Found %d models.", resp.Msg.GetLatencyMs(), resp.Msg.GetModelCount())}
	}
	h.render(w, r, http.StatusOK, setupKeyScreen(s))
}

func (h *Handler) saveSetupProvider(ctx context.Context, s *setupVM) error {
	cfg := map[string]string{}
	if s.Key != "" {
		cfg["api_key"] = s.Key
	}
	if s.Template.Driver == "openai-compatible" {
		base := s.BaseURL
		if base == "" {
			base = s.Template.Base
		}
		if base != "" {
			cfg["base_url"] = base
		}
		if s.Template.Preset != "" {
			cfg["preset_id"] = s.Template.Preset
		}
	} else if s.BaseURL != "" {
		cfg["base_url"] = s.BaseURL
	}
	raw, _ := json.Marshal(cfg)
	if s.ProviderID != "" {
		req := &psmithv1.UpdateUserModelProviderRequest{Id: s.ProviderID, Label: &s.Label}
		if s.Key != "" {
			req.Config = raw
		}
		_, err := h.models.UpdateUserModelProvider(ctx, connect.NewRequest(req))
		return err
	}
	resp, err := h.models.CreateUserModelProvider(ctx, connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{
		Type: s.Template.Driver, Label: s.Label, Config: raw,
	}))
	if err != nil {
		return err
	}
	s.ProviderID = resp.Msg.GetProvider().GetId()
	return nil
}

// GET /setup/models: step 3, the provider's models with switches.
func (h *Handler) handleSetupModelsForm(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, http.StatusOK, setupModelsScreen(h.loadSetupModels(r.Context(), r.URL.Query().Get("p"), r.URL.Query().Get("t"))))
}

func (h *Handler) loadSetupModels(ctx context.Context, pid, tid string) setupVM {
	all := h.templates(ctx)
	s := setupVM{ProviderID: pid, Template: pickTemplate(all, tid)}
	if resp, err := h.models.GetUserModelProvider(ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: pid})); err == nil {
		s.Label = resp.Msg.GetProvider().GetLabel()
		if tid == "" {
			s.Template = templateFor(all, resp.Msg.GetProvider())
		}
	}
	resp, err := h.models.DiscoverModels(ctx, connect.NewRequest(&psmithv1.DiscoverModelsRequest{UserModelProviderId: pid}))
	if err != nil {
		s.Error = "Couldn't list models: " + friendlyError(err)
		return s
	}
	anyOn := false
	for _, m := range resp.Msg.GetModels() {
		row := setupModelVM{Name: orDefault(m.GetDisplayName(), m.GetModelId()), ID: m.GetModelId(), On: m.GetAlreadyEnabled()}
		if m.ContextWindow != nil {
			row.Context = abbrevTokens(m.GetContextWindow())
		}
		row.Cost, _ = costBucket(m.GetPricing())
		row.Caps = capLabels(m.GetCapabilities())
		anyOn = anyOn || row.On
		s.Models = append(s.Models, row)
	}
	// A fresh provider starts with its first few models on, so Finish is
	// one keystroke for someone who doesn't care which.
	if !anyOn {
		for i := range s.Models {
			if i < 3 {
				s.Models[i].On = true
			}
		}
	}
	return s
}

func capLabels(c *psmithv1.ModelCapabilities) []string {
	var out []string
	if c.GetVision() {
		out = append(out, "Vision")
	}
	if c.GetToolUse() {
		out = append(out, "Tools")
	}
	if c.GetThinking() {
		out = append(out, "Thinking")
	}
	return out
}

// POST /setup/models: turn on the ticked models, off the rest, and start.
func (h *Handler) handleSetupModels(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	_ = r.ParseForm()
	pid := r.PostFormValue("p")
	on := r.PostForm["model_ids"]
	if len(on) == 0 {
		s := h.loadSetupModels(ctx, pid, r.PostFormValue("t"))
		for i := range s.Models {
			s.Models[i].On = false
		}
		s.Error = "Turn on at least one model to chat with."
		h.render(w, r, http.StatusOK, setupModelsScreen(s))
		return
	}
	if _, err := h.models.EnableModels(ctx, connect.NewRequest(&psmithv1.EnableModelsRequest{UserModelProviderId: pid, ModelIds: on})); err != nil {
		s := h.loadSetupModels(ctx, pid, r.PostFormValue("t"))
		s.Error = friendlyError(err)
		h.render(w, r, http.StatusOK, setupModelsScreen(s))
		return
	}
	keep := map[string]bool{}
	for _, id := range on {
		keep[id] = true
	}
	if resp, err := h.models.ListUserModels(ctx, connect.NewRequest(&psmithv1.ListUserModelsRequest{UserModelProviderId: pid})); err == nil {
		var off []string
		for _, m := range resp.Msg.GetModels() {
			if !keep[m.GetModelId()] {
				off = append(off, m.GetModelId())
			}
		}
		if len(off) > 0 {
			if _, err := h.models.DisableModels(ctx, connect.NewRequest(&psmithv1.DisableModelsRequest{UserModelProviderId: pid, ModelIds: off})); err != nil {
				h.logger.Warn("web: setup disable models failed", "err", err)
			}
		}
	}
	http.Redirect(w, r, "/chats", http.StatusSeeOther)
}
