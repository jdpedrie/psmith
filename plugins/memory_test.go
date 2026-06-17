package plugins

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jdpedrie/spalt/internal/embeddings"
)

// stubSearcher returns canned results so tests assert behavior
// without spinning up Postgres + the worker. UserID and Limit are
// captured for the "scope-by-caller" assertions.
type stubSearcher struct {
	hits        []embeddings.Hit
	err         error
	lastUserID  uuid.UUID
	lastLimit   int
	lastQuery   string
	lastMaxDist float64
	wasCalled   bool
}

func (s *stubSearcher) Search(_ context.Context, query string, opts embeddings.SearchOptions) ([]embeddings.Hit, error) {
	s.wasCalled = true
	s.lastQuery = query
	s.lastUserID = opts.UserID
	s.lastLimit = opts.Limit
	s.lastMaxDist = opts.MaxDistance
	if s.err != nil {
		return nil, s.err
	}
	return s.hits, nil
}

func newMemoryForTest(t *testing.T) *memory {
	t.Helper()
	pl, err := newMemory(nil)
	if err != nil {
		t.Fatalf("newMemory: %v", err)
	}
	return pl.(*memory)
}

func TestMemory_Descriptor(t *testing.T) {
	t.Parallel()
	pl := newMemoryForTest(t)
	if pl.Name() != MemoryName {
		t.Errorf("Name=%q", pl.Name())
	}
	if pl.DisplayName() == "" || pl.Description() == "" {
		t.Error("DisplayName/Description must be non-empty")
	}
	tp, ok := Plugin(pl).(ToolProvider)
	if !ok {
		t.Fatal("memory must implement ToolProvider")
	}
	tools := tp.Tools()
	if len(tools) != 1 || tools[0].Name != memoryToolName {
		t.Fatalf("tools=%v", tools)
	}
	// Schema must parse — the runtime hands this straight to the
	// provider; a malformed schema breaks every model-side
	// tool-use turn.
	var schema map[string]any
	if err := json.Unmarshal(tools[0].InputSchema, &schema); err != nil {
		t.Errorf("schema invalid JSON: %v", err)
	}
}

