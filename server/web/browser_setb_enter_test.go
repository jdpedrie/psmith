package web

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"
	"github.com/google/uuid"

	letteredchoices "github.com/jdpedrie/psmith/plugins/lettered_choices"
	textinjector "github.com/jdpedrie/psmith/plugins/text_injector"
	"github.com/jdpedrie/psmith/server/store"
)

// Enter in a plugin setting saves the tab. The form's first submit button
// used to be a row's move arrow or Remove, so Enter moved or removed a
// plugin instead.
func TestBrowser_ProfilePluginsEnterSaves(t *testing.T) {
	e := newBrowserEnv(t)
	ctx := context.Background()
	conv, err := e.q.GetConversationByID(ctx, uuid.MustParse(e.convID))
	if err != nil {
		t.Fatal(err)
	}
	pid := conv.ProfileID
	for i, name := range []string{letteredchoices.Name, textinjector.Name} {
		if _, err := e.q.InsertProfilePlugin(ctx, store.InsertProfilePluginParams{ProfileID: pid, Ordinal: int32(i), PluginName: name, ConfigEncrypted: []byte(`{}`)}); err != nil {
			t.Fatal(err)
		}
	}
	e.open(t, "/settings/profiles/"+pid.String()+"/plugins?open="+letteredchoices.Name)
	field := `input[name$="keep_last_n"]`
	if err := chromedp.Run(e.ctx,
		chromedp.WaitVisible(field, chromedp.ByQuery),
		chromedp.SetValue(field, "", chromedp.ByQuery),
		chromedp.SendKeys(field, "3", chromedp.ByQuery),
	); err != nil {
		t.Fatalf("type: %v", err)
	}
	if err := chromedp.Run(e.ctx, chromedp.KeyEvent(kb.Enter)); err != nil {
		t.Fatalf("Enter: %v", err)
	}
	time.Sleep(1500 * time.Millisecond)
	rows, err := e.q.ListProfilePlugins(ctx, pid)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, r := range rows {
		names = append(names, r.PluginName)
	}
	if len(names) != 2 || names[0] != letteredchoices.Name || names[1] != textinjector.Name {
		t.Fatalf("plugins after Enter = %v, want both in their order", names)
	}
	if !strings.Contains(string(rows[0].ConfigEncrypted), `"keep_last_n":3`) {
		t.Error("Enter didn't save the typed setting")
	}
}
