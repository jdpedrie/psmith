package web

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// convVM is everything the conversation screen draws: the header, the
// transcript, what sits in the composer's place, and the inspector.
type convVM struct {
	ID          string
	Title       string
	Profile     string
	ProfileID   string
	Color       int
	CtxLabel    string // "Context 2 of 2"
	Model       modelChipVM
	Gauge       gaugeVM
	Items       []msgItem
	RunID       string
	Slot        string // "", "archived", "review"
	ReviewID    string
	Truncated   bool
	Harness     *harnessVM
	Inspector   inspVM
	ShowInsp    bool
	Placeholder string
	Draft       string     // composer text the page opens with
	Pending     []attachVM // attachments waiting to send
	Live        liveInit   // what a streaming reply has shown so far

	Personas   string // "Skeptic, Optimist, Economist" for a council
	ContinueID string // the leaf a "Continue the discussion" extends
	Rename     bool   // the header is the rename form
	DropNote   string // what the drop overlay says the model takes
	JumpShown  bool   // the Jump to latest pill starts visible
	Uploading  int    // pending uploads still in flight
	Dropping   bool   // a file is being dragged over the transcript
}

// liveInit seeds a streaming reply's first paint, before its stream's
// replay arrives.
type liveInit struct {
	Chips []liveChipVM
	HTML  string
}

type modelChipVM struct {
	Value    string // "providerID|modelID"
	Name     string
	Provider string
}

type gaugeVM struct {
	Tokens  int64
	Window  int64
	Warn    int64
	Label   string // "82k"
	State   string // "", "warn", "over"
	Percent float64
	WarnPct float64
}

// msgItem is one row of the transcript.
type msgItem struct {
	ID        string
	ConvID    string
	ParentID  string
	Role      string // "user", "assistant", "summary", "strip", "start", "harness"
	HTML      string
	Text      string // raw text, for copy and edit
	Images    []attachVM
	Files     []attachVM
	Thinking  *thinkVM
	Tools     []toolVM
	Usage     *usageVM
	Branch    *branchVM
	Persona   string
	PersonaN  int
	Error     string
	Strip     string // for Role "strip": the label
	StripLink string

	Edited      bool
	State       string // "", "edit", "delete", "menu", "regen"
	Parts       []fragVM
	ModelValue  string // "providerID|modelID" that produced a reply
	ModelLabel  string // "Claude Opus 4.7 · Anthropic"
	HideActions bool   // a council voice that isn't the last of its run
	Start       *startVM
	Regen       []providerGroupVM // the "Regenerate with" menu, when open
	Harness     *harnessVM
}

type attachVM struct {
	ID, URL, Name, Size string
	Kind                string // "PDF", "PNG", …: the type label on file chips
	Pct                 int    // upload progress; 0 once stored
}

type thinkVM struct {
	Label string // "Thought for 6.2s"
	HTML  string
	Open  bool
}

type toolVM struct {
	Name    string
	Summary string
	Dur     string
	Error   string
	Input   string
	Output  string
	Open    bool
}

type usageVM struct {
	Model  string
	Tokens string
	Cached string // "94% cached", or ""
	Cost   string
	Input  string
	Output string
	CacheR string
	CacheW string
	Reason string

	Open      bool
	ModelName string // "Claude Opus 4.7"
	Provider  string
	Stop      string
	Sent      string
	InCost    string
	OutCost   string
	CacheRC   string
	CacheWC   string
	Total     string
	CachedPct int
	Saved     string // what the cache saved on this reply, or ""
}

type branchVM struct {
	Index, Count int
	PrevID       string
	NextID       string
}

// startVM is what a context started from: the profile's system prompt and,
// after a compression, the summary it was seeded with.
type startVM struct {
	Open         bool
	Prompt       string // rendered
	PromptFrom   string // the profile's name
	PromptID     string
	Summary      string // rendered
	SummaryTitle string // "Summary of context 1"
	SummaryMeta  string // "46 turns · compressed Oct 30"
	SummaryID    string
	Editing      string // the message id being edited in place, if any
	EditText     string
}

