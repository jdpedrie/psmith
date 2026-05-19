package conversations

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/plugins"
)

// makeMergeProfile creates a profile via raw query — focused on the merge
// tests, no profile-service ceremony.
func makeMergeProfile(t *testing.T, q *store.Queries, userID uuid.UUID, name string, parent *uuid.UUID) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := q.CreateProfile(context.Background(), store.CreateProfileParams{
		ID:              id,
		UserID:          userID,
		Name:            name,
		ParentProfileID: parent,
	}); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return id
}

func insertProfilePlugin(t *testing.T, q *store.Queries, profileID uuid.UUID, ordinal int32, name string, configJSON string, disabled bool) {
	t.Helper()
	var cfgBytes []byte
	if configJSON != "" {
		cfgBytes = []byte(configJSON)
	}
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID:       profileID,
		Ordinal:         ordinal,
		PluginName:      name,
		ConfigEncrypted: cfgBytes,
		Disabled:        disabled,
	}); err != nil {
		t.Fatalf("InsertProfilePlugin: %v", err)
	}
}

func insertConversationPlugin(t *testing.T, q *store.Queries, convID uuid.UUID, ordinal int32, name string, configJSON string, disabled bool) {
	t.Helper()
	var cfgBytes []byte
	if configJSON != "" {
		cfgBytes = []byte(configJSON)
	}
	if _, err := q.InsertConversationPlugin(context.Background(), store.InsertConversationPluginParams{
		ConversationID:  convID,
		Ordinal:         ordinal,
		PluginName:      name,
		ConfigEncrypted: cfgBytes,
		Disabled:        disabled,
	}); err != nil {
		t.Fatalf("InsertConversationPlugin: %v", err)
	}
}

// TestPluginMerge_ChildInheritsParentPlugins pins the new behaviour:
// a child profile WITH its own plugin rows no longer overrides the
// parent's pipeline wholesale — they merge.
func TestPluginMerge_ChildInheritsParentPlugins(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user := mustCreateUser(t, q, "alice")

	parentID := makeMergeProfile(t, q, user.ID, "parent", nil)
	insertProfilePlugin(t, q, parentID, 0, plugins.LetteredChoicesName, `{}`, false)

	childID := makeMergeProfile(t, q, user.ID, "child", &parentID)
	insertProfilePlugin(t, q, childID, 0, plugins.ComponentBuilderName, `{}`, false)

	rows, _, err := svc.mergedProfileChainRows(context.Background(), childID)
	if err != nil {
		t.Fatalf("mergedProfileChainRows: %v", err)
	}
	if !containsName(rows, plugins.LetteredChoicesName) {
		t.Errorf("expected parent's lettered_choices in merged set; got %v", pluginNames(rows))
	}
	if !containsName(rows, plugins.ComponentBuilderName) {
		t.Errorf("expected child's component_builder in merged set; got %v", pluginNames(rows))
	}
}

// TestPluginMerge_DisabledRowSubtractsInheritedPlugin — child can
// explicitly drop an inherited plugin via a disabled=true row.
func TestPluginMerge_DisabledRowSubtractsInheritedPlugin(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user := mustCreateUser(t, q, "alice")

	parentID := makeMergeProfile(t, q, user.ID, "parent", nil)
	insertProfilePlugin(t, q, parentID, 0, plugins.LetteredChoicesName, `{}`, false)

	childID := makeMergeProfile(t, q, user.ID, "child", &parentID)
	insertProfilePlugin(t, q, childID, 0, plugins.LetteredChoicesName, "", true)

	rows, _, err := svc.mergedProfileChainRows(context.Background(), childID)
	if err != nil {
		t.Fatalf("mergedProfileChainRows: %v", err)
	}
	if containsName(rows, plugins.LetteredChoicesName) {
		t.Errorf("expected disabled row to subtract inherited plugin; got %v", pluginNames(rows))
	}
}

// TestPluginMerge_ChildOverridesParentConfig — when both define the
// same plugin (enabled), child wins per first-by-name rule.
func TestPluginMerge_ChildOverridesParentConfig(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user := mustCreateUser(t, q, "alice")

	parentID := makeMergeProfile(t, q, user.ID, "parent", nil)
	insertProfilePlugin(t, q, parentID, 0, plugins.LetteredChoicesName, `{"keep_last_n":3}`, false)

	childID := makeMergeProfile(t, q, user.ID, "child", &parentID)
	insertProfilePlugin(t, q, childID, 0, plugins.LetteredChoicesName, `{"keep_last_n":7}`, false)

	rows, _, err := svc.mergedProfileChainRows(context.Background(), childID)
	if err != nil {
		t.Fatalf("mergedProfileChainRows: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row after child-wins merge; got %d", len(rows))
	}
	if string(rows[0].ConfigEncrypted) != `{"keep_last_n":7}` {
		t.Errorf("expected child config to win; got %q", string(rows[0].ConfigEncrypted))
	}
}

// TestPluginMerge_ConversationDisabledRemovesInheritedPlugin —
// conv-level disabled subtracts what the profile chain would have
// merged in.
func TestPluginMerge_ConversationDisabledRemovesInheritedPlugin(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user := mustCreateUser(t, q, "alice")

	profileID := makeMergeProfile(t, q, user.ID, "p", nil)
	insertProfilePlugin(t, q, profileID, 0, plugins.LetteredChoicesName, `{}`, false)

	convID := uuid.New()
	contextID := uuid.New()
	if _, err := q.CreateConversation(context.Background(), store.CreateConversationParams{
		ID: convID, UserID: user.ID, ProfileID: profileID,
	}); err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if _, err := q.CreateContext(context.Background(), store.CreateContextParams{
		ID: contextID, ConversationID: convID,
	}); err != nil {
		t.Fatalf("CreateContext: %v", err)
	}

	insertConversationPlugin(t, q, convID, 0, plugins.LetteredChoicesName, "", true)

	convRow, _ := q.GetConversationByID(context.Background(), convID)
	pipeline, err := svc.resolvePluginPipelineForConversation(context.Background(), convRow)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if len(pipeline) != 0 {
		t.Errorf("expected empty pipeline after conv disable; got %d entries", len(pipeline))
	}
}

func pluginNames(rows []mergedRow) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.Name
	}
	return out
}

func containsName(rows []mergedRow, name string) bool {
	for _, r := range rows {
		if r.Name == name {
			return true
		}
	}
	return false
}
