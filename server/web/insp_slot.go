package web

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
)

// slotVM is the card that takes the composer's place.
type slotVM struct {
	Kind   string // compress, compacting, review, edit, failed, archived, elicit, readonly
	ConvID string

	CtxLabel  string // the context being compressed: "Context 2"
	NextLabel string // the one a summary starts: "Context 3"
	Tokens    int64
	Turns     int

	// Compress and failed: the instructions and the model choice.
	Guide     string
	GuideFrom string
	Groups    []cmpGroupVM
	Selected  string // "providerID|modelID"
	Fit       fitVM

	// Compacting, review and edit.
	RunID       string
	ModelName   string
	MessageID   string
	SummaryHTML string
	SummaryText string
	Truncated   bool
	// Stopped: Esc stopped the compression, so the summary ends where it
	// was cut off.
	Stopped bool
	Usage   string

	// Failed.
	Error     string
	ErrorHint string
	ModelMeta string // "qwen3:8b · Ollama on nas.local"

	Archived string // "Archived Oct 28"

	Elicit *elicitVM

	// Read-only context page.
	ContextID   string
	ActiveLabel string
}

// cmpGroupVM is one <optgroup> of the compression model select.
type cmpGroupVM struct {
	Label   string
	Options []cmpOptVM
}

type cmpOptVM struct {
	Value    string
	Label    string
	Window   int64
	Selected bool
}

// fitVM says whether the context fits the chosen model's window.
type fitVM struct {
	OK    bool
	Label string // "Fits its 200k window" / "82,140 of a 40,960 window"
}

// defaultCompressionGuide fills the instructions when no profile sets any;
// Compact refuses an empty guide.
const defaultCompressionGuide = "Summarize the conversation so far for a fresh context. Keep decisions, open questions, names and numbers. Drop anything a later turn superseded."

// fillSlot decides what stands in the composer's place.
func (h *Handler) fillSlot(ctx context.Context, r *http.Request, vm *convVM, conv *psmithv1.Conversation, active *psmithv1.Context, msgs []*psmithv1.Message) {
	in := &vm.Inspector
	base := slotVM{ConvID: vm.ID, CtxLabel: activeLabel(in.Contexts, active.GetId()), Tokens: vm.Gauge.Tokens, Turns: in.Turns}
	base.NextLabel = fmt.Sprintf("Context %d", len(in.Contexts)+1)

	if vm.Slot == "archived" {
		base.Kind = "archived"
		base.Archived = "Archived"
		if a := conv.GetArchivedAt(); a != nil {
			base.Archived = "Archived " + a.AsTime().Format("Jan 2")
		}
		vm.CtxLabel = base.Archived
		in.Card = &base
		return
	}

	if run := h.runningCompaction(ctx, vm.ID); run != "" {
		base.Kind, base.RunID = "compacting", run
		base.ModelName = h.compressionModelName(ctx, conv)
		in.Card, in.Compress = &base, "running"
		return
	}

	if vm.Slot == "review" {
		for _, m := range msgs {
			if m.GetId() != vm.ReviewID {
				continue
			}
			base.MessageID = m.GetId()
			base.SummaryText = m.GetContent()
			base.SummaryHTML = renderMarkdown(m.GetContent())
			base.Truncated = isTruncatedFinish(m.GetFinishReason())
			base.ModelName = h.modelName(ctx, m.GetProviderId(), m.GetModelId())
			base.Usage = summaryUsage(m.GetUsage())
			base.Stopped = h.summaryStopped(ctx, vm.ID, m.GetId())
		}
		base.Kind = "review"
		if r.URL.Query().Get("summary") == "edit" {
			base.Kind = "edit"
		}
		in.Card, in.Compress = &base, "review"
		return
	}

	// A failed compression leaves an errored summary as the chain's last
	// message; the card offers another model until it is dismissed.
	if n := len(msgs); n > 0 {
		last := msgs[n-1]
		if last.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY && last.GetErrorText() != "" {
			card := h.compressCard(ctx, base, conv, modelValue(last.GetProviderId(), last.GetModelId()), "")
			card.Kind, card.MessageID = "failed", last.GetId()
			card.Error = last.GetErrorText()
			card.ErrorHint = card.CtxLabel + " is unchanged. Choose another model, then retry."
			card.ModelMeta = h.modelMeta(ctx, last.GetProviderId(), last.GetModelId())
			in.Card, in.Compress = &card, "open"
			return
		}
	}

	// A compression that ended between its start and this page (a short
	// summary, a fast model) has neither a running run nor its summary on
	// the chain yet. The start redirect names the run, so the page shows
	// the streaming card, whose stream replays the run and moves on to the
	// review when it ends.
	if run := r.URL.Query().Get("compact"); run != "" && h.recentCompaction(ctx, vm.ID, run) {
		base.Kind, base.RunID = "compacting", run
		base.ModelName = h.compressionModelName(ctx, conv)
		in.Card, in.Compress = &base, "running"
	}
}