// loadConversation builds the conversation screen's view model.
func (h *Handler) loadConversation(ctx context.Context, r *http.Request, id string) (convVM, error) {
	vm := convVM{ID: id, ShowInsp: inspectorOpen(r)}
	getResp, err := h.convos.GetConversation(ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: id}))
	if err != nil {
		return vm, err
	}
	conv := getResp.Msg.GetConversation()
	active := getResp.Msg.GetActiveContext()
	vm.Title = convoTitle(conv)
	vm.Harness = harnessVMFrom(conv.GetHarness())
	vm.ProfileID = conv.GetProfileId()
	vm.Color = profileColor(conv.GetProfileId())
	if h.profiles != nil {
		if p, err := h.profiles.GetProfile(ctx, connect.NewRequest(&psmithv1.GetProfileRequest{Id: conv.GetProfileId()})); err == nil {
			vm.Profile = p.Msg.GetProfile().GetName()
		}
	}
	vm.Placeholder = "Message " + vm.Profile
	if conv.GetArchivedAt() != nil {
		vm.Slot = "archived"
	}

	contexts := h.contextRows(ctx, id, active.GetId())
	vm.Inspector.Contexts = contexts
	vm.CtxLabel = contextLabel(contexts, active.GetId())

	msgsResp, err := h.convos.ListMessages(ctx, connect.NewRequest(&psmithv1.ListMessagesRequest{ContextId: active.GetId()}))
	if err != nil {
		return vm, err
	}
	msgs := msgsResp.Msg.GetMessages()

	pick := h.modelPicker(ctx, id, currentSettingsModel(conv), capsVM{}, vm.Harness)
	vm.Model = modelChipVM{Value: pick.Current.Value, Name: pick.Current.DisplayName, Provider: pick.ProviderLabel(pick.Current.ProviderID)}
	vm.DropNote = dropNote(pick.Current)

	tree := h.branchTree(ctx, active.GetId(), msgs)
	vm.Items = h.buildItems(ctx, id, msgs, tree, modelNames(pick))
	finishItems(vm.Items)

	var lead []msgItem
	if vm.Harness != nil {
		lead = append(lead, msgItem{Role: "harness", ConvID: id, Harness: vm.Harness})
	}
	if active.GetParentContextId() != "" && len(contexts) > 1 {
		start := h.startOf(ctx, active, msgs, vm.Profile)
		start.SummaryTitle = "Summary of context " + ordinalOf(contexts, active.GetParentContextId())
		label := "Context " + ordinalOf(contexts, active.GetId()) + " · started from a summary"
		if n := h.turnsIn(ctx, active.GetParentContextId()); n > 0 {
			label += fmt.Sprintf(" of %d turns", n)
			start.SummaryMeta = fmt.Sprintf("%d turns · %s", n, start.SummaryMeta)
		}
		lead = append(lead, msgItem{Role: "start", ConvID: id, Strip: label, Start: start})
	}
	vm.Items = append(lead, vm.Items...)

	for _, m := range msgs {
		if m.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY && m.GetErrorText() == "" && vm.Slot == "" {
			vm.Slot, vm.ReviewID, vm.Truncated = "review", m.GetId(), isTruncatedFinish(m.GetFinishReason())
		}
	}
	vm.Personas = personasOf(vm.Items)
	if n := len(vm.Items); n > 0 {
		if last := vm.Items[n-1]; last.Role == "assistant" && last.Persona != "" {
			vm.ContinueID = last.ID
		}
	}

	vm.Gauge = h.gauge(ctx, active, pick.Current.ContextWindow)
	vm.Inspector.Tab = "context"
	vm.Inspector.Cost = fmt.Sprintf("$%.4f", active.GetCumulativeCostUsd())
	vm.Inspector.Turns, vm.Inspector.Cache, vm.Inspector.Changes = turnStats(msgs)
	h.fillInspector(ctx, r, &vm, conv, active, msgs)
	return vm, nil
}

