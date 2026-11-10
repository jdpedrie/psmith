package web

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
)

// The cache line is green only when the cache is doing its job.
func TestCacheGood(t *testing.T) {
	t.Parallel()
	for s, want := range map[string]bool{"91% hit": true, "80% hit": true, "79% hit": false, "0% hit": false, "None yet": false, "": false} {
		if got := cacheGood(s); got != want {
			t.Errorf("cacheGood(%q) = %v, want %v", s, got, want)
		}
	}
	html := renderComp(context.Background(), contextTab(convVM{ID: "c", Inspector: inspVM{Cache: "None yet"}}))
	if strings.Contains(html, `class="good"`) {
		t.Error("\"None yet\" renders green")
	}
}

// The context tab's body asks for itself again when the conversation
// changes, and the partial route answers with that body.
func TestInspectorPartial_RefreshesTheContextTab(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	page := f.get(t, f.h.handleConversation, "/c/"+f.conv, nil).Body.String()
	i := strings.Index(page, `id="insp-context"`)
	if i < 0 {
		t.Fatal("no context tab body")
	}
	start := strings.LastIndex(page[:i], "<")
	tag := page[start : start+strings.Index(page[start:], ">")]
	for _, want := range []string{`id="insp-context"`, `hx-get="/c/` + f.conv + `/partials/inspector"`, `hx-trigger="sse:conversation-changed-` + f.conv + `"`} {
		if !strings.Contains(tag, want) {
			t.Errorf("the context tab's body lacks %s: %s", want, tag)
		}
	}
	part := f.get(t, f.h.handleInspectorPartial, "/c/"+f.conv+"/partials/inspector", nil)
	if part.Code != 200 || !strings.Contains(part.Body.String(), `id="insp-context"`) || !strings.Contains(part.Body.String(), "Context size") {
		t.Fatalf("partial: %d %s", part.Code, part.Body.String())
	}
	// The contexts manager keeps its rename field and confirm; it doesn't
	// refresh under the reader.
	manage := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=contexts", nil).Body.String()
	if strings.Contains(manage, `id="insp-context"`) {
		t.Error("the contexts manager refreshes itself")
	}
}

// The delete confirm doesn't count turns a conversation doesn't have.
func TestInfo_DeleteNoteWithoutTurns(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	body := f.get(t, f.h.handleConversation, "/c/"+f.conv+"?tab=info&confirm=delete", nil).Body.String()
	if strings.Contains(body, "0 turns are deleted") {
		t.Error("the confirm says \"all 0 turns are deleted\"")
	}
	if !strings.Contains(body, "Its context is deleted for good. Archive keeps it instead.") {
		t.Error("the confirm lacks the empty conversation's note")
	}
}

// With nothing to summarize, Compress is drawn off, as on the Mac, rather
// than opening a card whose Start can only fail.
func TestContextTab_CompressOffWhenEmpty(t *testing.T) {
	t.Parallel()
	empty := renderComp(context.Background(), compressButton(convVM{ID: "c"}))
	if strings.Contains(empty, "/compact") || !strings.Contains(empty, "disabled") {
		t.Errorf("an empty conversation offers Compress: %s", empty)
	}
	some := renderComp(context.Background(), compressButton(convVM{ID: "c", Inspector: inspVM{Turns: 2}}))
	if !strings.Contains(some, `href="/c/c/compact"`) {
		t.Errorf("a conversation with turns lacks Compress: %s", some)
	}
}

// The compression stream only streams this conversation's compression: a
// run id from another conversation (here, another account's) is refused.
func TestCompactStream_RefusesAnotherConversationsRun(t *testing.T) {
	t.Parallel()
	f := newInspFx(t)
	var other sendFixture
	t.Run("other account", func(t *testing.T) { other = seedSendable(t, f.q, "http://unused") })
	cx, err := f.q.ListContextsByConversation(context.Background(), other.convID)
	if err != nil || len(cx) == 0 {
		t.Fatal(err)
	}
	id, _ := uuid.NewV7()
	if _, err := f.q.CreateStreamRun(context.Background(), store.CreateStreamRunParams{ID: id, ConversationID: other.convID, ContextID: cx[0].ID, ModelID: "m", Status: "completed", Purpose: string(stream.PurposeCompression)}); err != nil {
		t.Fatal(err)
	}
	rec := f.get(t, f.h.handleCompactStream, "/c/"+f.conv+"/compact/stream?run="+id.String(), nil)
	if rec.Code != 404 {
		t.Errorf("streaming another conversation's run = %d, body %q", rec.Code, rec.Body.String())
	}
}
