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

	"github.com/jdpedrie/psmith/server/store"
)

type inspPacks struct {
	Packs []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
		Body string `json:"body"`
	} `json:"packs"`
	Announce *bool `json:"announce_to_model"`
}

func (e *browserEnv) inspPacks(t *testing.T) inspPacks {
	t.Helper()
	var out inspPacks
	if err := json.Unmarshal(e.inspConvPlugins(t)["context_packs"].ConfigEncrypted, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// Context Packs' packs edit as rows in the inspector: open one and change
// it, Add a pack, flip the switch, Save; then Delete one. Each step keeps
// what was typed, and the ids the delivery ledger keys off survive.
func TestBrowser_InspPluginListEditor(t *testing.T) {
	e := newBrowserEnv(t)
	cfg := `{"packs":[{"id":"p1","name":"Style guide","description":"House style","body":"Use sentence case."}],"announce_to_model":true}`
	if _, err := e.q.InsertConversationPlugin(context.Background(), store.InsertConversationPluginParams{ConversationID: uuid.MustParse(e.convID), PluginName: "context_packs", ConfigEncrypted: []byte(cfg)}); err != nil {
		t.Fatal(err)
	}
	form := `#inspector form[action$="/plugin/context_packs"]`
	e.open(t, "/c/"+e.convID+"/plugin/context_packs")
	waitUntil(t, e, "rows", `!!document.querySelector('.lrow summary')`, 3*time.Second)
	if n := eval[int](t, e, `document.querySelectorAll('.lrow').length`); n != 1 {
		t.Fatalf("rows = %d", n)
	}

	// Open the row and rename it; Add saves that and opens a blank row.
	e.inspClick(t, ".lrow summary")
	waitUntil(t, e, "open", `!!document.querySelector('.lrow details[open] input[name="lst_packs_0_name"]')`, 2*time.Second)
	if err := chromedp.Run(e.ctx, chromedp.SetValue(`input[name="lst_packs_0_name"]`, "", chromedp.ByQuery), chromedp.SendKeys(`input[name="lst_packs_0_name"]`, "House style guide", chromedp.ByQuery)); err != nil {
		t.Fatal(err)
	}
	e.inspClick(t, form+` button[name="add_row"]`)
	waitUntil(t, e, "blank row", `document.readyState === 'complete' && !!document.querySelector('.lrow details[open] input[name="lst_packs_1_name"]')`, 5*time.Second)
	e.inspShot(t, "list-added")
	if got := e.inspPacks(t); len(got.Packs) != 1 || got.Packs[0].Name != "House style guide" || got.Packs[0].ID != "p1" {
		t.Fatalf("Add didn't keep the edit: %+v", got)
	}

	if err := chromedp.Run(e.ctx,
		chromedp.SendKeys(`input[name="lst_packs_1_name"]`, "Release calendar", chromedp.ByQuery),
		chromedp.SendKeys(`textarea[name="lst_packs_1_body"]`, "Builds ship Thursdays.", chromedp.ByQuery)); err != nil {
		t.Fatal(err)
	}
	e.inspClick(t, form+` button[data-switch="cfg_announce_to_model"]`)
	e.inspClick(t, form+` button.btn.primary[type=submit]`)
	waitUntil(t, e, "saved", `document.readyState === 'complete' && location.search === '?tab=plugins'`, 5*time.Second)
	got := e.inspPacks(t)
	if len(got.Packs) != 2 || got.Packs[1].Name != "Release calendar" || got.Packs[1].Body != "Builds ship Thursdays." || got.Packs[1].ID == "" {
		t.Fatalf("packs after Save = %+v", got.Packs)
	}
	if got.Announce == nil || *got.Announce {
		t.Errorf("the switch didn't save off: %v", got.Announce)
	}

	// Enter in a field saves; it doesn't press the first row's Delete.
	keep := got.Packs[1].ID
	e.open(t, "/c/"+e.convID+"/plugin/context_packs")
	waitUntil(t, e, "rows", `document.querySelectorAll('.lrow').length === 2`, 3*time.Second)
	e.inspClick(t, ".lrow summary")
	if err := chromedp.Run(e.ctx, chromedp.SendKeys(`input[name="lst_packs_0_name"]`, "!"+kb.Enter, chromedp.ByQuery)); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, e, "saved by Enter", `document.readyState === 'complete' && location.search === '?tab=plugins'`, 5*time.Second)
	if got := e.inspPacks(t); len(got.Packs) != 2 || !strings.Contains(got.Packs[0].Name, "!") {
		t.Fatalf("Enter in a field = %+v", got.Packs)
	}

	// Delete the first; the second keeps its id.
	e.open(t, "/c/"+e.convID+"/plugin/context_packs")
	waitUntil(t, e, "rows", `document.querySelectorAll('.lrow').length === 2`, 3*time.Second)
	e.inspClick(t, `button.lrow-del[value="packs.0"]`)
	waitUntil(t, e, "deleted", `document.readyState === 'complete' && document.querySelectorAll('.lrow').length === 1`, 5*time.Second)
	if got := e.inspPacks(t); len(got.Packs) != 1 || got.Packs[0].ID != keep {
		t.Errorf("after Delete = %+v", got.Packs)
	}
}
