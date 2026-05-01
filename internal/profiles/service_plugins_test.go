package profiles

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	clarkv1 "github.com/jdpedrie/reeve/gen/clark/v1"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/plugins"
)

// makeProfilePlain creates a profile with the minimum required fields. Used
// across the plugin-management tests; doesn't exercise compression knobs or
// parent inheritance unless explicitly passed.
func makeProfilePlain(t *testing.T, qs *store.Queries, userID uuid.UUID, parentID *uuid.UUID) store.Profile {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	p, err := qs.CreateProfile(context.Background(), store.CreateProfileParams{
		ID:              id,
		UserID:          userID,
		ParentProfileID: parentID,
		Name:            "p-" + id.String()[:8],
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return p
}

// --- ListPluginTypes -------------------------------------------------------

func TestListPluginTypes_IncludesLetteredChoicesWithCapabilities(t *testing.T) {
	t.Parallel()
	svc, _ := newTestSvc(t)
	user := mustCreateUser(t, q(t), "alice")
	resp, err := svc.ListPluginTypes(ctxAs(user), connect.NewRequest(&clarkv1.ListPluginTypesRequest{}))
	if err != nil {
		t.Fatalf("ListPluginTypes: %v", err)
	}
	var got *clarkv1.PluginType
	for _, pt := range resp.Msg.PluginTypes {
		if pt.Name == plugins.LetteredChoicesName {
			got = pt
			break
		}
	}
	if got == nil {
		t.Fatalf("lettered_choices not in registry; got names=%v", names(resp.Msg.PluginTypes))
	}
	if got.Description == "" {
		t.Error("description should be non-empty")
	}
	if len(got.ConfigFields) != 4 {
		t.Errorf("config_fields len = %d want 4", len(got.ConfigFields))
	}
	// Spot-check keep_last_n: NUMBER type with default JSON-encoded "1".
	var keepLastN, sysOverride *clarkv1.ConfigField
	for _, f := range got.ConfigFields {
		switch f.Name {
		case "keep_last_n":
			keepLastN = f
		case "system_instruction_override":
			sysOverride = f
		}
	}
	if keepLastN == nil {
		t.Fatal("keep_last_n field missing")
	}
	if keepLastN.Type != clarkv1.ConfigField_NUMBER {
		t.Errorf("keep_last_n type = %v want NUMBER", keepLastN.Type)
	}
	if keepLastN.DefaultJson != "1" {
		t.Errorf("keep_last_n default_json = %q want %q", keepLastN.DefaultJson, "1")
	}
	if sysOverride == nil {
		t.Fatal("system_instruction_override field missing")
	}
	if sysOverride.Type != clarkv1.ConfigField_TEXTAREA {
		t.Errorf("system_instruction_override type = %v want TEXTAREA", sysOverride.Type)
	}
	if sysOverride.DefaultJson != "" {
		t.Errorf("system_instruction_override default_json = %q want \"\"", sysOverride.DefaultJson)
	}
	caps := got.Capabilities
	if caps == nil {
		t.Fatal("capabilities is nil")
	}
	// Lettered_choices implements four sub-interfaces.
	if !caps.Configurable {
		t.Error("Configurable should be true")
	}
	if !caps.SystemPrompter {
		t.Error("SystemPrompter should be true")
	}
	if !caps.HistoryTransformer {
		t.Error("HistoryTransformer should be true")
	}
	if !caps.DisplayTransformer {
		t.Error("DisplayTransformer should be true")
	}
	// And not the others.
	if caps.OutgoingUserTransformer || caps.ChunkTransformer || caps.ToolProvider {
		t.Errorf("unexpected capability bits set: %+v", caps)
	}
}

// --- GetProfilePlugins -----------------------------------------------------

func TestGetProfilePlugins_EmptyByDefault(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	prof := makeProfilePlain(t, qs, user.ID, nil)

	resp, err := svc.GetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.GetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("GetProfilePlugins: %v", err)
	}
	if len(resp.Msg.Plugins) != 0 {
		t.Errorf("got %d rows, want 0", len(resp.Msg.Plugins))
	}
}

func TestGetProfilePlugins_ReturnsRowsInOrder(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	prof := makeProfilePlain(t, qs, user.ID, nil)
	for i, name := range []string{plugins.LetteredChoicesName, plugins.LetteredChoicesName} {
		if _, err := qs.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
			ProfileID: prof.ID, Ordinal: int32(i), PluginName: name,
		}); err != nil {
			t.Fatalf("InsertProfilePlugin %d: %v", i, err)
		}
	}
	resp, err := svc.GetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.GetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("GetProfilePlugins: %v", err)
	}
	if len(resp.Msg.Plugins) != 2 {
		t.Fatalf("got %d rows, want 2", len(resp.Msg.Plugins))
	}
	if resp.Msg.Plugins[0].Ordinal != 0 || resp.Msg.Plugins[1].Ordinal != 1 {
		t.Errorf("ordinals wrong: %+v", resp.Msg.Plugins)
	}
}

