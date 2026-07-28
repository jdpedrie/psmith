package profiles

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	// Export consults each plugin's own ConfigFields to decide what may
	// travel, so the registry has to be populated the way psmithd populates
	// it. Without this the tests would exercise the unknown-plugin path.
	_ "github.com/jdpedrie/psmith/plugins/all"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/store"
)

// --- helpers ---------------------------------------------------------------

func mustProfile(t *testing.T, q *store.Queries, userID uuid.UUID, name string, parent *uuid.UUID) store.Profile {
	t.Helper()
	p, err := q.CreateProfile(context.Background(), store.CreateProfileParams{
		ID:              uuid.New(),
		UserID:          userID,
		Name:            name,
		ParentProfileID: parent,
	})
	if err != nil {
		t.Fatalf("CreateProfile(%s): %v", name, err)
	}
	return p
}

func mustAttachPlugin(t *testing.T, q *store.Queries, profileID uuid.UUID, ordinal int32, name string, config string) {
	t.Helper()
	// Sealed with crypto.Nop{} to match newTestSvc, so the bytes land in
	// config_encrypted exactly as production writes them.
	sealed, err := crypto.Nop{}.Encrypt([]byte(config))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID:       profileID,
		Ordinal:         ordinal,
		PluginName:      name,
		ConfigEncrypted: sealed,
	}); err != nil {
		t.Fatalf("InsertProfilePlugin(%s): %v", name, err)
	}
}

func mustExport(t *testing.T, svc *Service, ctx context.Context, profileID uuid.UUID, preserve bool) *psmithv1.ExportProfileResponse {
	t.Helper()
	resp, err := svc.ExportProfile(ctx, connect.NewRequest(&psmithv1.ExportProfileRequest{
		ProfileId:     profileID.String(),
		PreserveChain: preserve,
	}))
	if err != nil {
		t.Fatalf("ExportProfile: %v", err)
	}
	return resp.Msg
}

func decodeForTest(t *testing.T, payload []byte) *psmithv1.ProfileBundle {
	t.Helper()
	b, err := decodeBundle(payload)
	if err != nil {
		t.Fatalf("decodeBundle: %v", err)
	}
	return b
}

func pluginByName(b *psmithv1.BundledProfile, name string) *psmithv1.BundledPlugin {
	for _, p := range b.Plugins {
		if p.PluginName == name {
			return p
		}
	}
	return nil
}

// --- export: the security properties ---------------------------------------

// A profile-level value for a Global field is the case the UI is supposed to
// prevent and the schema still permits. If it ever lands there, export must
// not carry it: Global means the value belongs to the user, not the profile.
func TestExport_StripsGlobalConfigKeys(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "exp-global")
	ctx := ctxAs(u)

	p := mustProfile(t, q, u.ID, "Researcher", nil)
	mustAttachPlugin(t, q, p.ID, 0, "brave_search",
		`{"api_key":"BSA-secret-do-not-share","default_count":7}`)

	out := mustExport(t, svc, ctx, p.ID, false)
	bundle := decodeForTest(t, out.Payload)

	bp := pluginByName(bundle.Profiles[0], "brave_search")
	if bp == nil {
		t.Fatal("brave_search missing from bundle")
	}
	var cfg map[string]any
	if err := json.Unmarshal(bp.Config, &cfg); err != nil {
		t.Fatalf("unmarshal exported config: %v", err)
	}
	if _, leaked := cfg["api_key"]; leaked {
		t.Error("api_key was exported; Global fields must never leave the server")
	}
	if got := cfg["default_count"]; got != float64(7) {
		t.Errorf("non-secret config should survive: default_count = %v", got)
	}
	// Scan the raw bytes too, not just the parsed config: a leak through
	// some other field would still show up here.
	if strings.Contains(string(out.Payload), "BSA-secret") {
		t.Error("the secret appears somewhere in the raw payload")
	}
	if len(out.Notices) == 0 {
		t.Error("expected a notice telling the exporter the key was withheld")
	}
}

