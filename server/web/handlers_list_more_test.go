package web

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"testing"
)

// listMoreHref pulls the Show more button's URL out of a rendered list.
func listMoreHref(t *testing.T, body string) string {
	t.Helper()
	m := regexp.MustCompile(`class="btn h28 ghost more-rows" hx-get="([^"]+)"`).FindStringSubmatch(body)
	if m == nil {
		t.Fatal("no Show more button")
	}
	u, _ := url.QueryUnescape(strings.ReplaceAll(m[1], "&amp;", "&"))
	return u
}

// Show more continues the section the first page ended in instead of
// starting it again under a second "Today".
func TestShowMore_ContinuesTheSection(t *testing.T) {
	e := newListEnv(t)
	for i := 0; i < 101; i++ {
		e.newConv(t, fmt.Sprintf("Conversation %03d", i))
	}
	first := e.get(e.h.handleChats, "/chats", nil).Body.String()
	if n := strings.Count(first, `<div class="group-head">Today</div>`); n != 1 {
		t.Fatalf("first page has %d Today heads", n)
	}
	more := e.get(e.h.handleListRowsPartial, listMoreHref(t, first), nil).Body.String()
	if !strings.Contains(more, `data-row=`) {
		t.Fatalf("second page has no rows:\n%s", more)
	}
	if strings.Contains(more, `class="group-head"`) {
		t.Errorf("second page repeats a section head:\n%s", more[:min(len(more), 400)])
	}
}
