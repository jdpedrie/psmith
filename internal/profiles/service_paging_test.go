package profiles

import (
	"fmt"
	"testing"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
)

func seedProfiles(t *testing.T, svc *Service, u store.User, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		if _, err := svc.CreateProfile(ctxAs(u), connect.NewRequest(&psmithv1.CreateProfileRequest{
			Name: fmt.Sprintf("profile-%02d", i),
		})); err != nil {
			t.Fatalf("seed profile %d: %v", i, err)
		}
	}
}

func TestService_ListProfiles_PageSizeZeroReturnsAll(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	seedProfiles(t, svc, user, 5)

	resp, err := svc.ListProfiles(ctxAs(user), connect.NewRequest(&psmithv1.ListProfilesRequest{}))
	if err != nil {
		t.Fatalf("ListProfiles: %v", err)
	}
	if len(resp.Msg.Profiles) != 5 {
		t.Errorf("legacy page_size=0 should return all 5, got %d", len(resp.Msg.Profiles))
	}
	if resp.Msg.NextPageToken != "" {
		t.Errorf("legacy mode must not set next_page_token, got %q", resp.Msg.NextPageToken)
	}
}

func TestService_ListProfiles_Paging(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	seedProfiles(t, svc, user, 5)

	seen := map[string]bool{}
	var flat []string
	token := ""
	pages := 0
	for {
		resp, err := svc.ListProfiles(ctxAs(user), connect.NewRequest(&psmithv1.ListProfilesRequest{
			PageSize: 2, PageToken: token,
		}))
		if err != nil {
			t.Fatalf("page %d: %v", pages, err)
		}
		for _, p := range resp.Msg.Profiles {
			if seen[p.Id] {
				t.Fatalf("profile %s repeated across pages", p.Id)
			}
			seen[p.Id] = true
			flat = append(flat, p.Name)
		}
		pages++
		token = resp.Msg.NextPageToken
		if token == "" {
			break
		}
		if pages > 10 {
			t.Fatal("paging did not terminate")
		}
	}
	if pages != 3 || len(flat) != 5 {
		t.Fatalf("want 5 profiles over 3 pages, got %d over %d", len(flat), pages)
	}
	// created_at ascending: seed order is the page order.
	for i, name := range flat {
		if want := fmt.Sprintf("profile-%02d", i); name != want {
			t.Errorf("position %d: got %s want %s", i, name, want)
		}
	}
}

func TestService_ListProfiles_InvalidPageToken(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	_, err := svc.ListProfiles(ctxAs(user), connect.NewRequest(&psmithv1.ListProfilesRequest{
		PageSize: 2, PageToken: "garbage!!!",
	}))
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("want InvalidArgument, got %v", err)
	}
}