// mcp's env and headers are profile-scoped, so Global does not cover them.
// They hold API keys and bearer tokens, which is what Secret is for.
func TestExport_StripsSecretConfigKeys(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "exp-secret")
	ctx := ctxAs(u)

	p := mustProfile(t, q, u.ID, "Tooling", nil)
	mustAttachPlugin(t, q, p.ID, 0, "mcp",
		`{"transport":"stdio","command":"npx","env":"API_TOKEN=sk-live-xyz","headers":"Authorization: Bearer tok"}`)

	out := mustExport(t, svc, ctx, p.ID, false)

	if strings.Contains(string(out.Payload), "sk-live-xyz") {
		t.Error("mcp env leaked into the bundle")
	}
	if strings.Contains(string(out.Payload), "Bearer tok") {
		t.Error("mcp headers leaked into the bundle")
	}

	bundle := decodeForTest(t, out.Payload)
	var cfg map[string]any
	if err := json.Unmarshal(pluginByName(bundle.Profiles[0], "mcp").Config, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if cfg["command"] != "npx" {
		t.Errorf("non-secret config should survive: command = %v", cfg["command"])
	}
}

// A registry reference must export as a name. Resolving it would read a row
// whose whole purpose is to keep credentials in one encrypted place.
func TestExport_MCPRegistryRefBecomesNameNotSpec(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "exp-mcpref")
	ctx := ctxAs(u)

	sealed, err := crypto.Nop{}.Encrypt([]byte(`{"transport":"http","url":"https://x","headers":"Authorization: Bearer registry-token"}`))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	srv, err := q.InsertUserMCPServer(context.Background(), store.InsertUserMCPServerParams{
		ID:              uuid.New(),
		UserID:          u.ID,
		Name:            "Linear",
		ConfigEncrypted: sealed,
	})
	if err != nil {
		t.Fatalf("InsertUserMCPServer: %v", err)
	}

	p := mustProfile(t, q, u.ID, "Work", nil)
	mustAttachPlugin(t, q, p.ID, 0, "mcp:"+srv.ID.String(), `{}`)

	out := mustExport(t, svc, ctx, p.ID, false)
	if strings.Contains(string(out.Payload), "registry-token") {
		t.Fatal("registry spec was resolved and exported")
	}

	bundle := decodeForTest(t, out.Payload)
	bp := bundle.Profiles[0].Plugins[0]
	if bp.McpServerName == nil || *bp.McpServerName != "Linear" {
		t.Errorf("expected the server name, got %v", bp.McpServerName)
	}
	if strings.HasPrefix(bp.PluginName, "mcp:") {
		t.Errorf("the source-side registry id must not travel: %q", bp.PluginName)
	}
}

// Configs are sealed at rest and the legacy plaintext column is empty for
// anything written since. Reading the wrong column exports blank configs.
func TestExport_ReadsEncryptedConfigNotLegacyColumn(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "exp-encrypted")
	ctx := ctxAs(u)

	p := mustProfile(t, q, u.ID, "Choices", nil)
	mustAttachPlugin(t, q, p.ID, 0, "lettered_choices", `{"keep_last_n":3}`)

	bundle := decodeForTest(t, mustExport(t, svc, ctx, p.ID, false).Payload)
	var cfg map[string]any
	if err := json.Unmarshal(pluginByName(bundle.Profiles[0], "lettered_choices").Config, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if cfg["keep_last_n"] != float64(3) {
		t.Errorf("config did not survive export: %v", cfg)
	}
}

// --- export: flatten vs preserve -------------------------------------------

func TestExport_FlattenCollapsesChainAndInheritsValues(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "exp-flat")
	ctx := ctxAs(u)

	sys := "you are a careful assistant"
	root, err := q.CreateProfile(context.Background(), store.CreateProfileParams{
		ID: uuid.New(), UserID: u.ID, Name: "Base", SystemMessage: &sys, ParentOnly: true,
	})
	if err != nil {
		t.Fatalf("create root: %v", err)
	}
	mustAttachPlugin(t, q, root.ID, 0, "basic_grounding", `{}`)

	child := mustProfile(t, q, u.ID, "Leaf", &root.ID)
	mustAttachPlugin(t, q, child.ID, 1, "lettered_choices", `{}`)

	bundle := decodeForTest(t, mustExport(t, svc, ctx, child.ID, false).Payload)

	if len(bundle.Profiles) != 1 {
		t.Fatalf("flatten should produce one profile, got %d", len(bundle.Profiles))
	}
	only := bundle.Profiles[0]
	if only.SystemMessage == nil || *only.SystemMessage != sys {
		t.Errorf("inherited system message missing: %v", only.SystemMessage)
	}
	if only.Name != "Leaf" {
		t.Errorf("name should be the leaf's: %q", only.Name)
	}
	if pluginByName(only, "basic_grounding") == nil || pluginByName(only, "lettered_choices") == nil {
		t.Errorf("flatten must carry the merged pipeline, got %d plugins", len(only.Plugins))
	}
}

