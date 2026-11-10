package conversations

import (
	"context"
	"errors"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	apptools "github.com/jdpedrie/psmith/plugins/app_tools"
	"github.com/jdpedrie/psmith/server/store"
)

// capsTestPipeline makes a profile (with profilePlugin, if any) and a
// conversation on it, lets convPlugin add conversation-level rows, and
// runs the gate on the built pipeline for a model that can only stream.
func capsTestPipeline(t *testing.T, profilePlugin string, convPlugin func(svc *Service, q *store.Queries, convID uuid.UUID)) error {
	t.Helper()
	svc, q, _ := newFullSvc(t)
	user := mustCreateUser(t, q, "alice")
	profileID := makeMergeProfile(t, q, user.ID, "p", nil)
	if profilePlugin != "" {
		insertProfilePlugin(t, q, profileID, 0, profilePlugin, `{}`, false)
	}
	convID := uuid.New()
	if _, err := q.CreateConversation(context.Background(), store.CreateConversationParams{
		ID: convID, UserID: user.ID, ProfileID: profileID,
	}); err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	convPlugin(svc, q, convID)
	conv, err := q.GetConversationByID(context.Background(), convID)
	if err != nil {
		t.Fatalf("GetConversationByID: %v", err)
	}
	pipeline, err := svc.resolvePluginPipelineForConversation(context.Background(), conv)
	if err != nil {
		t.Fatalf("resolve pipeline: %v", err)
	}
	// A model that can stream and nothing else.
	return validateModelCapabilities(pipeline, "plain-model", []byte(`{"streaming":true}`))
}

// A tool plugin attached to one conversation only: the profile requires
// nothing, so a gate reading the profile let the send through to a model
// that can't call tools.
func TestCapabilityGate_ConversationPluginIsChecked(t *testing.T) {
	t.Parallel()
	err := capsTestPipeline(t, "", func(_ *Service, q *store.Queries, convID uuid.UUID) {
		insertConversationPlugin(t, q, convID, 0, apptools.Name, `{}`, false)
	})
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("err = %v, want FailedPrecondition naming tool use", err)
	}
	var ce *connect.Error
	if errors.As(err, &ce) && !strings.Contains(ce.Message(), "tool") {
		t.Errorf("message %q doesn't name the missing capability", ce.Message())
	}
}

// The profile's tool plugin turned off for this conversation doesn't hold
// its sends to the profile's requirements.
func TestCapabilityGate_ConversationCanTurnAProfilePluginOff(t *testing.T) {
	t.Parallel()
	err := capsTestPipeline(t, apptools.Name, func(_ *Service, q *store.Queries, convID uuid.UUID) {
		insertConversationPlugin(t, q, convID, 0, apptools.Name, "", true)
	})
	if err != nil {
		t.Fatalf("err = %v, want the send allowed", err)
	}
}

// The profile's own tool plugin is still checked.
func TestCapabilityGate_ProfilePluginIsChecked(t *testing.T) {
	t.Parallel()
	err := capsTestPipeline(t, apptools.Name, func(*Service, *store.Queries, uuid.UUID) {})
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("err = %v, want FailedPrecondition", err)
	}
}