// dropNote is the drop overlay's second line: what the current model reads.
func dropNote(m pickerModelVM) string {
	name := m.DisplayName
	if name == "" {
		name = "This model"
	}
	if m.Caps.Vision {
		return name + " takes images and PDFs."
	}
	return name + " takes files as documents, not images."
}

// modelNames maps "providerID|modelID" to the model's and provider's labels.
func modelNames(p pickerData) map[string][2]string {
	out := map[string][2]string{}
	for _, g := range p.Groups {
		for _, m := range g.Models {
			out[m.Value] = [2]string{m.DisplayName, g.Label}
		}
	}
	return out
}

// startOf reads the active context's seed: its system prompt and the summary
// it was promoted from.
func (h *Handler) startOf(ctx context.Context, active *psmithv1.Context, msgs []*psmithv1.Message, profile string) *startVM {
	s := &startVM{PromptFrom: profile}
	for _, m := range msgs {
		switch m.GetRole() {
		case psmithv1.MessageRole_MESSAGE_ROLE_SYSTEM:
			if s.PromptID == "" {
				s.PromptID, s.Prompt = m.GetId(), renderMarkdown(m.GetContent())
			}
		case psmithv1.MessageRole_MESSAGE_ROLE_CONTEXT:
			if s.SummaryID == "" {
				s.SummaryID, s.Summary = m.GetId(), renderMarkdown(m.GetContent())
			}
		}
	}
	if ts := active.GetCreatedAt(); ts != nil {
		s.SummaryMeta = "compressed " + ts.AsTime().Format("Jan 2")
	}
	return s
}

// turnsIn counts the user turns on a context's current chain.
func (h *Handler) turnsIn(ctx context.Context, contextID string) int {
	resp, err := h.convos.ListMessages(ctx, connect.NewRequest(&psmithv1.ListMessagesRequest{ContextId: contextID}))
	if err != nil {
		return 0
	}
	n := 0
	for _, m := range resp.Msg.GetMessages() {
		if m.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_USER {
			n++
		}
	}
	return n
}

// personasOf lists a council's voices in the order they first spoke.
func personasOf(items []msgItem) string {
	var names []string
	seen := map[string]bool{}
	for _, it := range items {
		if it.Persona != "" && !seen[it.Persona] {
			seen[it.Persona] = true
			names = append(names, it.Persona)
		}
	}
	return strings.Join(names, ", ")
}

// finishItems sets what depends on a row's neighbors: a council voice shows
// its actions only at the end of a run of voices, and a choice the user then
// sent reads as chosen.
func finishItems(items []msgItem) {
	for i := range items {
		next := (*msgItem)(nil)
		if i+1 < len(items) {
			next = &items[i+1]
		}
		if items[i].Persona != "" && next != nil && next.Role == "assistant" && next.Persona != "" {
			items[i].HideActions = true
		}
		if next != nil && next.Role == "user" {
			for p := range items[i].Parts {
				for c := range items[i].Parts[p].Choices {
					ch := &items[i].Parts[p].Choices[c]
					if ch.Payload != "" && strings.TrimSpace(next.Text) == ch.Payload {
						ch.Chosen = true
					}
				}
			}
		}
	}
}

// inspectorOpen reads the inspector's open state, a per-browser preference.
func inspectorOpen(r *http.Request) bool {
	c, err := r.Cookie("psmith_inspector")
	return err != nil || c.Value != "0"
}

func contextLabel(rows []ctxRowVM, activeID string) string {
	if len(rows) == 0 {
		return ""
	}
	return fmt.Sprintf("Context %s of %d", ordinalOf(rows, activeID), len(rows))
}