func TestExport_PreserveKeepsChainRootFirst(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "exp-preserve")
	ctx := ctxAs(u)

	root := mustProfile(t, q, u.ID, "Base", nil)
	child := mustProfile(t, q, u.ID, "Leaf", &root.ID)

	bundle := decodeForTest(t, mustExport(t, svc, ctx, child.ID, true).Payload)
	if len(bundle.Profiles) != 2 {
		t.Fatalf("expected 2 profiles, got %d", len(bundle.Profiles))
	}
	if bundle.Profiles[0].Name != "Base" {
		t.Errorf("root must come first so import can rewire parents: got %q", bundle.Profiles[0].Name)
	}
	if bundle.Profiles[1].ParentRef != bundle.Profiles[0].Ref {
		t.Errorf("child's parent_ref should name the root's ref")
	}
}

func TestExport_RejectsForeignProfile(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	owner := mustCreateUser(t, q, "exp-owner")
	other := mustCreateUser(t, q, "exp-other")
	p := mustProfile(t, q, owner.ID, "Private", nil)

	_, err := svc.ExportProfile(ctxAs(other), connect.NewRequest(&psmithv1.ExportProfileRequest{
		ProfileId: p.ID.String(),
	}))
	if err == nil {
		t.Fatal("exporting another user's profile must fail")
	}
}

// --- bundle framing --------------------------------------------------------

func TestDecodeBundle_RejectsForeignBytes(t *testing.T) {
	t.Parallel()
	// proto.Unmarshal accepts plenty of arbitrary input, which is exactly why
	// the magic prefix exists.
	if _, err := decodeBundle([]byte("just some text")); err == nil {
		t.Error("expected a bad-header error")
	}
	if _, err := decodeBundle(nil); err == nil {
		t.Error("expected a bad-header error for empty input")
	}
}

func TestDecodeBundle_RefusesNewerFormat(t *testing.T) {
	t.Parallel()
	body, err := proto.Marshal(&psmithv1.ProfileBundle{Version: bundleVersion + 1})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	_, err = decodeBundle(append(append([]byte{}, bundleMagic...), body...))
	if err == nil || !strings.Contains(err.Error(), "newer") {
		t.Errorf("expected a version refusal, got %v", err)
	}
}

// --- import ----------------------------------------------------------------

