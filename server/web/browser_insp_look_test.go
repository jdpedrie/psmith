package web

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

// TestBrowser_InspLook captures the inspector's views in light mode and
// another theme for a person to look over. It only runs when
// PSMITH_WEB_INSP_LOOK is set.
func TestBrowser_InspLook(t *testing.T) {
	if os.Getenv("PSMITH_WEB_INSP_LOOK") == "" {
		t.Skip("set PSMITH_WEB_INSP_LOOK to capture the inspector's views")
	}
	e := newBrowserEnv(t)
	e.inspSeedTurns(t, e.inspActiveContext(t), "Question", "Answer")
	host := strings.Split(strings.TrimPrefix(e.srv.URL, "http://"), ":")[0]
	for _, look := range [][2]string{{"system", "light"}, {"clay", "dark"}, {"nordic", "light"}} {
		if err := chromedp.Run(e.ctx, chromedp.ActionFunc(func(ctx context.Context) error {
			if err := network.SetCookie(themeCookie, look[0]).WithDomain(host).WithPath("/").Do(ctx); err != nil {
				return err
			}
			return network.SetCookie(modeCookie, look[1]).WithDomain(host).WithPath("/").Do(ctx)
		})); err != nil {
			t.Fatal(err)
		}
		for name, path := range map[string]string{
			"context": "?tab=context", "settings": "?tab=settings", "plugins": "?tab=plugins", "contexts": "?tab=contexts",
			"info": "?tab=info", "compact": "/compact", "model": "/model",
		} {
			p := "/c/" + e.convID + path
			if strings.HasPrefix(path, "/") {
				p = "/c/" + e.convID + path
			}
			e.open(t, p)
			e.inspShot(t, look[0]+"-"+look[1]+"-"+name)
		}
	}
}
