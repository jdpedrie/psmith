package web

import (
	"net/url"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
)

// A refused delete says why in words a person can act on, not the
// service's "profile has dependent rows".
func TestProfileDelete_RefusalSaysWhy(t *testing.T) {
	t.Parallel()
	e := newSetbEnv(t)
	chief := e.profile(t, "Chief", "")
	e.profile(t, "Demo", chief)
	body := e.shown(t, e.post(e.h.handleProfileDelete, "/", map[string]string{"id": chief}, url.Values{"from": {"list"}}))
	if !strings.Contains(body, "Chief can&#39;t be deleted while Demo inherits from it.") || strings.Contains(body, "dependent rows") {
		t.Fatalf("child refusal not worded: %s", body)
	}

	used := e.profile(t, "Pirate", "")
	cid, _ := uuid.NewV7()
	if _, err := e.q.CreateConversation(e.ctx, store.CreateConversationParams{ID: cid, UserID: e.uid, ProfileID: uuid.MustParse(used)}); err != nil {
		t.Fatal(err)
	}
	body = e.shown(t, e.post(e.h.handleProfileDelete, "/", map[string]string{"id": used}, url.Values{}))
	if !strings.Contains(body, "Pirate can&#39;t be deleted while conversations use it.") {
		t.Fatalf("conversation refusal not worded: %s", body)
	}
}
