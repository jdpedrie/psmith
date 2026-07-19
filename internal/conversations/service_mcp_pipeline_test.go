package conversations

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/internal/mcpreg"
	"github.com/jdpedrie/psmith/internal/providers"
	"github.com/jdpedrie/psmith/internal/store"
)

// The whole point of per-server pseudo-plugin identity: the chain
// merge dedupes and disables BY NAME, so two different MCP servers
// must not collapse onto one "mcp" slot, and a child must be able to
// disable one inherited server while keeping another.

func seedMCPServerRow(t *testing.T, q *store.Queries, userID uuid.UUID, name, url string) store.UserMcpServer {
	t.Helper()
	spec := mcpreg.SpecConfig{Transport: "http", URL: url, ToolPrefix: name}
	cfg, _ := json.Marshal(spec)
	id, _ := uuid.NewV7()
	row, err := q.InsertUserMCPServer(context.Background(), store.InsertUserMCPServerParams{
		ID: id, UserID: userID, Name: name, ConfigEncrypted: cfg, // Nop cipher
	})
	if err != nil {
		t.Fatalf("InsertUserMCPServer: %v", err)
	}
	return row
}

func attachPlugin(t *testing.T, q *store.Queries, profileID uuid.UUID, ordinal int32, name string, disabled bool) {
	t.Helper()
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID: profileID, Ordinal: ordinal, PluginName: name, Disabled: disabled,
	}); err != nil {
		t.Fatalf("InsertProfilePlugin(%s): %v", name, err)
	}
}

func TestPluginChainMerge_MCPServersKeepDistinctIdentity(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	ctx := context.Background()

	f := seedSendable(t, q, registerFakeDriver(t, "mcp-merge",
		[]providers.Chunk{textChunk("hi"), doneChunk()}, nil))
	serverA := seedMCPServerRow(t, q, f.user.ID, "linear", "https://mcp.linear.test/rpc")
	serverB := seedMCPServerRow(t, q, f.user.ID, "firecrawl", "https://mcp.firecrawl.test/rpc")

	// Parent carries both servers. Child disables A and keeps
	// inheriting B — only possible because each server has its own
	// pipeline identity.
	parent := f.profile
	attachPlugin(t, q, parent.ID, 0, mcpreg.RefName(serverA.ID), false)
	attachPlugin(t, q, parent.ID, 1, mcpreg.RefName(serverB.ID), false)

	childID, _ := uuid.NewV7()
	child, err := q.CreateProfile(ctx, store.CreateProfileParams{
		ID: childID, UserID: f.user.ID, ParentProfileID: &parent.ID, Name: "child",
	})
	if err != nil {
		t.Fatalf("CreateProfile(child): %v", err)
	}
	attachPlugin(t, q, child.ID, 0, mcpreg.RefName(serverA.ID), true)

	rows, owner, err := svc.mergedProfileChainRows(ctx, child.ID)
	if err != nil {
		t.Fatalf("mergedProfileChainRows: %v", err)
	}
	if owner != f.user.ID {
		t.Errorf("owner = %v want %v", owner, f.user.ID)
	}
	if len(rows) != 1 || rows[0].Name != mcpreg.RefName(serverB.ID) {
		t.Fatalf("merged rows = %+v want exactly [%s]", rows, mcpreg.RefName(serverB.ID))
	}

	// The surviving reference builds into a real pipeline entry with
	// the registry spec resolved in.
	pipeline, err := svc.buildPipeline(ctx, rows, owner)
	if err != nil {
		t.Fatalf("buildPipeline: %v", err)
	}
	if len(pipeline) != 1 || pipeline[0].Name() != mcpreg.BaseName {
		t.Fatalf("pipeline = %v want one mcp instance", pipeline)
	}
}

func TestBuildPipeline_DanglingMCPRefDegradesToNoOp(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	ctx := context.Background()

	f := seedSendable(t, q, registerFakeDriver(t, "mcp-dangle",
		[]providers.Chunk{textChunk("hi"), doneChunk()}, nil))
	attachPlugin(t, q, f.profile.ID, 0, mcpreg.RefName(uuid.New()), false)

	// A reference whose registry row is gone must not fail the build —
	// it resolves to an unconfigured mcp instance that no-ops.
	pipeline, err := svc.resolvePluginPipeline(ctx, f.profile.ID)
	if err != nil {
		t.Fatalf("resolvePluginPipeline: %v", err)
	}
	if len(pipeline) != 1 || pipeline[0].Name() != mcpreg.BaseName {
		t.Fatalf("pipeline = %v want one (unconfigured) mcp instance", pipeline)
	}
}