func ordinalOf(rows []ctxRowVM, id string) string {
	for i, r := range rows {
		if r.ID == id {
			return fmt.Sprint(i + 1)
		}
	}
	return fmt.Sprint(len(rows))
}

// gauge is the header's context meter: the active context's size against the
// model's window and the user's warning level.
func (h *Handler) gauge(ctx context.Context, active *psmithv1.Context, window int32) gaugeVM {
	g := gaugeVM{Tokens: active.GetLastMessageTotalTokens(), Window: int64(window)}
	g.Warn = h.warnTokens(ctx)
	g.Label = abbrevTokens(int32(g.Tokens))
	if g.Tokens == 0 {
		g.Label = "0"
	}
	if g.Window > 0 {
		g.Percent = min(100, float64(g.Tokens)*100/float64(g.Window))
		g.WarnPct = float64(g.Warn) * 100 / float64(g.Window)
		if g.Tokens >= g.Window*9/10 {
			g.State = "over"
		}
	}
	if g.State == "" && g.Warn > 0 && g.Tokens >= g.Warn {
		g.State = "warn"
	}
	return g
}

// branchTree maps each parent to its children, oldest first, so the
// transcript can offer "2 of 3" and a branch switch can walk down. Only
// chains the server says have siblings cost a full-tree read.
func (h *Handler) branchTree(ctx context.Context, contextID string, chain []*psmithv1.Message) map[string][]string {
	need := false
	for _, m := range chain {
		if m.GetSiblingCount() > 0 {
			need = true
			break
		}
	}
	if !need {
		return nil
	}
	return h.fullTree(ctx, contextID)
}

func (h *Handler) fullTree(ctx context.Context, contextID string) map[string][]string {
	resp, err := h.convos.ListMessages(ctx, connect.NewRequest(&psmithv1.ListMessagesRequest{ContextId: contextID, FullTree: true, StructureOnly: true}))
	if err != nil {
		return nil
	}
	all := resp.Msg.GetMessages()
	sort.SliceStable(all, func(i, j int) bool { return all[i].GetCreatedAt().AsTime().Before(all[j].GetCreatedAt().AsTime()) })
	byParent := map[string][]string{}
	for _, m := range all {
		byParent[m.GetParentId()] = append(byParent[m.GetParentId()], m.GetId())
	}
	return byParent
}

// newestLeaf walks from id down to its newest descendant: the tip a branch
// switch lands on.
func newestLeaf(tree map[string][]string, id string) string {
	for range 10000 {
		kids := tree[id]
		if len(kids) == 0 {
			return id
		}
		id = kids[len(kids)-1]
	}
	return id
}