func TestGetProfilePlugins_DoesNotWalkParentChain(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	parent := makeProfilePlain(t, qs, user.ID, nil)
	pid := parent.ID
	child := makeProfilePlain(t, qs, user.ID, &pid)

	// Plugin attached to PARENT only.
	if _, err := qs.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID: parent.ID, Ordinal: 0, PluginName: plugins.LetteredChoicesName,
	}); err != nil {
		t.Fatalf("InsertProfilePlugin: %v", err)
	}

	resp, err := svc.GetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.GetProfilePluginsRequest{
		ProfileId: child.ID.String(),
	}))
	if err != nil {
		t.Fatalf("GetProfilePlugins child: %v", err)
	}
	if len(resp.Msg.Plugins) != 0 {
		t.Errorf("child returned %d rows; want 0 (Get must not inherit)", len(resp.Msg.Plugins))
	}
}

func TestGetProfilePlugins_CrossUserNotFound(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	alice := mustCreateUser(t, qs, "alice")
	bob := mustCreateUser(t, qs, "bob")
	prof := makeProfilePlain(t, qs, alice.ID, nil)

	_, err := svc.GetProfilePlugins(ctxAs(bob), connect.NewRequest(&clarkv1.GetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
	}))
	assertConnectCode(t, err, connect.CodeNotFound)
}

func TestGetProfilePlugins_InvalidUUID(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	_, err := svc.GetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.GetProfilePluginsRequest{
		ProfileId: "not-a-uuid",
	}))
	assertConnectCode(t, err, connect.CodeInvalidArgument)
}

// --- SetProfilePlugins -----------------------------------------------------

func TestSetProfilePlugins_HappyPath(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	prof := makeProfilePlain(t, qs, user.ID, nil)

	resp, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.SetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
		Plugins: []*clarkv1.ProfilePlugin{
			{PluginName: plugins.LetteredChoicesName, Config: []byte(`{"keep_last_n": 2}`)},
			{PluginName: plugins.LetteredChoicesName, Config: nil},
		},
	}))
	if err != nil {
		t.Fatalf("SetProfilePlugins: %v", err)
	}
	if len(resp.Msg.Plugins) != 2 {
		t.Fatalf("response len = %d want 2", len(resp.Msg.Plugins))
	}
	if resp.Msg.Plugins[0].Ordinal != 0 || resp.Msg.Plugins[1].Ordinal != 1 {
		t.Errorf("ordinals wrong: %+v", resp.Msg.Plugins)
	}

	// Round-trip via Get to confirm persistence.
	got, _ := svc.GetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.GetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
	}))
	if len(got.Msg.Plugins) != 2 {
		t.Errorf("GetProfilePlugins len = %d want 2", len(got.Msg.Plugins))
	}
}

func TestSetProfilePlugins_AtomicReplace(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	prof := makeProfilePlain(t, qs, user.ID, nil)

	// Pre-populate with 3 rows.
	for i := 0; i < 3; i++ {
		_, _ = qs.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
			ProfileID: prof.ID, Ordinal: int32(i), PluginName: plugins.LetteredChoicesName,
		})
	}
	// Replace with 1 row.
	_, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.SetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
		Plugins: []*clarkv1.ProfilePlugin{
			{PluginName: plugins.LetteredChoicesName},
		},
	}))
	if err != nil {
		t.Fatalf("SetProfilePlugins: %v", err)
	}
	rows, _ := qs.ListProfilePlugins(context.Background(), prof.ID)
	if len(rows) != 1 {
		t.Errorf("after replace: %d rows want 1", len(rows))
	}
	if rows[0].Ordinal != 0 {
		t.Errorf("ordinal=%d want 0", rows[0].Ordinal)
	}
}

