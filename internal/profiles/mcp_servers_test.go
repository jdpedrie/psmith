package profiles

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/mcpreg"
	"github.com/jdpedrie/psmith/plugins"
)

func TestMCPServers_CreateAndListWithheldSecrets(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "mcp-create")
	ctx := ctxAs(user)

	created, err := svc.UpsertMCPServer(ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Name:      "Firecrawl",
		Transport: "http",
		Url:       "https://mcp.firecrawl.test/rpc",
		Headers:   strPtr("Authorization: Bearer fc-secret"),
	}))
	if err != nil {
		t.Fatalf("UpsertMCPServer: %v", err)
	}
	s := created.Msg.Server
	if s.Id == "" || s.Name != "Firecrawl" || s.Transport != "http" {
		t.Errorf("created projection wrong: %+v", s)
	}
	if !s.HasHeaders {
		t.Error("has_headers should be true")
	}

	listed, err := svc.ListMCPServers(ctx, connect.NewRequest(&psmithv1.ListMCPServersRequest{}))
	if err != nil {
		t.Fatalf("ListMCPServers: %v", err)
	}
	if len(listed.Msg.Servers) != 1 {
		t.Fatalf("servers len = %d want 1", len(listed.Msg.Servers))
	}
	got := listed.Msg.Servers[0]
	if got.Url != "https://mcp.firecrawl.test/rpc" || !got.HasHeaders || got.HasEnv {
		t.Errorf("list projection wrong: %+v", got)
	}
}

func TestMCPServers_UpdateAbsentSecretsKept(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "mcp-update")
	ctx := ctxAs(user)

	created, err := svc.UpsertMCPServer(ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Name:      "Local FS",
		Transport: "stdio",
		Command:   "npx",
		Args:      "-y\nsome-mcp-server",
		Env:       strPtr("API_KEY=hunter2"),
	}))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	id := uuid.MustParse(created.Msg.Server.Id)

	// Save from an edit form that never displays secrets: env ABSENT.
	updated, err := svc.UpsertMCPServer(ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Id:        id.String(),
		Name:      "Local FS",
		Transport: "stdio",
		Command:   "uvx",
		Args:      "-y\nsome-mcp-server",
	}))
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if !updated.Msg.Server.HasEnv {
		t.Error("absent env should keep the stored value")
	}
	_, spec, err := mcpreg.Load(ctx, qs, crypto.Nop{}, user.ID, id)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if spec.Env != "API_KEY=hunter2" || spec.Command != "uvx" {
		t.Errorf("spec after update = %+v", spec)
	}

	// Present-but-empty env clears.
	cleared, err := svc.UpsertMCPServer(ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Id:        id.String(),
		Name:      "Local FS",
		Transport: "stdio",
		Command:   "uvx",
		Env:       strPtr(""),
	}))
	if err != nil {
		t.Fatalf("clear: %v", err)
	}
	if cleared.Msg.Server.HasEnv {
		t.Error("present-but-empty env should clear the stored value")
	}
}

func TestMCPServers_DuplicateNameRejected(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "mcp-dup")
	ctx := ctxAs(user)

	mk := func() (*connect.Response[psmithv1.UpsertMCPServerResponse], error) {
		return svc.UpsertMCPServer(ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
			Name: "Same", Transport: "inproc",
		}))
	}
	if _, err := mk(); err != nil {
		t.Fatalf("first: %v", err)
	}
	_, err := mk()
	assertConnectCode(t, err, connect.CodeAlreadyExists)
}

func TestMCPServers_BadTransportRejected(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "mcp-badtransport")

	_, err := svc.UpsertMCPServer(ctxAs(user), connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Name: "X", Transport: "carrier-pigeon",
	}))
	assertConnectCode(t, err, connect.CodeInvalidArgument)
}

func TestMCPServers_DeleteOwnerScoped(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	owner := mustCreateUser(t, qs, "mcp-del-owner")
	stranger := mustCreateUser(t, qs, "mcp-del-stranger")

	created, err := svc.UpsertMCPServer(ctxAs(owner), connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Name: "Mine", Transport: "inproc",
	}))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	id := created.Msg.Server.Id

	_, err = svc.DeleteMCPServer(ctxAs(stranger), connect.NewRequest(&psmithv1.DeleteMCPServerRequest{Id: id}))
	assertConnectCode(t, err, connect.CodeNotFound)

	if _, err := svc.DeleteMCPServer(ctxAs(owner), connect.NewRequest(&psmithv1.DeleteMCPServerRequest{Id: id})); err != nil {
		t.Fatalf("owner delete: %v", err)
	}
	_, err = svc.DeleteMCPServer(ctxAs(owner), connect.NewRequest(&psmithv1.DeleteMCPServerRequest{Id: id}))
	assertConnectCode(t, err, connect.CodeNotFound)
}