func TestMemory_ExecuteTool_HappyPath(t *testing.T) {
	t.Parallel()
	user := uuid.New()
	conv := uuid.New()
	activeCtx := uuid.New()
	otherConv := uuid.New()
	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	stub := &stubSearcher{hits: []embeddings.Hit{
		{
			MessageID: uuid.New(), ContextID: uuid.New(), ConversationID: otherConv,
			ConversationTitle: "old project", Role: "user",
			Content: "we decided to use HNSW", CreatedAt: t0,
			Distance: 0.12,
		},
	}}

	ctx := WithSearcher(context.Background(), stub)
	ctx = WithCallerInfo(ctx, CallerInfo{
		UserID: user, ConversationID: conv, ActiveContextID: activeCtx,
	})

	pl := newMemoryForTest(t)
	res, err := pl.ExecuteTool(ctx, memoryToolName,
		json.RawMessage(`{"query":"vector index choice"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}

	// Stub was called with the right scoping.
	if stub.lastUserID != user {
		t.Errorf("searcher.UserID=%s want %s", stub.lastUserID, user)
	}
	if stub.lastLimit != 5 {
		t.Errorf("searcher.Limit=%d want 5 (default)", stub.lastLimit)
	}
	if stub.lastQuery != "vector index choice" {
		t.Errorf("searcher.Query=%q", stub.lastQuery)
	}

	// Output parses and carries the one hit.
	var out memoryToolOutput
	if err := json.Unmarshal(res.Output, &out); err != nil {
		t.Fatalf("decode output: %v", err)
	}
	if len(out.Hits) != 1 || out.Hits[0].Content != "we decided to use HNSW" {
		t.Errorf("hits=%+v", out.Hits)
	}
	if out.Hits[0].ConversationTitle != "old project" {
		t.Errorf("title=%q", out.Hits[0].ConversationTitle)
	}
}

// The critical case: a hit from an OLD retired context of the same
// conversation should pass through (it's exactly the use case). A
// hit from the active context should be filtered (already in wire
// prefix).
func TestMemory_ExecuteTool_FiltersActiveContextKeepsRetiredContexts(t *testing.T) {
	t.Parallel()
	user := uuid.New()
	conv := uuid.New()
	activeCtx := uuid.New()
	retiredCtx := uuid.New()

	stub := &stubSearcher{hits: []embeddings.Hit{
		{
			MessageID:      uuid.New(),
			ContextID:      activeCtx,
			ConversationID: conv,
			Content:        "in wire prefix already",
		},
		{
			MessageID:      uuid.New(),
			ContextID:      retiredCtx,
			ConversationID: conv,
			Content:        "compressed out of the same conv — should surface",
		},
		{
			MessageID:      uuid.New(),
			ContextID:      uuid.New(),
			ConversationID: uuid.New(),
			Content:        "different conversation entirely",
		},
	}}
	ctx := WithSearcher(context.Background(), stub)
	ctx = WithCallerInfo(ctx, CallerInfo{
		UserID: user, ConversationID: conv, ActiveContextID: activeCtx,
	})

	pl := newMemoryForTest(t)
	res, err := pl.ExecuteTool(ctx, memoryToolName,
		json.RawMessage(`{"query":"x"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	var out memoryToolOutput
	if err := json.Unmarshal(res.Output, &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Hits) != 2 {
		t.Fatalf("hits=%d want 2 (retired-context + other-conv; active dropped)", len(out.Hits))
	}
	if out.Hits[0].Content != "compressed out of the same conv — should surface" {
		t.Errorf("retired-context hit missing or out of order: %+v", out.Hits)
	}
	if out.Skipped == nil || out.Skipped.ActiveContext != 1 {
		t.Errorf("Skipped=%+v want ActiveContext=1", out.Skipped)
	}
}

func TestMemory_ExecuteTool_RespectsIncludeActiveContext(t *testing.T) {
	t.Parallel()
	user := uuid.New()
	conv := uuid.New()
	activeCtx := uuid.New()

	pl, err := newMemory(json.RawMessage(`{"include_active_context":true}`))
	if err != nil {
		t.Fatalf("newMemory: %v", err)
	}
	stub := &stubSearcher{hits: []embeddings.Hit{
		{MessageID: uuid.New(), ContextID: activeCtx, ConversationID: conv, Content: "active"},
		{MessageID: uuid.New(), ContextID: uuid.New(), ConversationID: conv, Content: "retired"},
	}}
	ctx := WithSearcher(context.Background(), stub)
	ctx = WithCallerInfo(ctx, CallerInfo{
		UserID: user, ConversationID: conv, ActiveContextID: activeCtx,
	})

	res, err := pl.(*memory).ExecuteTool(ctx, memoryToolName,
		json.RawMessage(`{"query":"x"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	var out memoryToolOutput
	_ = json.Unmarshal(res.Output, &out)
	if len(out.Hits) != 2 {
		t.Errorf("hits=%d want 2 (both, since opt-in is on)", len(out.Hits))
	}
	if out.Skipped != nil {
		t.Errorf("Skipped should be nil; got %+v", out.Skipped)
	}
}

func TestMemory_ExecuteTool_NoSearcherErrors(t *testing.T) {
	t.Parallel()
	ctx := WithCallerInfo(context.Background(),
		CallerInfo{UserID: uuid.New(), ConversationID: uuid.New()})
	pl := newMemoryForTest(t)
	_, err := pl.ExecuteTool(ctx, memoryToolName, json.RawMessage(`{"query":"x"}`))
	if err == nil || !strings.Contains(err.Error(), "no Searcher in context") {
		t.Errorf("want no-searcher error, got %v", err)
	}
}

func TestMemory_ExecuteTool_NoCallerInfoErrors(t *testing.T) {
	t.Parallel()
	ctx := WithSearcher(context.Background(), &stubSearcher{})
	pl := newMemoryForTest(t)
	_, err := pl.ExecuteTool(ctx, memoryToolName, json.RawMessage(`{"query":"x"}`))
	if err == nil || !strings.Contains(err.Error(), "CallerInfo") {
		t.Errorf("want no-caller error, got %v", err)
	}
}

func TestMemory_ExecuteTool_EmptyQueryRejected(t *testing.T) {
	t.Parallel()
	ctx := WithSearcher(context.Background(), &stubSearcher{})
	ctx = WithCallerInfo(ctx, CallerInfo{UserID: uuid.New(), ConversationID: uuid.New()})
	pl := newMemoryForTest(t)
	_, err := pl.ExecuteTool(ctx, memoryToolName, json.RawMessage(`{"query":"   "}`))
	if err == nil || !strings.Contains(err.Error(), "query is required") {
		t.Errorf("want empty-query error, got %v", err)
	}
}

func TestMemory_ExecuteTool_CountRespected(t *testing.T) {
	t.Parallel()
	stub := &stubSearcher{}
	ctx := WithSearcher(context.Background(), stub)
	ctx = WithCallerInfo(ctx, CallerInfo{UserID: uuid.New(), ConversationID: uuid.New()})
	pl := newMemoryForTest(t)
	_, err := pl.ExecuteTool(ctx, memoryToolName,
		json.RawMessage(`{"query":"x","count":12}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if stub.lastLimit != 12 {
		t.Errorf("model count not honored: limit=%d want 12", stub.lastLimit)
	}
}

func TestMemory_ExecuteTool_CountClampedAt25(t *testing.T) {
	t.Parallel()
	stub := &stubSearcher{}
	ctx := WithSearcher(context.Background(), stub)
	ctx = WithCallerInfo(ctx, CallerInfo{UserID: uuid.New(), ConversationID: uuid.New()})
	pl := newMemoryForTest(t)
	_, _ = pl.ExecuteTool(ctx, memoryToolName,
		json.RawMessage(`{"query":"x","count":9999}`))
	if stub.lastLimit != 25 {
		t.Errorf("clamp broken: limit=%d want 25", stub.lastLimit)
	}
}

func TestMemory_ExecuteTool_SearcherErrorPropagates(t *testing.T) {
	t.Parallel()
	stub := &stubSearcher{err: errors.New("upstream down")}
	ctx := WithSearcher(context.Background(), stub)
	ctx = WithCallerInfo(ctx, CallerInfo{UserID: uuid.New(), ConversationID: uuid.New()})
	pl := newMemoryForTest(t)
	_, err := pl.ExecuteTool(ctx, memoryToolName, json.RawMessage(`{"query":"x"}`))
	if err == nil || !strings.Contains(err.Error(), "upstream down") {
		t.Errorf("want propagated error, got %v", err)
	}
}

func TestMemory_ExecuteTool_UnknownToolErrors(t *testing.T) {
	t.Parallel()
	pl := newMemoryForTest(t)
	_, err := pl.ExecuteTool(context.Background(), "not_a_tool", nil)
	if err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Errorf("want unknown-tool error, got %v", err)
	}
}