func (h *Handler) buildItems(ctx context.Context, convID string, msgs []*psmithv1.Message, tree map[string][]string, names map[string][2]string) []msgItem {
	out := make([]msgItem, 0, len(msgs))
	for _, m := range msgs {
		role := roleClass(m.GetRole())
		if role == "system" || m.GetIsWelcome() && m.GetContent() == "" {
			continue
		}
		if m.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY {
			role = "summary"
		}
		content := m.GetContent()
		if dc := m.GetDisplayContent(); dc != "" {
			content = dc
		}
		it := msgItem{ID: m.GetId(), ConvID: convID, ParentID: m.GetParentId(), Role: role, Text: content, HTML: renderMarkdown(content),
			Persona: m.GetPersona(), PersonaN: int(m.GetPersonaIndex()), Error: m.GetErrorText(), Edited: m.GetEditedAt() != nil}
		it.Images, it.Files = h.attachmentsOf(ctx, m.GetAttachments())
		if t := m.GetThinkingRenderedText(); t != "" || len(m.GetThinking()) > 0 {
			label := "Thought"
			if d := m.GetThinkingDurationMs(); d > 0 {
				label = fmt.Sprintf("Thought for %.1fs", float64(d)/1000)
			}
			it.Thinking = &thinkVM{Label: label, HTML: renderMarkdown(t)}
		}
		for _, tc := range m.GetToolCalls() {
			it.Tools = append(it.Tools, toolVM{Name: tc.GetName(), Summary: toolSummary(tc.GetInput()), Dur: fmt.Sprintf("%.1fs", float64(tc.GetElapsedMs())/1000),
				Error: tc.GetError(), Input: prettyJSON(tc.GetInput()), Output: prettyJSON(tc.GetOutput())})
		}
		if len(m.GetUiFragments()) > 0 {
			it.Parts = fragmentsOf(m.GetUiFragments())
		}
		if m.GetProviderId() != "" {
			it.ModelValue = modelValue(m.GetProviderId(), m.GetModelId())
			n := names[it.ModelValue]
			if n[0] == "" {
				n[0] = m.GetModelId()
			}
			it.ModelLabel = n[0]
			if n[1] != "" {
				it.ModelLabel += " · " + n[1]
			}
			if role == "assistant" && m.GetUsage() != nil {
				it.Usage = usageOf(m)
				it.Usage.ModelName, it.Usage.Provider = n[0], n[1]
			}
		}
		if sibs := tree[m.GetParentId()]; len(sibs) > 1 {
			for i, s := range sibs {
				if s == m.GetId() {
					b := &branchVM{Index: i + 1, Count: len(sibs)}
					if i > 0 {
						b.PrevID = sibs[i-1]
					}
					if i+1 < len(sibs) {
						b.NextID = sibs[i+1]
					}
					it.Branch = b
				}
			}
		}
		out = append(out, it)
	}
	return out
}

// attachmentsOf splits a message's files into images (drawn as tiles) and
// everything else (drawn as download chips).
func (h *Handler) attachmentsOf(ctx context.Context, atts []*psmithv1.MessageAttachment) (images, files []attachVM) {
	for _, a := range atts {
		av := attachVM{ID: a.GetFileId(), Name: a.GetOriginalFilename(), Size: humanBytes(a.GetSizeBytes()), Kind: kindLabel(a.GetMimeType(), a.GetOriginalFilename())}
		if av.Name == "" {
			av.Name = "Attachment"
		}
		av.URL = h.signedImageURL(ctx, a.GetFileId())
		if a.GetKind() == "image" {
			images = append(images, av)
		} else {
			files = append(files, av)
		}
	}
	return images, files
}

// kindLabel is the short type on a file chip: "PDF", "PNG", "Text".
func kindLabel(mime, name string) string {
	switch {
	case mime == "application/pdf":
		return "PDF"
	case strings.HasPrefix(mime, "text/"):
		return "Text"
	}
	if i := strings.LastIndexByte(name, '.'); i >= 0 && i < len(name)-1 && len(name)-i <= 6 {
		return strings.ToUpper(name[i+1:])
	}
	if i := strings.IndexByte(mime, '/'); i >= 0 {
		return strings.ToUpper(mime[i+1:])
	}
	return "File"
}

