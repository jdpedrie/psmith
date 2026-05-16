package mcpserver

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/conversations"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/modelproviders"
	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/internal/storage"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// --- harness ---

type fixture struct {
	server  *Server
	queries *store.Queries
	user    store.User
	ctx     context.Context
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)

	uid, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	user, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID:           uid,
		Username:     "mcpuser",
		PasswordHash: "x",
		IsAdmin:      false,
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	cipher := crypto.Nop{}
	catalog := modelmeta.NewLiveCatalog(nil)
	supervisor := stream.New(q, slog.Default())
	fileStore, err := storage.NewFS(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewFS: %v", err)
	}

	profilesSvc := profiles.NewService(q, pool, cipher)
	modelProvSvc := modelproviders.NewService(q, catalog, cipher, slog.Default())
	convSvc := conversations.NewService(q, pool, catalog, supervisor, cipher, fileStore, slog.Default())

	srv := New(profilesSvc, convSvc, modelProvSvc, slog.Default())

	ctx := auth.ContextWithUser(context.Background(), auth.User{
		ID:          user.ID,
		Username:    user.Username,
		DisplayName: user.DisplayName,
		IsAdmin:     user.IsAdmin,
		CreatedAt:   user.CreatedAt,
		UpdatedAt:   user.UpdatedAt,
	})
	return &fixture{server: srv, queries: q, user: user, ctx: ctx}
}

// callRPC marshals one JSON-RPC request, dispatches it, decodes the
// response. Returns the raw response object so tests can poke at
// either Result or Error. id=`1` is hard-coded; callers don't need to
// vary it.
func callRPC(t *testing.T, srv *Server, ctx context.Context, method string, params any) rpcResponse {
	t.Helper()
	body, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		ID      int    `json:"id"`
		Method  string `json:"method"`
		Params  any    `json:"params,omitempty"`
	}{JSONRPC: "2.0", ID: 1, Method: method, Params: params})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	out, err := srv.HandleRPC(ctx, body)
	if err != nil {
		t.Fatalf("HandleRPC: %v", err)
	}
	if out == nil {
		t.Fatalf("expected response bytes, got nil (notification?)")
	}
	var resp rpcResponse
	if err := json.Unmarshal(out, &resp); err != nil {
		t.Fatalf("unmarshal response: %v (body: %s)", err, string(out))
	}
	return resp
}

// callTool wraps tools/call and decodes the ToolResult.
func callTool(t *testing.T, srv *Server, ctx context.Context, name string, args any) ToolResult {
	t.Helper()
	resp := callRPC(t, srv, ctx, "tools/call", map[string]any{
		"name":      name,
		"arguments": args,
	})
	if resp.Error != nil {
		t.Fatalf("tools/call %s: rpc error: %+v", name, resp.Error)
	}
	var tr ToolResult
	if err := json.Unmarshal(resp.Result, &tr); err != nil {
		t.Fatalf("decode tool result: %v", err)
	}
	return tr
}

// --- protocol-level tests ---

func TestServer_Initialize(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	resp := callRPC(t, f.server, f.ctx, "initialize", map[string]any{
		"protocolVersion": ProtocolVersion,
		"capabilities":    map[string]any{},
		"clientInfo":      map[string]any{"name": "test", "version": "0.0"},
	})
	if resp.Error != nil {
		t.Fatalf("initialize errored: %+v", resp.Error)
	}
	var ir InitializeResult
	if err := json.Unmarshal(resp.Result, &ir); err != nil {
		t.Fatalf("decode initialize result: %v", err)
	}
	if ir.ProtocolVersion != ProtocolVersion {
		t.Errorf("protocol version: got %q, want %q", ir.ProtocolVersion, ProtocolVersion)
	}
	if ir.ServerInfo["name"] != "reeve" {
		t.Errorf("server name: %q", ir.ServerInfo["name"])
	}
}

