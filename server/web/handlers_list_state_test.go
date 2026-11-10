package web

import (
	"regexp"
	"strings"
	"testing"
)

// A row's rename or delete-confirm link beside an open conversation puts
// only that row in its state; the open conversation's own head and
// inspector stay as they were.
func TestRowStates_DontLeakIntoTheOpenConversation(t *testing.T) {
	e := newListEnv(t)
	open := e.fx.convID.String()
	other := e.newConv(t, "Other")
	path := map[string]string{"id": open}

	page := e.get(e.h.handleConversation, "/c/"+open, path).Body.String()
	m := regexp.MustCompile(`data-row="` + other + `"[\s\S]*?<a role="menuitem"[^>]*href="([^"]+)"[\s\S]*?class="danger" href="([^"]+)"`).FindStringSubmatch(page)
	if m == nil {
		t.Fatal("no row menu for the other conversation")
	}
	rename := strings.ReplaceAll(m[1], "&amp;", "&")
	confirm := strings.ReplaceAll(m[2], "&amp;", "&")

	body := e.get(e.h.handleConversation, rename, path).Body.String()
	mustContain(t, body, `class="ritem rename"`)
	if strings.Contains(body, `id="conv-title"`) {
		t.Errorf("renaming a row (%s) also opened the open conversation's title for renaming", rename)
	}
	body = e.get(e.h.handleConversation, confirm, path).Body.String()
	mustContain(t, body, "Delete “Other”?")
}

// The search box's Rename and Delete commands for the open conversation
// open its own rename and delete confirm, which show at every width.
func TestCommand_RenameAndDeleteOpenTheConversationsOwn(t *testing.T) {
	e := newListEnv(t)
	id := e.fx.convID.String()
	c := e.h.loadCommand(e.ctx, "this conversation", id)
	hrefs := map[string]string{}
	for _, it := range c.Commands {
		hrefs[it.Label] = it.Href
	}
	path := map[string]string{"id": id}
	if h := hrefs["Rename this conversation"]; h == "" {
		t.Fatal("no Rename command")
	} else if body := e.get(e.h.handleConversation, h, path).Body.String(); !strings.Contains(body, `id="conv-title"`) || strings.Contains(body, `class="ritem rename"`) {
		t.Errorf("Rename (%s) should open the title in the head, and only there", h)
	}
	if h := hrefs["Delete this conversation"]; h == "" {
		t.Fatal("no Delete command")
	} else if body := e.get(e.h.handleConversation, h, path).Body.String(); strings.Contains(body, `class="ritem confirm"`) || !strings.Contains(body, "Delete") {
		t.Errorf("Delete (%s) confirms in the list row, which a phone doesn't show", h)
	}
}
