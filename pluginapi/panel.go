package pluginapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// PanelProvider is implemented by plugins that contribute a surface to the
// composer's add menu.
//
// The point of this interface is that clients render panels without knowing
// which plugin produced them. A panel's body is []ContentPart — the same
// structure ContentRenderer emits into a message — so the client draws it with
// the fragment renderer it already has. A plugin that wants a list of things
// with titles, descriptions and state emits a `card_list`; it does not ship a
// view, and the app has no switch on plugin name.
//
// The cost of that is real: a panel can only express what the fragment
// vocabulary can express. That is the intended trade. A plugin needing a
// bespoke form is a signal to grow the vocabulary, which every plugin then
// gets, rather than to special-case one plugin in every client.
type PanelProvider interface {
	// Panel describes the menu entry. Called on a config-only instance at
	// describe time, so it must not depend on conversation state.
	Panel() PanelDescriptor

	// RenderPanel builds the panel body for one conversation. The context
	// carries the same host capabilities tool dispatch gets.
	//
	// Returning an error surfaces to the user; returning zero parts renders
	// the panel's empty state rather than an error, because "nothing to show
	// yet" is a normal condition and not a failure.
	RenderPanel(ctx context.Context) ([]ContentPart, error)
}

// PanelDescriptor is the menu entry: what the user taps to open the panel.
type PanelDescriptor struct {
	// Title labels the menu entry and the panel itself.
	Title string
	// SFSymbol names the icon. Apple clients render it directly; other
	// clients are free to ignore it. A name no client recognises degrades to
	// no icon rather than an error.
	SFSymbol string
	// Subtitle is optional one-line context under the menu entry.
	Subtitle string
}

// ActionHandler is implemented by plugins that accept actions from a panel.
//
// This is the return path the fragment vocabulary was missing. `compose:`,
// `send:` and `external:` all terminate in the client; nothing carried intent
// back to the plugin that drew the UI. A fragment action of the form
// `plugin:<action>?<k>=<v>` reaches HandleAction on the plugin that rendered
// it, so a panel can be interactive without the client knowing what the
// interaction means.
//
// Handlers run outside a send. The context carries host capabilities, so an
// action can read and write the plugin's own state. Whatever it changes shows
// up when the client re-renders the panel, which it does after every action.
type ActionHandler interface {
	HandleAction(ctx context.Context, action string, params map[string]string) error
}

// ErrUnknownAction is what a handler returns for an action it does not
// recognise. Clients can be newer than servers, so an unknown action is a
// version skew to report rather than a crash.
var ErrUnknownAction = errors.New("unknown plugin action")

// PanelActionScheme prefixes fragment actions routed back to a plugin.
const PanelActionScheme = "plugin:"

// ParsePanelAction splits a `plugin:<action>?<k>=<v>&…` fragment action.
//
// Returns ok=false for anything that is not a plugin action, so a caller can
// hand it any action string and let the parser decide.
func ParsePanelAction(raw string) (action string, params map[string]string, ok bool) {
	if !strings.HasPrefix(raw, PanelActionScheme) {
		return "", nil, false
	}
	rest := strings.TrimPrefix(raw, PanelActionScheme)
	if rest == "" {
		return "", nil, false
	}

	name, query, hasQuery := strings.Cut(rest, "?")
	if name == "" {
		return "", nil, false
	}
	params = map[string]string{}
	if hasQuery {
		// Tolerate a malformed query rather than dropping the action: the
		// action name is the load-bearing half, and a client that encoded a
		// value badly should get a clear handler error, not silence.
		if vs, err := url.ParseQuery(query); err == nil {
			for k := range vs {
				params[k] = vs.Get(k)
			}
		}
	}
	return name, params, true
}

// BuildPanelAction is the inverse, so plugins compose actions instead of
// formatting strings by hand and getting the escaping wrong.
func BuildPanelAction(action string, params map[string]string) string {
	if len(params) == 0 {
		return PanelActionScheme + action
	}
	vs := url.Values{}
	for k, v := range params {
		vs.Set(k, v)
	}
	return fmt.Sprintf("%s%s?%s", PanelActionScheme, action, vs.Encode())
}

// --- Pipeline fan-out ---------------------------------------------------

// PanelFor finds the plugin owning a named panel and renders it.
//
// Looks the plugin up by name rather than trusting an index, because the
// pipeline a client saw when it drew the menu may not be the pipeline that
// resolves now (a profile edit, a conversation-level override). A stale name
// is a clean not-found instead of the wrong plugin's panel.
func (p Pipeline) PanelFor(ctx context.Context, pluginName string, decorate func(context.Context, string) context.Context) ([]ContentPart, error) {
	for _, pl := range p {
		if pl.Name() != pluginName {
			continue
		}
		provider, ok := pl.(PanelProvider)
		if !ok {
			return nil, fmt.Errorf("plugin %q has no panel", pluginName)
		}
		pctx := ctx
		if decorate != nil {
			pctx = decorate(ctx, pluginName)
		}
		return provider.RenderPanel(pctx)
	}
	return nil, fmt.Errorf("plugin %q is not active on this conversation", pluginName)
}

// DispatchAction routes a panel action to its plugin.
func (p Pipeline) DispatchAction(ctx context.Context, pluginName, action string, params map[string]string, decorate func(context.Context, string) context.Context) error {
	for _, pl := range p {
		if pl.Name() != pluginName {
			continue
		}
		handler, ok := pl.(ActionHandler)
		if !ok {
			return fmt.Errorf("plugin %q does not accept actions", pluginName)
		}
		pctx := ctx
		if decorate != nil {
			pctx = decorate(ctx, pluginName)
		}
		return handler.HandleAction(pctx, action, params)
	}
	return fmt.Errorf("plugin %q is not active on this conversation", pluginName)
}

// NewCardListPart is a helper for the common panel shape: a list of things
// with a title, a description, optional state badges, and an action.
//
// Exists so plugins do not hand-roll the props JSON and drift from what the
// renderer expects. The schema is documented in pluginapi/CONTENT_RENDERERS.md.
func NewCardListPart(key string, items []Card) ContentPart {
	props, err := json.Marshal(map[string]any{"items": items})
	if err != nil {
		// Cards are plugin-authored structs with no unmarshalable fields, so
		// this cannot fail in practice. Emitting an empty list beats
		// propagating an error nobody can act on.
		props = []byte(`{"items":[]}`)
	}
	return NewFragmentPart("card_list", props, key)
}

// Card is one row of a card_list.
type Card struct {
	Title       string   `json:"title"`
	Description string   `json:"description,omitempty"`
	Badges      []string `json:"badges,omitempty"`
	Action      string   `json:"action,omitempty"`
}