// compactionRun loads a compression run of this conversation, or reports
// false for any other run id.
func (h *Handler) compactionRun(ctx context.Context, convID, runID string) (store.StreamRun, bool) {
	if h.queries == nil {
		return store.StreamRun{}, false
	}
	rid, err := uuid.Parse(runID)
	if err != nil {
		return store.StreamRun{}, false
	}
	run, err := h.queries.GetStreamRunByID(ctx, rid)
	if err != nil || run.ConversationID.String() != convID || run.Purpose != string(stream.PurposeCompression) {
		return store.StreamRun{}, false
	}
	return run, true
}

// summaryStopped reports whether a summary came from a compression the
// user stopped. The summary row keeps what streamed before the stop and
// nothing marks it as cut short; the run that wrote it does.
func (h *Handler) summaryStopped(ctx context.Context, convID, messageID string) bool {
	if h.queries == nil {
		return false
	}
	cid, err := uuid.Parse(convID)
	if err != nil {
		return false
	}
	runs, err := h.queries.ListStreamRunsByConversation(ctx, cid)
	if err != nil {
		return false
	}
	for _, run := range runs {
		if run.ResultMessageID != nil && run.ResultMessageID.String() == messageID {
			return run.Purpose == string(stream.PurposeCompression) && run.Status == "cancelled"
		}
	}
	return false
}

// recentCompaction reports whether runID is this conversation's compression
// and is running or ended moments ago. An old ?compact= URL, reloaded later,
// shows the conversation as it is.
func (h *Handler) recentCompaction(ctx context.Context, convID, runID string) bool {
	run, ok := h.compactionRun(ctx, convID, runID)
	return ok && (run.EndedAt == nil || time.Since(*run.EndedAt) < 15*time.Second)
}

func activeLabel(rows []ctxRowVM, activeID string) string {
	for _, r := range rows {
		if r.ID == activeID {
			return r.Label
		}
	}
	return "this context"
}

// compressCard builds the compress (and failed) card: the instructions and
// the model the profile sets, overridden by what the user posted.
func (h *Handler) compressCard(ctx context.Context, base slotVM, conv *psmithv1.Conversation, model, guide string) slotVM {
	base.Kind = "compress"
	prof := h.resolvedProfile(ctx, conv.GetProfileId())
	profName := h.profileName(ctx, conv.GetProfileId())
	base.Guide, base.GuideFrom = defaultCompressionGuide, "Default instructions. Edits apply to this run only."
	if g := strings.TrimSpace(prof.GetCompressionGuide()); g != "" {
		base.Guide, base.GuideFrom = g, "From the "+profName+" profile. Edits apply to this run only."
	}
	if guide != "" {
		base.Guide = guide
	}
	if model == "" && prof.GetCompressionProviderId() != "" && prof.GetCompressionModelId() != "" {
		model = modelValue(prof.GetCompressionProviderId(), prof.GetCompressionModelId())
	}
	if model == "" {
		model = currentSettingsModel(conv)
	}
	data := h.modelPicker(ctx, conv.GetId(), model, capsVM{}, nil)
	if model == "" {
		model = data.Current.Value
	}
	base.Selected = model
	base.Groups = cmpGroups(data, model)
	for _, g := range data.Groups {
		for _, m := range g.Models {
			if m.Value == model {
				base.Fit = fitOf(base.Tokens, int64(m.ContextWindow))
			}
		}
	}
	return base
}

