package conversations

import (
	"testing"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

func TestService_ArchiveConversation_ListsAndRestore(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	seedConversations(t, svc, ctxAs(alice), prof.ID.String(), []string{"keep", "shelve"})

	list := func(archived bool) []*psmithv1.Conversation {
		resp, err := svc.ListConversations(ctxAs(alice), connect.NewRequest(&psmithv1.ListConversationsRequest{
			Archived: archived,
		}))
		if err != nil {
			t.Fatalf("list(archived=%v): %v", archived, err)
		}
		return resp.Msg.Conversations
	}

	active := list(false)
	if len(active) != 2 || len(list(true)) != 0 {
		t.Fatalf("precondition: want 2 active / 0 archived, got %d/%d", len(active), len(list(true)))
	}
	var target *psmithv1.Conversation
	for _, c := range active {
		if c.GetTitle() == "shelve" {
			target = c
		}
	}

	if _, err := svc.ArchiveConversation(ctxAs(alice), connect.NewRequest(&psmithv1.ArchiveConversationRequest{
		Id: target.Id,
	})); err != nil {
		t.Fatalf("archive: %v", err)
	}

	if got := list(false); len(got) != 1 || got[0].GetTitle() != "keep" {
		t.Errorf("active list after archive: %+v", titlesOf(got))
	}
	arch := list(true)
	if len(arch) != 1 || arch[0].GetTitle() != "shelve" {
		t.Fatalf("archived list: %+v", titlesOf(arch))
	}
	if arch[0].ArchivedAt == nil {
		t.Error("archived conversation should carry archived_at")
	}

	// Unarchive restores.
	if _, err := svc.UnarchiveConversation(ctxAs(alice), connect.NewRequest(&psmithv1.UnarchiveConversationRequest{
		Id: target.Id,
	})); err != nil {
		t.Fatalf("unarchive: %v", err)
	}
	if got := list(false); len(got) != 2 {
		t.Errorf("active after unarchive: %+v", titlesOf(got))
	}
	if got := list(true); len(got) != 0 {
		t.Errorf("archived after unarchive: %+v", titlesOf(got))
	}
}

// Archived means read-only: every mutating RPC refuses with
// FailedPrecondition. A representative set covers each gating pattern
// (conversation-fetch, context-fetch, settings-update); all eleven
// handlers share the same requireNotArchived helper.
func TestService_ArchivedConversationIsReadOnly(t *testing.T) {
	t.Parallel()
	// Full deps: SendMessage / Compact / SetConversationPlugins check
	// their supervisor+catalog+pool wiring before ownership, so the
	// archived gate is only reachable with a fully-wired service.
	svc, q, _, _ := newFullSvcWithPool(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	seedConversations(t, svc, ctxAs(alice), prof.ID.String(), []string{"frozen"})

	resp, err := svc.ListConversations(ctxAs(alice), connect.NewRequest(&psmithv1.ListConversationsRequest{}))
	if err != nil || len(resp.Msg.Conversations) != 1 {
		t.Fatalf("seed list: %v / %d", err, len(resp.Msg.Conversations))
	}
	conv := resp.Msg.Conversations[0]
	getResp, err := svc.GetConversation(ctxAs(alice), connect.NewRequest(&psmithv1.GetConversationRequest{Id: conv.Id}))
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	ctxID := getResp.Msg.GetActiveContext().GetId()

	if _, err := svc.ArchiveConversation(ctxAs(alice), connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: conv.Id})); err != nil {
		t.Fatalf("archive: %v", err)
	}

	wantFrozen := func(name string, err error) {
		t.Helper()
		if connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Errorf("%s on archived conversation: want FailedPrecondition, got %v", name, err)
		}
	}

	_, err = svc.SendMessage(ctxAs(alice), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: conv.Id, Content: "hi",
	}))
	wantFrozen("SendMessage", err)

	newTitle := "renamed"
	_, err = svc.UpdateConversation(ctxAs(alice), connect.NewRequest(&psmithv1.UpdateConversationRequest{
		Id: conv.Id, Title: &newTitle,
	}))
	wantFrozen("UpdateConversation", err)

	_, err = svc.ActivateContext(ctxAs(alice), connect.NewRequest(&psmithv1.ActivateContextRequest{
		ContextId: ctxID,
	}))
	wantFrozen("ActivateContext", err)

	_, err = svc.Compact(ctxAs(alice), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId: conv.Id,
	}))
	wantFrozen("Compact", err)

	_, err = svc.SetConversationPlugins(ctxAs(alice), connect.NewRequest(&psmithv1.SetConversationPluginsRequest{
		ConversationId: conv.Id,
	}))
	wantFrozen("SetConversationPlugins", err)

	// Reads stay open.
	if _, err := svc.GetConversation(ctxAs(alice), connect.NewRequest(&psmithv1.GetConversationRequest{Id: conv.Id})); err != nil {
		t.Errorf("GetConversation should stay readable: %v", err)
	}
	if _, err := svc.ListMessages(ctxAs(alice), connect.NewRequest(&psmithv1.ListMessagesRequest{ContextId: ctxID})); err != nil {
		t.Errorf("ListMessages should stay readable: %v", err)
	}

	// Deleting an archived conversation stays allowed — archive is not a
	// lock against cleanup.
	if _, err := svc.DeleteConversation(ctxAs(alice), connect.NewRequest(&psmithv1.DeleteConversationRequest{Id: conv.Id})); err != nil {
		t.Errorf("DeleteConversation on archived should be allowed: %v", err)
	}
}

func TestService_ArchiveConversation_Validation(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	seedConversations(t, svc, ctxAs(alice), prof.ID.String(), []string{"mine"})

	resp, _ := svc.ListConversations(ctxAs(alice), connect.NewRequest(&psmithv1.ListConversationsRequest{}))
	convID := resp.Msg.Conversations[0].Id

	_, err := svc.ArchiveConversation(ctxAs(bob), connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: convID}))
	if connect.CodeOf(err) != connect.CodeNotFound {
		t.Errorf("cross-user archive: want NotFound, got %v", err)
	}
	_, err = svc.ArchiveConversation(ctxAs(alice), connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: "junk"}))
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Errorf("bad id: want InvalidArgument, got %v", err)
	}
}

func titlesOf(cs []*psmithv1.Conversation) []string {
	out := make([]string, len(cs))
	for i, c := range cs {
		out[i] = c.GetTitle()
	}
	return out
}
