package mcpreg

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"
)

func seed(t *testing.T) (*store.Queries, store.User, store.UserMcpServer) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	ctx := context.Background()

	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(ctx, store.CreateUserParams{
		ID: uid, Username: "mcpreg-" + uid.String()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	spec := SpecConfig{
		Transport:  "http",
		URL:        "https://mcp.example.test/rpc",
		Headers:    "Authorization: Bearer secret-token",
		ToolPrefix: "fc",
	}
	cfg, _ := json.Marshal(spec)
	sid, _ := uuid.NewV7()
	row, err := q.InsertUserMCPServer(ctx, store.InsertUserMCPServerParams{
		ID: sid, UserID: user.ID, Name: "Firecrawl", ConfigEncrypted: cfg, // Nop cipher: plaintext bytes
	})
	if err != nil {
		t.Fatalf("InsertUserMCPServer: %v", err)
	}
	return q, user, row
}

func TestResolve_PassthroughForNonRefs(t *testing.T) {
	t.Parallel()
	q, user, _ := seed(t)
	name, cfg, err := Resolve(context.Background(), q, crypto.Nop{}, user.ID, "brave_search", json.RawMessage(`{"a":1}`), true)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if name != "brave_search" || string(cfg) != `{"a":1}` {
		t.Errorf("passthrough mangled: name=%q cfg=%s", name, cfg)
	}
}

func TestResolve_MergesSpecAndAttachOverrides(t *testing.T) {
	t.Parallel()
	q, user, row := seed(t)
	ctx := context.Background()

	name, cfg, err := Resolve(ctx, q, crypto.Nop{}, user.ID, RefName(row.ID), json.RawMessage(`{"tool_prefix":"crawl"}`), true)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if name != BaseName {
		t.Errorf("name = %q want %q", name, BaseName)
	}
	var got SpecConfig
	if err := json.Unmarshal(cfg, &got); err != nil {
		t.Fatalf("decode merged: %v", err)
	}
	if got.URL != "https://mcp.example.test/rpc" || got.Headers != "Authorization: Bearer secret-token" {
		t.Errorf("registry spec fields lost: %+v", got)
	}
	if got.ToolPrefix != "crawl" {
		t.Errorf("attach override lost: tool_prefix = %q want %q", got.ToolPrefix, "crawl")
	}
}

func TestResolve_EmptyAttachValuesDoNotClearDefaults(t *testing.T) {
	t.Parallel()
	q, user, row := seed(t)

	// Client forms serialize untouched fields as "" — that must not
	// wipe the registry's default prefix.
	_, cfg, err := Resolve(context.Background(), q, crypto.Nop{}, user.ID, RefName(row.ID), json.RawMessage(`{"tool_prefix":""}`), true)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	var got SpecConfig
	_ = json.Unmarshal(cfg, &got)
	if got.ToolPrefix != "fc" {
		t.Errorf("tool_prefix = %q want registry default %q", got.ToolPrefix, "fc")
	}
}

func TestResolve_DanglingRef(t *testing.T) {
	t.Parallel()
	q, user, _ := seed(t)
	ctx := context.Background()
	missing := RefName(uuid.New())

	if _, _, err := Resolve(ctx, q, crypto.Nop{}, user.ID, missing, nil, true); !errors.Is(err, ErrNotFound) {
		t.Errorf("strict dangling: err = %v want ErrNotFound", err)
	}
	name, cfg, err := Resolve(ctx, q, crypto.Nop{}, user.ID, missing, nil, false)
	if err != nil {
		t.Fatalf("lenient dangling: %v", err)
	}
	if name != BaseName || string(cfg) != `{}` {
		t.Errorf("lenient dangling = (%q, %s) want (%q, {})", name, cfg, BaseName)
	}
}

func TestResolve_ForeignRowReadsAsNotFound(t *testing.T) {
	t.Parallel()
	q, _, row := seed(t)
	ctx := context.Background()

	oid, _ := uuid.NewV7()
	other, err := q.CreateUser(ctx, store.CreateUserParams{
		ID: oid, Username: "mcpreg-other-" + oid.String()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	if _, _, err := Resolve(ctx, q, crypto.Nop{}, other.ID, RefName(row.ID), nil, true); !errors.Is(err, ErrNotFound) {
		t.Errorf("foreign strict: err = %v want ErrNotFound", err)
	}
}

func TestRefIDAndRefName(t *testing.T) {
	t.Parallel()
	id := uuid.New()
	got, ok := RefID(RefName(id))
	if !ok || got != id {
		t.Errorf("RefID(RefName(id)) = (%v, %v)", got, ok)
	}
	if _, ok := RefID("mcp"); ok {
		t.Error("bare name must not parse as ref")
	}
	if _, ok := RefID("mcp:not-a-uuid"); ok {
		t.Error("malformed id must not parse as ref")
	}
}
