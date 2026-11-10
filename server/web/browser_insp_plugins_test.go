package web

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	_ "github.com/jdpedrie/psmith/plugins/context_packs"
	"github.com/jdpedrie/psmith/server/store"
)

// inspConvPlugins reads the conversation's plugin overrides from the
// database: name to (disabled, config).
func (e *browserEnv) inspConvPlugins(t *testing.T) map[string]store.ConversationPlugin {
	t.Helper()
	rows, err := e.q.ListConversationPlugins(context.Background(), uuid.MustParse(e.convID))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]store.ConversationPlugin{}
	for _, r := range rows {
		out[r.PluginName] = r
	}
	return out
}

// The Plugins tab: Add plugin puts one on this conversation only; the
// profile's plugins switch off here and back on with Save; × removes a
// conversation plugin.
func TestBrowser_InspPluginsAddToggleRemove(t *testing.T) {
	e := newBrowserEnv(t)
	conv, err := e.q.GetConversationByID(context.Background(), uuid.MustParse(e.convID))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{ProfileID: conv.ProfileID, Ordinal: 0, PluginName: "basic_grounding"}); err != nil {
		t.Fatal(err)
	}
	e.open(t, "/c/"+e.convID+"?tab=plugins")
	waitUntil(t, e, "plugins tab", `!!document.getElementById('insp-plugins')`, 3*time.Second)

	// Switch the profile's plugin off: the switch flips, the bar counts it.
	e.inspClick(t, `#insp-plugins button[data-switch="on_basic_grounding"]`)
	waitUntil(t, e, "switch off", `document.querySelector('#insp-plugins button[data-switch="on_basic_grounding"]').getAttribute('aria-checked') === 'false' && !document.querySelector('#insp-plugins [data-savebar]').hidden`, 2*time.Second)
	e.inspShot(t, "switched-off")
	e.inspClick(t, "#insp-plugins [data-savebar] button[type=submit]")
	waitUntil(t, e, "saved", `document.readyState === 'complete' && !!document.querySelector('#insp-plugins li.plug.off')`, 5*time.Second)
	if p, ok := e.inspConvPlugins(t)["basic_grounding"]; !ok || !p.Disabled {
		t.Fatalf("basic_grounding isn't off for the conversation: %+v", p)
	}

	// And back on.
	e.inspClick(t, `#insp-plugins button[data-switch="on_basic_grounding"]`)
	e.inspClick(t, "#insp-plugins [data-savebar] button[type=submit]")
	waitUntil(t, e, "back on", `document.readyState === 'complete' && !!document.getElementById('insp-plugins') && !document.querySelector('#insp-plugins li.plug.off')`, 5*time.Second)
	if _, ok := e.inspConvPlugins(t)["basic_grounding"]; ok {
		t.Error("switching it back on left an override behind")
	}

	// Add Context Packs from the menu.
	e.inspClick(t, "#insp-plugins details.add-plug > summary")
	e.inspClick(t, `#insp-plugins details.add-plug button[value="context_packs"]`)
	waitUntil(t, e, "added", `document.readyState === 'complete' && !!document.querySelector('#insp-plugins button.plug-x[value="context_packs"]')`, 5*time.Second)
	if _, ok := e.inspConvPlugins(t)["context_packs"]; !ok {
		t.Fatal("Context Packs isn't on the conversation after Add")
	}

	// Remove it with ×.
	e.inspClick(t, `#insp-plugins button.plug-x[value="context_packs"]`)
	waitUntil(t, e, "removed", `document.readyState === 'complete' && !!document.getElementById('insp-plugins') && !document.querySelector('#insp-plugins button.plug-x[value="context_packs"]')`, 5*time.Second)
	if _, ok := e.inspConvPlugins(t)["context_packs"]; ok {
		t.Error("Context Packs is still on the conversation after ×")
	}
}