// cmpGroups turns the picker's groups into optgroups, favorites first.
func cmpGroups(data pickerData, selected string) []cmpGroupVM {
	var favs cmpGroupVM
	favs.Label = "Favorites"
	var out []cmpGroupVM
	for _, g := range data.Groups {
		grp := cmpGroupVM{Label: g.Label}
		for _, m := range g.Models {
			if m.Disabled {
				continue
			}
			o := cmpOptVM{Value: m.Value, Label: m.DisplayName, Window: int64(m.ContextWindow)}
			if m.Favorite {
				favs.Options = append(favs.Options, o)
			}
			o.Selected = m.Value == selected
			grp.Options = append(grp.Options, o)
		}
		if len(grp.Options) > 0 {
			out = append(out, grp)
		}
	}
	if len(favs.Options) > 0 {
		out = append([]cmpGroupVM{favs}, out...)
	}
	return out
}

func fitOf(tokens, window int64) fitVM {
	if window <= 0 {
		return fitVM{OK: true, Label: "Window unknown"}
	}
	if tokens <= window {
		return fitVM{OK: true, Label: "Fits its " + abbrevTokens(int32(window)) + " window"}
	}
	return fitVM{Label: commas(tokens) + " of a " + commas(window) + " window"}
}

// summaryUsage is the review card's one line of numbers.
func summaryUsage(u *psmithv1.MessageUsage) string {
	if u == nil {
		return ""
	}
	in := int64(u.GetInputTokens() + u.GetCacheReadTokens() + u.GetCacheWriteTokens())
	s := "In " + commas(in)
	if c := u.GetCacheReadTokens(); c > 0 {
		s += " (" + commas(int64(c)) + " cached)"
	}
	s += " · out " + commas(int64(u.GetOutputTokens()))
	if u.TotalCostUsd != nil {
		s += fmt.Sprintf(" · $%.4f", u.GetTotalCostUsd())
	}
	return s
}

// resolvedProfile is the conversation's profile with its parent chain
// applied, or an empty profile.
func (h *Handler) resolvedProfile(ctx context.Context, id string) *psmithv1.Profile {
	if h.profiles == nil || id == "" {
		return &psmithv1.Profile{}
	}
	resp, err := h.profiles.GetProfile(ctx, connect.NewRequest(&psmithv1.GetProfileRequest{Id: id, Resolve: true}))
	if err != nil {
		return &psmithv1.Profile{}
	}
	return resp.Msg.GetProfile()
}

func (h *Handler) profileName(ctx context.Context, id string) string {
	if h.profiles == nil || id == "" {
		return ""
	}
	resp, err := h.profiles.GetProfile(ctx, connect.NewRequest(&psmithv1.GetProfileRequest{Id: id}))
	if err != nil {
		return ""
	}
	return resp.Msg.GetProfile().GetName()
}

// userModels is the caller's enabled models, or nil.
func (h *Handler) userModels(ctx context.Context) []*psmithv1.UserModelEntry {
	if h.models == nil {
		return nil
	}
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{}))
	if err != nil {
		return nil
	}
	return resp.Msg.GetEntries()
}

func (h *Handler) findModel(ctx context.Context, providerID, modelID string) *psmithv1.UserModelEntry {
	for _, e := range h.userModels(ctx) {
		if e.GetProvider().GetId() == providerID && e.GetModel().GetModelId() == modelID {
			return e
		}
	}
	return nil
}

// modelName is a model's display name, or its id when the account no longer
// has it.
func (h *Handler) modelName(ctx context.Context, providerID, modelID string) string {
	if e := h.findModel(ctx, providerID, modelID); e != nil {
		return orName(e.GetModel().GetDisplayName(), modelID)
	}
	return modelID
}

// modelMeta is "model · provider", the failed card's subtitle.
func (h *Handler) modelMeta(ctx context.Context, providerID, modelID string) string {
	e := h.findModel(ctx, providerID, modelID)
	if e == nil {
		return modelID
	}
	return orName(e.GetModel().GetDisplayName(), modelID) + " · " + orName(e.GetProvider().GetLabel(), e.GetProvider().GetType())
}

// compressionModelName names the model a running compression uses: the
// profile's compression model, else the conversation's.
func (h *Handler) compressionModelName(ctx context.Context, conv *psmithv1.Conversation) string {
	p := h.resolvedProfile(ctx, conv.GetProfileId())
	if p.GetCompressionProviderId() != "" {
		return h.modelName(ctx, p.GetCompressionProviderId(), p.GetCompressionModelId())
	}
	if pid, mid, ok := splitModelValue(currentSettingsModel(conv)); ok {
		return h.modelName(ctx, pid, mid)
	}
	return ""
}