func TestSetProfilePlugins_EmptyListClearsPipeline(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	prof := makeProfilePlain(t, qs, user.ID, nil)
	_, _ = qs.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID: prof.ID, Ordinal: 0, PluginName: plugins.LetteredChoicesName,
	})

	_, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.SetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
		Plugins:   nil,
	}))
	if err != nil {
		t.Fatalf("SetProfilePlugins(empty): %v", err)
	}
	rows, _ := qs.ListProfilePlugins(context.Background(), prof.ID)
	if len(rows) != 0 {
		t.Errorf("after empty replace: %d rows want 0", len(rows))
	}
}

func TestSetProfilePlugins_UnknownPluginRejected(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	prof := makeProfilePlain(t, qs, user.ID, nil)
	// Pre-populate so we can verify the failed Set didn't touch existing rows.
	if _, err := qs.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID: prof.ID, Ordinal: 0, PluginName: plugins.LetteredChoicesName,
	}); err != nil {
		t.Fatalf("seed insert: %v", err)
	}

	_, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.SetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
		Plugins: []*clarkv1.ProfilePlugin{
			{PluginName: "definitely-not-a-real-plugin"},
		},
	}))
	assertConnectCode(t, err, connect.CodeInvalidArgument)

	// Pre-existing row must remain (validation happens BEFORE delete).
	rows, _ := qs.ListProfilePlugins(context.Background(), prof.ID)
	if len(rows) != 1 {
		t.Errorf("pre-existing rows lost on failed Set; got %d want 1", len(rows))
	}
}

func TestSetProfilePlugins_BadConfigRejected(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	prof := makeProfilePlain(t, qs, user.ID, nil)

	_, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.SetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
		Plugins: []*clarkv1.ProfilePlugin{
			{PluginName: plugins.LetteredChoicesName, Config: []byte(`{not json`)},
		},
	}))
	assertConnectCode(t, err, connect.CodeInvalidArgument)
}

func TestSetProfilePlugins_EmptyPluginNameRejected(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	prof := makeProfilePlain(t, qs, user.ID, nil)
	_, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.SetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
		Plugins: []*clarkv1.ProfilePlugin{
			{PluginName: ""},
		},
	}))
	assertConnectCode(t, err, connect.CodeInvalidArgument)
}

func TestSetProfilePlugins_CrossUserNotFound(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	alice := mustCreateUser(t, qs, "alice")
	bob := mustCreateUser(t, qs, "bob")
	prof := makeProfilePlain(t, qs, alice.ID, nil)
	_, err := svc.SetProfilePlugins(ctxAs(bob), connect.NewRequest(&clarkv1.SetProfilePluginsRequest{
		ProfileId: prof.ID.String(),
	}))
	assertConnectCode(t, err, connect.CodeNotFound)
}

func TestSetProfilePlugins_InvalidUUID(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "alice")
	_ = user
	_ = qs
	_, err := svc.SetProfilePlugins(ctxAs(user), connect.NewRequest(&clarkv1.SetProfilePluginsRequest{
		ProfileId: "not-a-uuid",
	}))
	assertConnectCode(t, err, connect.CodeInvalidArgument)
}

// --- helpers ---------------------------------------------------------------

// q returns a fresh queries handle for tests that only need to make a user
// outside the svc constructor.
func q(t *testing.T) *store.Queries {
	t.Helper()
	// Reuse newTestSvc's setup for the side effect of creating a fresh DB.
	_, qs := newTestSvc(t)
	return qs
}

func names(types []*clarkv1.PluginType) []string {
	out := make([]string, 0, len(types))
	for _, t := range types {
		out = append(out, t.Name)
	}
	return out
}

func assertConnectCode(t *testing.T, err error, want connect.Code) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error with code %v, got nil", want)
	}
	var ce *connect.Error
	if !errors.As(err, &ce) {
		t.Fatalf("expected *connect.Error, got %T (%v)", err, err)
	}
	if ce.Code() != want {
		t.Errorf("got code %v want %v (%v)", ce.Code(), want, err)
	}
}