func usageOf(m *psmithv1.Message) *usageVM {
	u := m.GetUsage()
	total := u.GetInputTokens() + u.GetOutputTokens() + u.GetCacheReadTokens() + u.GetCacheWriteTokens()
	vm := &usageVM{Model: shortModel(m.GetModelId()), Tokens: fmt.Sprintf("%s tokens", commas(int64(total)))}
	if in := u.GetInputTokens() + u.GetCacheReadTokens() + u.GetCacheWriteTokens(); in > 0 && u.GetCacheReadTokens() > 0 {
		vm.CachedPct = int(math.Round(float64(u.GetCacheReadTokens()) * 100 / float64(in)))
		vm.Cached = fmt.Sprintf("%d%% cached", vm.CachedPct)
	}
	if u.TotalCostUsd != nil {
		vm.Cost = fmt.Sprintf("$%.3f", u.GetTotalCostUsd())
		vm.Total = fmt.Sprintf("$%.4f", u.GetTotalCostUsd())
	}
	vm.Input, vm.Output = commas(int64(u.GetInputTokens())), commas(int64(u.GetOutputTokens()))
	vm.CacheR, vm.CacheW, vm.Reason = commas(int64(u.GetCacheReadTokens())), commas(int64(u.GetCacheWriteTokens())), commas(int64(u.GetReasoningTokens()))
	vm.InCost, vm.OutCost = dollars4(u.InputCostUsd), dollars4(u.OutputCostUsd)
	vm.CacheRC, vm.CacheWC = dollars4(u.CacheReadCostUsd), dollars4(u.CacheWriteCostUsd)
	// Full-price input, inferred from what the uncached input cost, against
	// what the cached tokens actually cost.
	if u.GetInputTokens() > 0 && u.InputCostUsd != nil && u.GetCacheReadTokens() > 0 {
		perToken := u.GetInputCostUsd() / float64(u.GetInputTokens())
		if saved := perToken*float64(u.GetCacheReadTokens()) - u.GetCacheReadCostUsd(); saved > 0 {
			vm.Saved = fmt.Sprintf("$%.4f", saved)
		}
	}
	vm.Stop = m.GetFinishReason()
	if ts := m.GetCreatedAt(); ts != nil {
		vm.Sent = ts.AsTime().Local().Format("15:04")
	}
	return vm
}

func dollars4(v *float64) string {
	if v == nil {
		return "—"
	}
	return fmt.Sprintf("$%.4f", *v)
}

// shortModel drops the family prefix the header already shows:
// "claude-opus-4-7" reads "Opus 4.7".
func shortModel(id string) string {
	s := strings.TrimPrefix(id, "claude-")
	parts := strings.Split(s, "-")
	if len(parts) >= 3 {
		name := strings.ToUpper(parts[0][:1]) + parts[0][1:]
		return name + " " + strings.Join(parts[1:], ".")
	}
	return id
}

func turnStats(msgs []*psmithv1.Message) (turns int, cache string, changes int) {
	last := ""
	for _, m := range msgs {
		switch m.GetRole() {
		case psmithv1.MessageRole_MESSAGE_ROLE_USER:
			turns++
		case psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT:
			key := m.GetProviderId() + "|" + m.GetModelId()
			if last != "" && key != last {
				changes++
			}
			last = key
			if u := m.GetUsage(); u != nil {
				if in := u.GetInputTokens() + u.GetCacheReadTokens() + u.GetCacheWriteTokens(); in > 0 {
					cache = fmt.Sprintf("%d%% hit", u.GetCacheReadTokens()*100/in)
				}
			}
		}
	}
	if cache == "" {
		cache = "None yet"
	}
	return turns, cache, changes
}

func toolSummary(input []byte) string {
	var v map[string]any
	if json.Unmarshal(input, &v) != nil {
		return ""
	}
	keys := make([]string, 0, len(v))
	for k := range v {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if s, ok := v[k].(string); ok && s != "" {
			if len([]rune(s)) > 48 {
				s = string([]rune(s)[:48]) + "…"
			}
			return s
		}
	}
	return ""
}

// warnTokens is the user's context warning level; 0 means none.
func (h *Handler) warnTokens(ctx context.Context) int64 {
	if h.prefs == nil {
		return 0
	}
	resp, err := h.prefs.GetPreferences(ctx, connect.NewRequest(&psmithv1.GetPreferencesRequest{}))
	if err != nil {
		return 0
	}
	return int64(resp.Msg.GetPreferences().GetContextWarningTokens())
}

func humanBytes(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%d KB", n>>10)
	case n > 0:
		return fmt.Sprintf("%d B", n)
	}
	return ""
}

func commas(n int64) string {
	s := fmt.Sprint(n)
	if n < 0 {
		return s
	}
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	return b.String()
}