func TestServer_NotificationReturnsNoBody(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	body := []byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	out, err := f.server.HandleRPC(f.ctx, body)
	if err != nil {
		t.Fatalf("HandleRPC: %v", err)
	}
	if out != nil {
		t.Errorf("expected nil response for notification, got %s", string(out))
	}
}

func TestServer_UnknownMethodReturnsRpcError(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	resp := callRPC(t, f.server, f.ctx, "no/such/method", nil)
	if resp.Error == nil {
		t.Fatal("expected rpc error for unknown method")
	}
	if resp.Error.Code != rpcCodeMethodNotFound {
		t.Errorf("error code: got %d want %d", resp.Error.Code, rpcCodeMethodNotFound)
	}
}

func TestServer_MalformedJSONReturnsParseError(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	out, err := f.server.HandleRPC(f.ctx, []byte("not json"))
	if err != nil {
		t.Fatalf("HandleRPC: %v", err)
	}
	var resp rpcResponse
	if err := json.Unmarshal(out, &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Error == nil || resp.Error.Code != rpcCodeParseError {
		t.Errorf("expected parse error, got %+v", resp.Error)
	}
}

// --- tools/list ---

func TestServer_ToolsListIncludesEverySchema(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	resp := callRPC(t, f.server, f.ctx, "tools/list", nil)
	if resp.Error != nil {
		t.Fatalf("tools/list errored: %+v", resp.Error)
	}
	var body struct {
		Tools []Tool `json:"tools"`
	}
	if err := json.Unmarshal(resp.Result, &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	want := map[string]bool{
		"list_profiles":       false,
		"get_profile":         false,
		"create_profile":      false,
		"update_profile":      false,
		"list_plugin_types":   false,
		"get_profile_plugins": false,
		"set_profile_plugins": false,
		"list_providers":      false,
		"list_models":         false,
		"list_conversations":  false,
		"get_conversation":    false,
		"list_messages":       false,
	}
	for _, tool := range body.Tools {
		if _, ok := want[tool.Name]; ok {
			want[tool.Name] = true
		}
		if tool.Description == "" {
			t.Errorf("tool %q has empty description", tool.Name)
		}
		// Every schema must be valid JSON.
		if !json.Valid(tool.InputSchema) {
			t.Errorf("tool %q has invalid input schema: %s", tool.Name, string(tool.InputSchema))
		}
	}
	for name, found := range want {
		if !found {
			t.Errorf("expected tool %q to be registered", name)
		}
	}
}

// --- tools/call: profiles round-trip ---

func TestTools_CreateAndListProfiles(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	// Empty list before any creates.
	res := callTool(t, f.server, f.ctx, "list_profiles", map[string]any{})
	if res.IsError {
		t.Fatalf("list_profiles errored: %+v", res)
	}

	// Create.
	res = callTool(t, f.server, f.ctx, "create_profile", map[string]any{
		"name":           "Test Profile",
		"description":    "from MCP",
		"system_message": "You are a tester.",
		"favorite":       true,
	})
	if res.IsError {
		t.Fatalf("create_profile errored: %+v", res)
	}
	var created struct {
		Profile map[string]any `json:"profile"`
	}
	mustDecodeText(t, res, &created)
	id, _ := created.Profile["id"].(string)
	if id == "" {
		t.Fatal("create_profile returned no id")
	}

	// List should now include it.
	res = callTool(t, f.server, f.ctx, "list_profiles", map[string]any{})
	var listed struct {
		Profiles []map[string]any `json:"profiles"`
	}
	mustDecodeText(t, res, &listed)
	if len(listed.Profiles) != 1 {
		t.Fatalf("expected 1 profile, got %d", len(listed.Profiles))
	}
	if listed.Profiles[0]["name"] != "Test Profile" {
		t.Errorf("name: %v", listed.Profiles[0]["name"])
	}

	// Get the detail.
	res = callTool(t, f.server, f.ctx, "get_profile", map[string]any{"id": id})
	var got struct {
		Profile map[string]any `json:"profile"`
	}
	mustDecodeText(t, res, &got)
	if got.Profile["system_message"] != "You are a tester." {
		t.Errorf("system_message: %v", got.Profile["system_message"])
	}
	if got.Profile["favorite"] != true {
		t.Errorf("favorite: %v", got.Profile["favorite"])
	}
}

func TestTools_UnknownToolReturnsIsError(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	res := callTool(t, f.server, f.ctx, "nope_not_a_tool", map[string]any{})
	if !res.IsError {
		t.Errorf("expected isError, got %+v", res)
	}
}

func TestTools_MissingRequiredArgReturnsIsError(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	res := callTool(t, f.server, f.ctx, "get_profile", map[string]any{})
	if !res.IsError {
		t.Errorf("expected isError for missing id, got %+v", res)
	}
}

// --- list_plugin_types ---

func TestTools_ListPluginTypesNonEmpty(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	res := callTool(t, f.server, f.ctx, "list_plugin_types", map[string]any{})
	if res.IsError {
		t.Fatalf("errored: %+v", res)
	}
	var body struct {
		PluginTypes []map[string]any `json:"plugin_types"`
	}
	mustDecodeText(t, res, &body)
	if len(body.PluginTypes) == 0 {
		t.Fatal("expected at least one plugin type to be registered")
	}
	// Spot-check shape: every entry must have a name + capabilities.
	for _, pt := range body.PluginTypes {
		if pt["name"] == "" {
			t.Errorf("plugin missing name: %+v", pt)
		}
	}
}

// --- HTTP handler + auth ---

func TestHandler_MissingAuthReturns401(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	h := Handler(f.server, f.queries)
	srv := httptest.NewServer(h)
	defer srv.Close()

	resp, err := http.Post(srv.URL, "application/json", bytes.NewReader([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status: got %d want %d", resp.StatusCode, http.StatusUnauthorized)
	}
}

func TestHandler_ValidBearerAttachesUser(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	rawToken := "test-token-mcp"
	if err := f.queries.CreateSession(context.Background(), store.CreateSessionParams{
		TokenHash: hashTokenForTest(rawToken),
		UserID:    f.user.ID,
		ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("CreateSession: %v", err)
	}

	h := Handler(f.server, f.queries)
	srv := httptest.NewServer(h)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL, bytes.NewReader([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)))
	req.Header.Set("Authorization", "Bearer "+rawToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status: got %d want 200 (body: %s)", resp.StatusCode, string(body))
	}
}

func TestHandler_GetReturns405(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	h := Handler(f.server, f.queries)
	srv := httptest.NewServer(h)
	defer srv.Close()
	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("status: got %d want 405", resp.StatusCode)
	}
}

func TestHandler_NotificationReturns202(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	rawToken := "test-token-notif"
	if err := f.queries.CreateSession(context.Background(), store.CreateSessionParams{
		TokenHash: hashTokenForTest(rawToken),
		UserID:    f.user.ID,
		ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("CreateSession: %v", err)
	}

	h := Handler(f.server, f.queries)
	srv := httptest.NewServer(h)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL, bytes.NewReader([]byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)))
	req.Header.Set("Authorization", "Bearer "+rawToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Errorf("status: got %d want 202", resp.StatusCode)
	}
}

// --- helpers ---

// mustDecodeText pulls the first text content item out of a ToolResult
// and unmarshals it into out. Tests expect every successful tool call
// to produce exactly one JSON text payload.
func mustDecodeText(t *testing.T, tr ToolResult, out any) {
	t.Helper()
	if len(tr.Content) == 0 {
		t.Fatalf("tool result has no content: %+v", tr)
	}
	if tr.Content[0].Type != "text" {
		t.Fatalf("expected text content, got %q", tr.Content[0].Type)
	}
	if err := json.Unmarshal([]byte(tr.Content[0].Text), out); err != nil {
		t.Fatalf("decode tool text: %v\nbody: %s", err, tr.Content[0].Text)
	}
}

// hashTokenForTest mirrors auth.hashToken (sha256 hex). Lives here
// because the production helper is unexported on purpose.
func hashTokenForTest(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}
