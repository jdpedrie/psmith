package profiles

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"
	"github.com/jdpedrie/psmith/plugins"
)

// TestResolveRequiredModelCapabilities_EmptyForBareProfile verifies a profile
// with no plugins reports zero requirements.
func TestResolveRequiredModelCapabilities_EmptyForBareProfile(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	resp, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&psmithv1.CreateProfileRequest{Name: "bare"}))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	pid := uuid.MustParse(resp.Msg.Profile.Id)

	caps, err := ResolveRequiredModelCapabilities(context.Background(), q, pid)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if !caps.Empty() {
		t.Errorf("bare profile should have no caps; got %+v", caps)
	}
}

// TestResolveRequiredModelCapabilities_AutoDerivesToolUse verifies attaching
// a tool-providing plugin (mcp with stdio transport) sets ToolUse.
func TestResolveRequiredModelCapabilities_AutoDerivesToolUse(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	resp, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&psmithv1.CreateProfileRequest{Name: "with_mcp"}))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	pid := uuid.MustParse(resp.Msg.Profile.Id)

	// Attach an mcp plugin (any transport — stdio is fine; we just need
	// the ToolProvider interface implementation, not actual tool calls).
	if _, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: pid.String(),
		Plugins: []*psmithv1.ProfilePlugin{{
			PluginName: plugins.MCPName,
			Config:     []byte(`{"transport":"stdio","command":"true"}`),
		}},
	})); err != nil {
		t.Fatalf("set plugins: %v", err)
	}

	caps, err := ResolveRequiredModelCapabilities(context.Background(), q, pid)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if !caps.ToolUse {
		t.Errorf("expected ToolUse=true after attaching mcp plugin; got %+v", caps)
	}
}

// TestResolveRequiredModelCapabilities_ParentInheritance verifies a child
// profile with no plugins picks up the parent's requirements (matches the
// all-or-nothing inheritance the conversations service uses).
func TestResolveRequiredModelCapabilities_ParentInheritance(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	parent, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&psmithv1.CreateProfileRequest{Name: "parent"}))
	if err != nil {
		t.Fatalf("create parent: %v", err)
	}
	parentID := uuid.MustParse(parent.Msg.Profile.Id)
	if _, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: parentID.String(),
		Plugins: []*psmithv1.ProfilePlugin{{
			PluginName: plugins.MCPName,
			Config:     []byte(`{"transport":"stdio","command":"true"}`),
		}},
	})); err != nil {
		t.Fatalf("set parent plugins: %v", err)
	}

	pParent := parentID.String()
	child, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&psmithv1.CreateProfileRequest{
		Name:            "child",
		ParentProfileId: &pParent,
	}))
	if err != nil {
		t.Fatalf("create child: %v", err)
	}
	childID := uuid.MustParse(child.Msg.Profile.Id)

	caps, err := ResolveRequiredModelCapabilities(context.Background(), q, childID)
	if err != nil {
		t.Fatalf("resolve child: %v", err)
	}
	if !caps.ToolUse {
		t.Errorf("expected child to inherit ToolUse from parent; got %+v", caps)
	}
}

// TestResolveRequiredModelCapabilities_ChildOverridesParent verifies a child
// with its own plugin list ignores the parent (all-or-nothing rule).
func TestResolveRequiredModelCapabilities_ChildOverridesParent(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	parent, _ := svc.CreateProfile(ctxAs(user), connect.NewRequest(&psmithv1.CreateProfileRequest{Name: "parent"}))
	parentID := uuid.MustParse(parent.Msg.Profile.Id)
	if _, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: parentID.String(),
		Plugins: []*psmithv1.ProfilePlugin{{
			PluginName: plugins.MCPName,
			Config:     []byte(`{"transport":"stdio","command":"true"}`),
		}},
	})); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	pParent := parentID.String()
	child, _ := svc.CreateProfile(ctxAs(user), connect.NewRequest(&psmithv1.CreateProfileRequest{
		Name:            "child",
		ParentProfileId: &pParent,
	}))
	childID := uuid.MustParse(child.Msg.Profile.Id)
	// Override parent: child has its own (cap-free) plugin list.
	if _, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: childID.String(),
		Plugins: []*psmithv1.ProfilePlugin{{
			PluginName: plugins.BasicGroundingName,
			Config:     []byte(`{}`),
		}},
	})); err != nil {
		t.Fatalf("set child: %v", err)
	}

	caps, err := ResolveRequiredModelCapabilities(context.Background(), q, childID)
	if err != nil {
		t.Fatalf("resolve child: %v", err)
	}
	if caps.ToolUse {
		t.Errorf("child override should NOT inherit ToolUse from parent; got %+v", caps)
	}
}