func TestListPluginTypes_IncludesRegisteredMCPServersPerUser(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	owner := mustCreateUser(t, qs, "mcp-types-owner")
	other := mustCreateUser(t, qs, "mcp-types-other")

	created, err := svc.UpsertMCPServer(ctxAs(owner), connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Name:      "Firecrawl",
		Transport: "http",
		Url:       "https://mcp.firecrawl.test/rpc",
	}))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	refName := mcpreg.Prefix + created.Msg.Server.Id

	resp, err := svc.ListPluginTypes(ctxAs(owner), connect.NewRequest(&psmithv1.ListPluginTypesRequest{}))
	if err != nil {
		t.Fatalf("ListPluginTypes: %v", err)
	}
	var pseudo *psmithv1.PluginType
	for _, pt := range resp.Msg.PluginTypes {
		if pt.Name == refName {
			pseudo = pt
		}
	}
	if pseudo == nil {
		t.Fatalf("pseudo-plugin %s missing; got %v", refName, names(resp.Msg.PluginTypes))
	}
	if pseudo.DisplayName != "Firecrawl" {
		t.Errorf("display_name = %q", pseudo.DisplayName)
	}
	if pseudo.Capabilities == nil || !pseudo.Capabilities.ToolProvider {
		t.Errorf("pseudo entry must carry the mcp tool_provider capability: %+v", pseudo.Capabilities)
	}
	if len(pseudo.ConfigFields) != 1 || pseudo.ConfigFields[0].Name != "tool_prefix" {
		t.Errorf("config fields = %+v want single tool_prefix override", pseudo.ConfigFields)
	}

	otherResp, err := svc.ListPluginTypes(ctxAs(other), connect.NewRequest(&psmithv1.ListPluginTypesRequest{}))
	if err != nil {
		t.Fatalf("ListPluginTypes(other): %v", err)
	}
	for _, pt := range otherResp.Msg.PluginTypes {
		if pt.Name == refName {
			t.Error("another user's registry entry leaked into the plugin list")
		}
	}
}

// NOT parallel: RegisterInprocMCPDispatcher is process-global, and the
// inproc transport's pool entry is shared across every inproc plugin
// in the test binary.
func TestMCPServers_TestProbe(t *testing.T) {
	svc, qs := newTestSvc(t)
	user := mustCreateUser(t, qs, "mcp-probe")
	ctx := ctxAs(user)

	plugins.RegisterInprocMCPDispatcher(func(_ context.Context, body []byte) ([]byte, error) {
		var req struct {
			ID     int64  `json:"id"`
			Method string `json:"method"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			return nil, err
		}
		switch req.Method {
		case "initialize":
			return fmt.Appendf(nil, `{"jsonrpc":"2.0","id":%d,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"fake","version":"0"}}}`, req.ID), nil
		case "tools/list":
			return fmt.Appendf(nil, `{"jsonrpc":"2.0","id":%d,"result":{"tools":[{"name":"probe_tool","description":"d","inputSchema":{}}]}}`, req.ID), nil
		default:
			return nil, nil
		}
	})
	t.Cleanup(func() { plugins.RegisterInprocMCPDispatcher(nil) })

	created, err := svc.UpsertMCPServer(ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Name: "Inproc", Transport: "inproc",
	}))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	resp, err := svc.TestMCPServer(ctx, connect.NewRequest(&psmithv1.TestMCPServerRequest{Id: created.Msg.Server.Id}))
	if err != nil {
		t.Fatalf("TestMCPServer: %v", err)
	}
	if !resp.Msg.Ok || len(resp.Msg.ToolNames) != 1 || resp.Msg.ToolNames[0] != "probe_tool" {
		t.Errorf("probe = %+v want ok with [probe_tool]", resp.Msg)
	}

	// Unreachable http server: failure is the RESPONSE, not an RPC error.
	dead, err := svc.UpsertMCPServer(ctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Name: "Dead", Transport: "http", Url: "http://127.0.0.1:1/rpc",
	}))
	if err != nil {
		t.Fatalf("create dead: %v", err)
	}
	deadResp, err := svc.TestMCPServer(ctx, connect.NewRequest(&psmithv1.TestMCPServerRequest{Id: dead.Msg.Server.Id}))
	if err != nil {
		t.Fatalf("TestMCPServer(dead): %v", err)
	}
	if deadResp.Msg.Ok || deadResp.Msg.ErrorMessage == "" {
		t.Errorf("dead probe = %+v want ok=false with message", deadResp.Msg)
	}

	// Foreign/dangling id → NotFound.
	_, err = svc.TestMCPServer(ctx, connect.NewRequest(&psmithv1.TestMCPServerRequest{Id: uuid.NewString()}))
	assertConnectCode(t, err, connect.CodeNotFound)
}

func TestSetProfilePlugins_MCPRefs(t *testing.T) {
	t.Parallel()
	svc, qs := newTestSvc(t)
	owner := mustCreateUser(t, qs, "mcp-attach-owner")
	stranger := mustCreateUser(t, qs, "mcp-attach-stranger")
	profile := makeProfilePlain(t, qs, owner.ID, nil)

	created, err := svc.UpsertMCPServer(ctxAs(owner), connect.NewRequest(&psmithv1.UpsertMCPServerRequest{
		Name: "Firecrawl", Transport: "http", Url: "https://mcp.firecrawl.test/rpc",
	}))
	if err != nil {
		t.Fatalf("create server: %v", err)
	}
	ref := mcpreg.Prefix + created.Msg.Server.Id

	// Valid reference attaches.
	if _, err := svc.SetProfilePlugins(ctxAs(owner), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: profile.ID.String(),
		Plugins:   []*psmithv1.ProfilePlugin{{PluginName: ref}},
	})); err != nil {
		t.Fatalf("attach valid ref: %v", err)
	}

	// Dangling id rejected at attach time.
	_, err = svc.SetProfilePlugins(ctxAs(owner), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: profile.ID.String(),
		Plugins:   []*psmithv1.ProfilePlugin{{PluginName: mcpreg.RefName(uuid.New())}},
	}))
	assertConnectCode(t, err, connect.CodeInvalidArgument)

	// Someone else's server id rejected (their profile, my registry row).
	strangerProfile := makeProfilePlain(t, qs, stranger.ID, nil)
	_, err = svc.SetProfilePlugins(ctxAs(stranger), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: strangerProfile.ID.String(),
		Plugins:   []*psmithv1.ProfilePlugin{{PluginName: ref}},
	}))
	assertConnectCode(t, err, connect.CodeInvalidArgument)
}
