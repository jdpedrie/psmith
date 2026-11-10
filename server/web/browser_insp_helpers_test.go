package web

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
)

// Helpers for the inspector's browser tests.

// inspActiveContext is the conversation's active context, read from the
// database.
func (e *browserEnv) inspActiveContext(t *testing.T) uuid.UUID {
	t.Helper()
	rows, err := e.q.ListContextsByConversation(context.Background(), uuid.MustParse(e.convID))
	if err != nil || len(rows) == 0 {
		t.Fatalf("ListContextsByConversation: %v (%d rows)", err, len(rows))
	}
	best := rows[0]
	for _, r := range rows[1:] {
		if r.ContextActivationTime.After(best.ContextActivationTime) {
			best = r
		}
	}
	return best.ID
}

// inspSeedTurns appends question and answer pairs to a context's newest
// message, so a test starts with a transcript without streaming it.
func (e *browserEnv) inspSeedTurns(t *testing.T, ctxID uuid.UUID, pairs ...string) {
	t.Helper()
	ctx := context.Background()
	var parent *uuid.UUID
	if leaf, err := e.q.GetContextLeafMessage(ctx, ctxID); err == nil {
		parent = &leaf.ID
	}
	pid := uuid.MustParse(e.providerID)
	model := "claude-fake"
	for i, text := range pairs {
		id, _ := uuid.NewV7()
		p := store.CreateMessageParams{ID: id, ContextID: ctxID, ParentID: parent, Role: "user", Content: text}
		if i%2 == 1 {
			p.Role, p.ProviderID, p.ModelID = "assistant", &pid, &model
		}
		if _, err := e.q.CreateMessage(ctx, p); err != nil {
			t.Fatalf("CreateMessage: %v", err)
		}
		parent = &id
		time.Sleep(2 * time.Millisecond)
	}
}

// inspClick clicks the first element matching a CSS selector, the way a person
// does: a real mouse event at its position.
func (e *browserEnv) inspClick(t *testing.T, sel string) {
	t.Helper()
	if err := chromedp.Run(e.ctx, chromedp.ScrollIntoView(sel, chromedp.ByQuery), chromedp.Click(sel, chromedp.ByQuery)); err != nil {
		t.Fatalf("click %s: %v", sel, err)
	}
}

// inspWaitPath waits for the page to land on a path (and finish loading).
func inspWaitPath(t *testing.T, e *browserEnv, path string) {
	t.Helper()
	waitUntil(t, e, "path "+path, fmt.Sprintf(`location.pathname + location.search === %q && document.readyState === "complete"`, path), 8*time.Second)
}

// inspShot saves a screenshot of the page to the test's output directory.
func (e *browserEnv) inspShot(t *testing.T, name string) {
	t.Helper()
	var b []byte
	if err := chromedp.Run(e.ctx, chromedp.CaptureScreenshot(&b)); err != nil {
		t.Fatalf("screenshot: %v", err)
	}
	_ = os.WriteFile(filepath.Join(e.out, name+".png"), b, 0o644)
}

// inspText is an element's innerText, or "" when it isn't there.
func inspText(t *testing.T, e *browserEnv, sel string) string {
	t.Helper()
	return eval[string](t, e, fmt.Sprintf(`(document.querySelector(%q) || {innerText: ""}).innerText`, sel))
}

func inspDeref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}

// inspNewContext starts a fresh active context, as a promoted compression
// would, and returns it.
func (e *browserEnv) inspNewContext(t *testing.T) uuid.UUID {
	t.Helper()
	ctx := context.Background()
	parent := e.inspActiveContext(t)
	id, _ := uuid.NewV7()
	time.Sleep(5 * time.Millisecond)
	if _, err := e.q.CreateContext(ctx, store.CreateContextParams{ID: id, ConversationID: uuid.MustParse(e.convID), ParentContextID: &parent, ContextActivationTime: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	return id
}