// TestGetProfile_PopulatesRequiredCapabilities verifies the proto field
// surfaces correctly (UI filtering relies on it).
func TestGetProfile_PopulatesRequiredCapabilities(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	resp, _ := svc.CreateProfile(ctxAs(user), connect.NewRequest(&psmithv1.CreateProfileRequest{Name: "p"}))
	pid := uuid.MustParse(resp.Msg.Profile.Id)
	if _, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: pid.String(),
		Plugins: []*psmithv1.ProfilePlugin{{
			PluginName: plugins.MCPName,
			Config:     []byte(`{"transport":"stdio","command":"true"}`),
		}},
	})); err != nil {
		t.Fatalf("set plugins: %v", err)
	}

	got, err := svc.GetProfile(ctxAs(user), connect.NewRequest(&psmithv1.GetProfileRequest{Id: pid.String()}))
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	caps := got.Msg.Profile.GetRequiredModelCapabilities()
	if caps == nil {
		t.Fatal("expected required_model_capabilities to be set")
	}
	if !caps.GetToolUse() {
		t.Errorf("expected ToolUse=true; got %+v", caps)
	}
}

// --- system profile seeding ---

// TestSeedSystemProfiles_InsertsTemplatesAndMarksFlag exercises the happy
// path: a brand-new user has no profiles, seeding inserts them all and the
// flag flips to true.
func TestSeedSystemProfiles_InsertsTemplatesAndMarksFlag(t *testing.T) {
	t.Parallel()
	pool, q, user := newSeedingFixture(t)

	if err := SeedSystemProfiles(context.Background(), pool, q, crypto.Nop{}, user.ID); err != nil {
		t.Fatalf("seed: %v", err)
	}

	rows, err := q.ListProfilesByUser(context.Background(), user.ID)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != len(SystemProfileTemplates) {
		t.Errorf("got %d profiles, expected %d", len(rows), len(SystemProfileTemplates))
	}
	gotNames := map[string]bool{}
	for _, r := range rows {
		gotNames[r.Name] = true
	}
	for _, tpl := range SystemProfileTemplates {
		if !gotNames[tpl.Name] {
			t.Errorf("missing seeded profile %q", tpl.Name)
		}
	}

	updated, err := q.GetUserByID(context.Background(), user.ID)
	if err != nil {
		t.Fatalf("get user: %v", err)
	}
	if !updated.SystemProfilesSeeded {
		t.Error("system_profiles_seeded should be true after seeding")
	}
}

// TestSeedSystemProfiles_Idempotent verifies a second call is a no-op.
func TestSeedSystemProfiles_Idempotent(t *testing.T) {
	t.Parallel()
	pool, q, user := newSeedingFixture(t)

	if err := SeedSystemProfiles(context.Background(), pool, q, crypto.Nop{}, user.ID); err != nil {
		t.Fatalf("first seed: %v", err)
	}
	if err := SeedSystemProfiles(context.Background(), pool, q, crypto.Nop{}, user.ID); err != nil {
		t.Fatalf("second seed: %v", err)
	}
	rows, _ := q.ListProfilesByUser(context.Background(), user.ID)
	if len(rows) != len(SystemProfileTemplates) {
		t.Errorf("expected %d profiles after re-seed; got %d (re-seeding should no-op)",
			len(SystemProfileTemplates), len(rows))
	}
}

// TestSeedSystemProfiles_AttachesPluginPipelines verifies each seeded profile
// has its declared plugins inserted in order.
func TestSeedSystemProfiles_AttachesPluginPipelines(t *testing.T) {
	t.Parallel()
	pool, q, user := newSeedingFixture(t)

	if err := SeedSystemProfiles(context.Background(), pool, q, crypto.Nop{}, user.ID); err != nil {
		t.Fatalf("seed: %v", err)
	}
	rows, _ := q.ListProfilesByUser(context.Background(), user.ID)
	for _, r := range rows {
		// Find the matching template.
		var tpl *SystemProfileTemplate
		for i := range SystemProfileTemplates {
			if SystemProfileTemplates[i].Name == r.Name {
				tpl = &SystemProfileTemplates[i]
				break
			}
		}
		if tpl == nil {
			continue
		}
		got, err := q.ListProfilePlugins(context.Background(), r.ID)
		if err != nil {
			t.Fatalf("list plugins for %s: %v", r.Name, err)
		}
		if len(got) != len(tpl.Plugins) {
			t.Errorf("%s: got %d plugins, want %d", r.Name, len(got), len(tpl.Plugins))
			continue
		}
		for i, gp := range got {
			if gp.PluginName != tpl.Plugins[i].Name {
				t.Errorf("%s: plugin[%d] name: got %q want %q",
					r.Name, i, gp.PluginName, tpl.Plugins[i].Name)
			}
			if int(gp.Ordinal) != i {
				t.Errorf("%s: plugin[%d] ordinal: got %d want %d",
					r.Name, i, gp.Ordinal, i)
			}
		}
	}
}

// --- helpers ---

func newSeedingFixture(t *testing.T) (*pgxpool.Pool, *store.Queries, store.User) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	user := mustCreateUser(t, q, "seeded_user")
	return pool, q, user
}