func TestImport_RoundTripsAcrossUsers(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	sender := mustCreateUser(t, q, "imp-sender")
	recipient := mustCreateUser(t, q, "imp-recipient")

	sys := "be concise"
	src, err := q.CreateProfile(context.Background(), store.CreateProfileParams{
		ID: uuid.New(), UserID: sender.ID, Name: "Shared", SystemMessage: &sys,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	mustAttachPlugin(t, q, src.ID, 0, "lettered_choices", `{"keep_last_n":4}`)

	payload := mustExport(t, svc, ctxAs(sender), src.ID, false).Payload

	resp, err := svc.ImportProfile(ctxAs(recipient), connect.NewRequest(&psmithv1.ImportProfileRequest{Payload: payload}))
	if err != nil {
		t.Fatalf("ImportProfile: %v", err)
	}
	if len(resp.Msg.Profiles) != 1 {
		t.Fatalf("expected 1 imported profile, got %d", len(resp.Msg.Profiles))
	}
	got := resp.Msg.Profiles[0]
	if got.Name != "Shared" || got.SystemMessage == nil || *got.SystemMessage != sys {
		t.Errorf("profile did not round-trip: %+v", got)
	}
	if got.OwnerUserId != recipient.ID.String() {
		t.Errorf("imported profile must be owned by the importer, got %s", got.OwnerUserId)
	}

	newID, err := uuid.Parse(got.Id)
	if err != nil {
		t.Fatalf("parse id: %v", err)
	}
	if newID == src.ID {
		t.Error("import must mint a new id, never reuse the source's")
	}
	rows, err := q.ListProfilePlugins(context.Background(), newID)
	if err != nil {
		t.Fatalf("ListProfilePlugins: %v", err)
	}
	if len(rows) != 1 || rows[0].PluginName != "lettered_choices" {
		t.Fatalf("plugin did not come across: %+v", rows)
	}
	plain, err := crypto.ResolveSecret(crypto.Nop{}, rows[0].ConfigEncrypted, rows[0].Config)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if !strings.Contains(string(plain), `"keep_last_n":4`) {
		t.Errorf("config did not survive the round trip: %s", plain)
	}
}

func TestImport_WarnsWhenProviderNotConfigured(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	recipient := mustCreateUser(t, q, "imp-noprovider")

	bundle := &psmithv1.ProfileBundle{
		Version: bundleVersion,
		Profiles: []*psmithv1.BundledProfile{{
			Ref:          "a",
			Name:         "Needs Anthropic",
			DefaultModel: &psmithv1.ModelRef{ProviderType: "anthropic", ModelId: "claude-sonnet-4-5"},
		}},
	}
	resp, err := svc.ImportProfile(ctxAs(recipient), connect.NewRequest(&psmithv1.ImportProfileRequest{
		Payload: mustPack(t, bundle),
	}))
	if err != nil {
		t.Fatalf("ImportProfile: %v", err)
	}
	w := findWarning(resp.Msg.Warnings, psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_PROVIDER_MISSING)
	if w == nil {
		t.Fatalf("expected a provider-missing warning, got %+v", resp.Msg.Warnings)
	}
	if !strings.Contains(w.Message, "anthropic") {
		t.Errorf("warning should name the provider: %q", w.Message)
	}
	// The profile still imports; a missing default model is recoverable.
	if len(resp.Msg.Profiles) != 1 {
		t.Errorf("import should succeed despite the missing provider")
	}
}

func TestImport_WarnsOnMissingMCPServerAndSkipsAttachment(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	recipient := mustCreateUser(t, q, "imp-nomcp")

	name := "Linear"
	bundle := &psmithv1.ProfileBundle{
		Version: bundleVersion,
		Profiles: []*psmithv1.BundledProfile{{
			Ref:     "a",
			Name:    "Work",
			Plugins: []*psmithv1.BundledPlugin{{PluginName: "mcp", McpServerName: &name}},
		}},
	}
	resp, err := svc.ImportProfile(ctxAs(recipient), connect.NewRequest(&psmithv1.ImportProfileRequest{
		Payload: mustPack(t, bundle),
	}))
	if err != nil {
		t.Fatalf("ImportProfile: %v", err)
	}
	w := findWarning(resp.Msg.Warnings, psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_MCP_SERVER_MISSING)
	if w == nil || !strings.Contains(w.Message, "Linear") {
		t.Fatalf("expected a missing-mcp warning naming Linear, got %+v", resp.Msg.Warnings)
	}

	id, _ := uuid.Parse(resp.Msg.Profiles[0].Id)
	rows, err := q.ListProfilePlugins(context.Background(), id)
	if err != nil {
		t.Fatalf("ListProfilePlugins: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("an unresolvable MCP reference must not be attached, got %+v", rows)
	}
}

func TestImport_MatchesMCPServerByName(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	recipient := mustCreateUser(t, q, "imp-mcpmatch")

	srv, err := q.InsertUserMCPServer(context.Background(), store.InsertUserMCPServerParams{
		ID: uuid.New(), UserID: recipient.ID, Name: "Linear", ConfigEncrypted: []byte(`{}`),
	})
	if err != nil {
		t.Fatalf("InsertUserMCPServer: %v", err)
	}

	name := "linear" // case-insensitive on purpose
	resp, err := svc.ImportProfile(ctxAs(recipient), connect.NewRequest(&psmithv1.ImportProfileRequest{
		Payload: mustPack(t, &psmithv1.ProfileBundle{
			Version: bundleVersion,
			Profiles: []*psmithv1.BundledProfile{{
				Ref:     "a",
				Name:    "Work",
				Plugins: []*psmithv1.BundledPlugin{{PluginName: "mcp", McpServerName: &name}},
			}},
		}),
	}))
	if err != nil {
		t.Fatalf("ImportProfile: %v", err)
	}
	id, _ := uuid.Parse(resp.Msg.Profiles[0].Id)
	rows, _ := q.ListProfilePlugins(context.Background(), id)
	if len(rows) != 1 || rows[0].PluginName != "mcp:"+srv.ID.String() {
		t.Fatalf("expected the reference rebound to the importer's server, got %+v", rows)
	}
}

func TestImport_WarnsOnUnknownPlugin(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	recipient := mustCreateUser(t, q, "imp-unknownplugin")

	resp, err := svc.ImportProfile(ctxAs(recipient), connect.NewRequest(&psmithv1.ImportProfileRequest{
		Payload: mustPack(t, &psmithv1.ProfileBundle{
			Version: bundleVersion,
			Profiles: []*psmithv1.BundledProfile{{
				Ref:     "a",
				Name:    "Exotic",
				Plugins: []*psmithv1.BundledPlugin{{PluginName: "not_a_real_plugin"}},
			}},
		}),
	}))
	if err != nil {
		t.Fatalf("ImportProfile: %v", err)
	}
	if findWarning(resp.Msg.Warnings, psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_PLUGIN_UNKNOWN) == nil {
		t.Errorf("expected an unknown-plugin warning, got %+v", resp.Msg.Warnings)
	}
}

func TestImport_SuffixesCollidingNames(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "imp-collide")
	mustProfile(t, q, u.ID, "Shared", nil)

	payload := mustPack(t, &psmithv1.ProfileBundle{
		Version:  bundleVersion,
		Profiles: []*psmithv1.BundledProfile{{Ref: "a", Name: "Shared"}},
	})
	resp, err := svc.ImportProfile(ctxAs(u), connect.NewRequest(&psmithv1.ImportProfileRequest{Payload: payload}))
	if err != nil {
		t.Fatalf("ImportProfile: %v", err)
	}
	if got := resp.Msg.Profiles[0].Name; got != "Shared (2)" {
		t.Errorf("expected a suffixed name, got %q", got)
	}
	if len(resp.Msg.Renamed) != 1 {
		t.Errorf("rename should be reported: %+v", resp.Msg.Renamed)
	}
	if findWarning(resp.Msg.Warnings, psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_RENAMED) == nil {
		t.Error("expected a rename warning")
	}
}

func TestImport_PreservedChainRewiresParents(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	sender := mustCreateUser(t, q, "imp-chain-src")
	recipient := mustCreateUser(t, q, "imp-chain-dst")

	root := mustProfile(t, q, sender.ID, "Base", nil)
	child := mustProfile(t, q, sender.ID, "Leaf", &root.ID)

	payload := mustExport(t, svc, ctxAs(sender), child.ID, true).Payload
	resp, err := svc.ImportProfile(ctxAs(recipient), connect.NewRequest(&psmithv1.ImportProfileRequest{Payload: payload}))
	if err != nil {
		t.Fatalf("ImportProfile: %v", err)
	}
	if len(resp.Msg.Profiles) != 2 {
		t.Fatalf("expected 2 profiles, got %d", len(resp.Msg.Profiles))
	}
	newRoot, newLeaf := resp.Msg.Profiles[0], resp.Msg.Profiles[1]
	if newLeaf.ParentProfileId == nil || *newLeaf.ParentProfileId != newRoot.Id {
		t.Errorf("child should point at the newly created root, got %v", newLeaf.ParentProfileId)
	}
	if *newLeaf.ParentProfileId == root.ID.String() {
		t.Error("child must not point at the sender's row")
	}
}

func TestImport_DryRunWritesNothing(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "imp-dryrun")

	before, err := q.ListProfilesByUser(context.Background(), u.ID)
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	resp, err := svc.ImportProfile(ctxAs(u), connect.NewRequest(&psmithv1.ImportProfileRequest{
		DryRun: true,
		Payload: mustPack(t, &psmithv1.ProfileBundle{
			Version: bundleVersion,
			Profiles: []*psmithv1.BundledProfile{{
				Ref:          "a",
				Name:         "Preview",
				DefaultModel: &psmithv1.ModelRef{ProviderType: "anthropic", ModelId: "x"},
			}},
		}),
	}))
	if err != nil {
		t.Fatalf("ImportProfile: %v", err)
	}
	if len(resp.Msg.Profiles) != 0 {
		t.Error("dry run must not report created profiles")
	}
	if len(resp.Msg.Warnings) == 0 {
		t.Error("dry run should still report what would not resolve")
	}
	after, err := q.ListProfilesByUser(context.Background(), u.ID)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(after) != len(before) {
		t.Errorf("dry run wrote rows: %d before, %d after", len(before), len(after))
	}
}

func TestImport_RejectsEmptyBundle(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, "imp-empty")
	_, err := svc.ImportProfile(ctxAs(u), connect.NewRequest(&psmithv1.ImportProfileRequest{
		Payload: mustPack(t, &psmithv1.ProfileBundle{Version: bundleVersion}),
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- small helpers ---------------------------------------------------------

func mustPack(t *testing.T, b *psmithv1.ProfileBundle) []byte {
	t.Helper()
	body, err := proto.Marshal(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return append(append([]byte{}, bundleMagic...), body...)
}

func findWarning(ws []*psmithv1.ImportWarning, kind psmithv1.ImportWarningKind) *psmithv1.ImportWarning {
	for _, w := range ws {
		if w.Kind == kind {
			return w
		}
	}
	return nil
}