// Configure on a conversation plugin whose settings include a list (Context
// Packs' packs) must not turn the list into a text field and save a string
// over it.
func TestBrowser_InspPluginConfigKeepsListFields(t *testing.T) {
	e := newBrowserEnv(t)
	cfg := `{"packs":[{"id":"p1","name":"Style guide","description":"House style","body":"Use sentence case."}],"announce_to_model":true}`
	if _, err := e.q.InsertConversationPlugin(context.Background(), store.InsertConversationPluginParams{ConversationID: uuid.MustParse(e.convID), PluginName: "context_packs", ConfigEncrypted: []byte(cfg)}); err != nil {
		t.Fatal(err)
	}
	e.open(t, "/c/"+e.convID+"/plugin/context_packs")
	waitUntil(t, e, "config view", `!!document.querySelector('#inspector form[action$="/plugin/context_packs"]')`, 3*time.Second)
	e.inspShot(t, "config")
	e.inspClick(t, `#inspector form[action$="/plugin/context_packs"] button.btn.primary[type=submit]`)
	waitUntil(t, e, "saved", `document.readyState === 'complete' && location.search === '?tab=plugins'`, 5*time.Second)

	got := e.inspConvPlugins(t)["context_packs"]
	var parsed struct {
		Packs []struct {
			Name string `json:"name"`
		} `json:"packs"`
	}
	if err := json.Unmarshal(got.ConfigEncrypted, &parsed); err != nil || len(parsed.Packs) != 1 || parsed.Packs[0].Name != "Style guide" {
		t.Errorf("saving the config view changed the packs: %s (%v)", got.ConfigEncrypted, err)
	}
}

// A plugin panel opens from the Plugins tab, and choosing a card runs the
// plugin's action in place: the card turns on and says what happens next.
func TestBrowser_InspPluginPanelAction(t *testing.T) {
	e := newBrowserEnv(t)
	cfg := `{"packs":[{"id":"p1","name":"Style guide","description":"House style","body":"Use sentence case."}]}`
	if _, err := e.q.InsertConversationPlugin(context.Background(), store.InsertConversationPluginParams{ConversationID: uuid.MustParse(e.convID), PluginName: "context_packs", ConfigEncrypted: []byte(cfg)}); err != nil {
		t.Fatal(err)
	}
	e.open(t, "/c/"+e.convID+"?tab=plugins")
	e.inspClick(t, `#insp-plugins a.plug-link[href$="/panel/context_packs"]`)
	inspWaitPath(t, e, "/c/"+e.convID+"/panel/context_packs")
	waitUntil(t, e, "card", `!!document.querySelector('#panel-parts button.plug-card')`, 3*time.Second)
	e.inspShot(t, "panel")
	e.inspClick(t, `#panel-parts button.plug-card`)
	waitUntil(t, e, "armed", `!!document.querySelector('#panel-parts button.plug-card.on') && document.getElementById('panel-parts').innerText.includes('Sends next')`, 4*time.Second)
	if p := eval[string](t, e, `location.pathname`); p != "/c/"+e.convID+"/panel/context_packs" {
		t.Errorf("the action navigated to %s instead of swapping in place", p)
	}
	// It holds across a reload: the server stored it.
	e.open(t, "/c/"+e.convID+"/panel/context_packs")
	if !strings.Contains(inspText(t, e, "#panel-parts"), "Sends next") {
		t.Error("the armed pack didn't survive a reload")
	}
	e.inspShot(t, "panel-armed")
}

// An open panel follows the conversation: once a send delivers the armed
// pack, the card says so without a reload.
func TestBrowser_InspPluginPanelFollowsReplies(t *testing.T) {
	e := newBrowserEnv(t)
	cfg := `{"packs":[{"id":"p1","name":"Style guide","description":"House style","body":"Use sentence case."}]}`
	if _, err := e.q.InsertConversationPlugin(context.Background(), store.InsertConversationPluginParams{ConversationID: uuid.MustParse(e.convID), PluginName: "context_packs", ConfigEncrypted: []byte(cfg)}); err != nil {
		t.Fatal(err)
	}
	e.fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Noted.", Delay: 100 * time.Millisecond}}})
	e.open(t, "/c/"+e.convID+"/panel/context_packs")
	e.inspClick(t, `#panel-parts button.plug-card`)
	waitUntil(t, e, "armed", `document.getElementById('panel-parts').innerText.includes('Sends next')`, 4*time.Second)

	e.keys(t, chromedp.SendKeys(`#composer-text`, "Write the intro", chromedp.ByID), chromedp.KeyEvent(kb.Enter))
	waitUntil(t, e, "reply", `document.getElementById('messages').innerText.includes('Noted.')`, 8*time.Second)
	end := time.Now().Add(4 * time.Second)
	for time.Now().Before(end) && !strings.Contains(inspText(t, e, "#panel-parts"), "Delivered") {
		time.Sleep(150 * time.Millisecond)
	}
	if got := inspText(t, e, "#panel-parts"); !strings.Contains(got, "Delivered") {
		t.Errorf("the panel still reads %q after the pack went out", got)
	}
}
