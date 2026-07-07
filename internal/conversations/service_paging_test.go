package conversations

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"
)

// walkPages exhausts ListConversations page by page and returns each
// page's conversation ids, failing on any repeated id (a duplicate
// across a page boundary is exactly the bug keyset paging prevents).
func walkPages(t *testing.T, svc *Service, ctx context.Context, req *psmithv1.ListConversationsRequest) [][]string {
	t.Helper()
	var pages [][]string
	seen := map[string]bool{}
	token := ""
	for i := 0; i < 20; i++ { // hard stop: a paging loop must terminate
		r := proto.Clone(req).(*psmithv1.ListConversationsRequest)
		r.PageToken = token
		resp, err := svc.ListConversations(ctx, connect.NewRequest(r))
		if err != nil {
			t.Fatalf("ListConversations page %d: %v", len(pages), err)
		}
		var ids []string
		for _, c := range resp.Msg.Conversations {
			if seen[c.Id] {
				t.Fatalf("conversation %s repeated across pages", c.Id)
			}
			seen[c.Id] = true
			ids = append(ids, c.Id)
		}
		pages = append(pages, ids)
		token = resp.Msg.NextPageToken
		if token == "" {
			return pages
		}
		if len(ids) == 0 {
			t.Fatal("empty page with a next_page_token")
		}
	}
	t.Fatal("paging did not terminate")
	return nil
}

func seedConversations(t *testing.T, svc *Service, ctx context.Context, profileID string, titles []string) {
	t.Helper()
	for _, title := range titles {
		req := &psmithv1.CreateConversationRequest{ProfileId: profileID}
		if title != "" {
			req.Title = &title
		}
		if _, err := svc.CreateConversation(ctx, connect.NewRequest(req)); err != nil {
			t.Fatalf("seed %q: %v", title, err)
		}
		// Distinct created_at per row — the tie case gets its own test.
		time.Sleep(5 * time.Millisecond)
	}
}

func TestService_ListConversations_PagingRecentlyCreated(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	seedConversations(t, svc, ctxAs(alice), prof.ID.String(), []string{"a", "b", "c", "d", "e"})

	order := psmithv1.ConversationOrder_CONVERSATION_ORDER_RECENTLY_CREATED
	pages := walkPages(t, svc, ctxAs(alice), &psmithv1.ListConversationsRequest{
		PageSize: 2, Order: &order,
	})

	if len(pages) != 3 || len(pages[0]) != 2 || len(pages[1]) != 2 || len(pages[2]) != 1 {
		t.Fatalf("want pages [2 2 1], got %v", pageLens(pages))
	}

	// The concatenation must equal the unpaged listing exactly — paging
	// is a window over the same order, not a reordering.
	unpaged, err := svc.ListConversations(ctxAs(alice), connect.NewRequest(&psmithv1.ListConversationsRequest{Order: &order}))
	if err != nil {
		t.Fatalf("unpaged: %v", err)
	}
	var flat []string
	for _, p := range pages {
		flat = append(flat, p...)
	}
	if len(flat) != len(unpaged.Msg.Conversations) {
		t.Fatalf("paged total %d != unpaged %d", len(flat), len(unpaged.Msg.Conversations))
	}
	for i, c := range unpaged.Msg.Conversations {
		if flat[i] != c.Id {
			t.Fatalf("order diverges at %d: paged %s unpaged %s", i, flat[i], c.Id)
		}
	}
}

func TestService_ListConversations_PagingRecentlyUsed(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	seedConversations(t, svc, ctxAs(alice), prof.ID.String(), []string{"a", "b", "c", "d", "e"})

	pages := walkPages(t, svc, ctxAs(alice), &psmithv1.ListConversationsRequest{PageSize: 2})
	if got := pageLens(pages); len(flatten(pages)) != 5 {
		t.Fatalf("want all 5 across pages, got %v", got)
	}
}

// All rows sharing one created_at forces every page boundary through the
// id tie-break. Without the id in the cursor tuple this skips or
// duplicates rows.
func TestService_ListConversations_PagingTieBreak(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	svc := NewService(q, nil, nil, nil, crypto.Nop{}, nil, nil)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	seedConversations(t, svc, ctxAs(alice), prof.ID.String(), []string{"a", "b", "c", "d", "e"})

	if _, err := pool.Exec(context.Background(),
		`UPDATE conversations SET created_at = '2026-01-01T00:00:00Z' WHERE user_id = $1`, alice.ID); err != nil {
		t.Fatalf("force ties: %v", err)
	}

	order := psmithv1.ConversationOrder_CONVERSATION_ORDER_RECENTLY_CREATED
	pages := walkPages(t, svc, ctxAs(alice), &psmithv1.ListConversationsRequest{
		PageSize: 2, Order: &order,
	})
	if len(flatten(pages)) != 5 {
		t.Fatalf("tie-broken paging lost rows: pages %v", pageLens(pages))
	}
}

func TestService_ListConversations_PagingWithTitleQuery(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	seedConversations(t, svc, ctxAs(alice), prof.ID.String(),
		[]string{"alpha one", "beta", "alpha two", "gamma", "alpha three"})

	tq := "alpha"
	pages := walkPages(t, svc, ctxAs(alice), &psmithv1.ListConversationsRequest{
		PageSize: 2, TitleQuery: &tq,
	})
	if len(flatten(pages)) != 3 {
		t.Fatalf("want the 3 alpha conversations across pages, got %v", pageLens(pages))
	}
}

func TestService_ListConversations_InvalidPageToken(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	_, err := svc.ListConversations(ctxAs(alice), connect.NewRequest(&psmithv1.ListConversationsRequest{
		PageToken: "not a token !!!",
	}))
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("want InvalidArgument, got %v", err)
	}
}

func pageLens(pages [][]string) []int {
	out := make([]int, len(pages))
	for i, p := range pages {
		out[i] = len(p)
	}
	return out
}

func flatten(pages [][]string) []string {
	var out []string
	for _, p := range pages {
		out = append(out, p...)
	}
	return out
}
