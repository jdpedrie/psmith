package modelproviders

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

// probingDriver answers each probe differently, keyed off what the request
// carries. The whole point of a probe is that different capabilities produce
// different upstream behaviour, so a driver that returns one canned reply
// would test the plumbing and none of the judgement.
type probingDriver struct {
	typeName string
	// refuse maps a probe shape ("tools", "image", "thinking") to the error
	// the upstream returns for it.
	refuse map[string]string
	// silent probe shapes accept the request and answer in prose.
	silent map[string]bool
	seen   []string
}

func (d *probingDriver) Type() string                                  { return d.typeName }
func (d *probingDriver) Stateful() bool                                { return false }
func (d *probingDriver) RenderThinkingToText(_ json.RawMessage) string { return "" }
func (d *probingDriver) DiscoverModels(_ context.Context) ([]providers.Model, error) {
	return nil, nil
}

func shapeOf(req providers.SendRequest) string {
	if len(req.Tools) > 0 {
		return "tools"
	}
	for _, m := range req.Messages {
		if len(m.Attachments) > 0 {
			return "image"
		}
	}
	if req.Settings.ThinkingEffort().On() {
		return "thinking"
	}
	return "plain"
}

func (d *probingDriver) Send(_ context.Context, req providers.SendRequest) (<-chan providers.Chunk, error) {
	shape := shapeOf(req)
	d.seen = append(d.seen, shape)
	if msg, ok := d.refuse[shape]; ok {
		return nil, errStr(msg)
	}
	ch := make(chan providers.Chunk, 4)
	if !d.silent[shape] {
		switch shape {
		case "tools":
			raw, _ := json.Marshal(map[string]string{"id": "t1", "name": "echo"})
			ch <- providers.Chunk{Type: providers.ChunkToolUseStart, Payload: raw}
			ch <- providers.Chunk{Type: providers.ChunkToolUseEnd, Payload: []byte(`{}`)}
			close(ch)
			return ch, nil
		case "thinking":
			raw, _ := json.Marshal(map[string]string{"text": "17 x 23..."})
			ch <- providers.Chunk{Type: providers.ChunkThinking, Payload: raw}
		}
	}
	ch <- textChunkP("ok")
	ch <- doneChunkP()
	close(ch)
	return ch, nil
}

func seedProbeModel(t *testing.T, q *store.Queries, provID uuid.UUID, caps modelmeta.Capabilities) {
	t.Helper()
	blob, _ := json.Marshal(caps)
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: provID,
		ModelID:             "probe-me",
		DisplayName:         "Probe Me",
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  time.Now().UTC(),
		Capabilities:        blob,
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}
}

func registerProbingDriver(t *testing.T, prefix string, d *probingDriver) string {
	t.Helper()
	typeName := uniqueTypeName(t, prefix)
	d.typeName = typeName
	providers.Register(typeName, func(_ providers.Deps, _ json.RawMessage) (providers.Provider, error) {
		return d, nil
	})
	return typeName
}

func outcomeFor(resp *psmithv1.ProbeUserModelResponse, cap string) psmithv1.ProbeOutcome {
	for _, r := range resp.Results {
		if r.Capability == cap {
			return r.Outcome
		}
	}
	return psmithv1.ProbeOutcome_PROBE_OUTCOME_UNSPECIFIED
}

// A model that does everything, starting from a definition that claims
// nothing: the case the probe exists for.
func TestProbeUserModel_EnablesWhatTheModelDemonstrates(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "alice", false)
	d := &probingDriver{}
	typeName := registerProbingDriver(t, "probe-all", d)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)
	seedProbeModel(t, q, prov.ID, modelmeta.Capabilities{})

	resp, err := svc.ProbeUserModel(ctxAs(user), connect.NewRequest(&psmithv1.ProbeUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "probe-me",
		Apply:               true,
	}))
	if err != nil {
		t.Fatalf("ProbeUserModel: %v", err)
	}

	for _, cap := range []string{"streaming", "tool_use", "vision", "thinking"} {
		if got := outcomeFor(resp.Msg, cap); got != psmithv1.ProbeOutcome_PROBE_OUTCOME_SUPPORTED {
			t.Errorf("%s: got %v, want supported", cap, got)
		}
	}
	if got := outcomeFor(resp.Msg, "prompt_caching"); got != psmithv1.ProbeOutcome_PROBE_OUTCOME_SKIPPED {
		t.Errorf("prompt_caching should be skipped, got %v", got)
	}
	if len(resp.Msg.Enabled) != 4 {
		t.Errorf("expected 4 capabilities enabled, got %v", resp.Msg.Enabled)
	}

	// And it actually persisted.
	row, err := q.GetUserModel(context.Background(), store.GetUserModelParams{
		UserModelProviderID: prov.ID, ModelID: "probe-me",
	})
	if err != nil {
		t.Fatalf("GetUserModel: %v", err)
	}
	var stored modelmeta.Capabilities
	_ = json.Unmarshal(row.Capabilities, &stored)
	if !stored.Streaming || !stored.ToolUse || !stored.Vision || !stored.Thinking {
		t.Errorf("capabilities were not written: %+v", stored)
	}
}

// The default is a dry run, so the first thing a user does is read the results
// rather than discover a changed definition.
func TestProbeUserModel_DryRunWritesNothing(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "bob", false)
	typeName := registerProbingDriver(t, "probe-dry", &probingDriver{})
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)
	seedProbeModel(t, q, prov.ID, modelmeta.Capabilities{})

	resp, err := svc.ProbeUserModel(ctxAs(user), connect.NewRequest(&psmithv1.ProbeUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "probe-me",
		// Apply omitted.
	}))
	if err != nil {
		t.Fatalf("ProbeUserModel: %v", err)
	}
	if len(resp.Msg.Enabled) == 0 {
		t.Fatal("dry run should still report what it WOULD enable")
	}
	row, _ := q.GetUserModel(context.Background(), store.GetUserModelParams{
		UserModelProviderID: prov.ID, ModelID: "probe-me",
	})
	var stored modelmeta.Capabilities
	_ = json.Unmarshal(row.Capabilities, &stored)
	if stored.Streaming || stored.ToolUse {
		t.Errorf("a dry run must not write: %+v", stored)
	}
	if resp.Msg.Capabilities.Streaming {
		t.Error("a dry run should report the STORED set, not the merged one")
	}
}

// A refusal is reported and never acted on.
func TestProbeUserModel_ContradictionsAreReportedNotApplied(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "carol", false)
	d := &probingDriver{refuse: map[string]string{
		"image": "400: image input is not supported by this model",
	}}
	typeName := registerProbingDriver(t, "probe-contra", d)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)
	// Definition claims vision; the model refuses it.
	seedProbeModel(t, q, prov.ID, modelmeta.Capabilities{Vision: true})

	resp, err := svc.ProbeUserModel(ctxAs(user), connect.NewRequest(&psmithv1.ProbeUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "probe-me",
		Apply:               true,
	}))
	if err != nil {
		t.Fatalf("ProbeUserModel: %v", err)
	}
	if len(resp.Msg.Contradicted) != 1 || resp.Msg.Contradicted[0] != "vision" {
		t.Errorf("expected vision reported as contradicted, got %v", resp.Msg.Contradicted)
	}
	row, _ := q.GetUserModel(context.Background(), store.GetUserModelParams{
		UserModelProviderID: prov.ID, ModelID: "probe-me",
	})
	var stored modelmeta.Capabilities
	_ = json.Unmarshal(row.Capabilities, &stored)
	if !stored.Vision {
		t.Error("a contradiction must never clear the stored flag")
	}
}

// An outage must not be recorded as a fact about the model.
func TestProbeUserModel_TransientFailureChangesNothing(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "dave", false)
	d := &probingDriver{refuse: map[string]string{
		"plain": "dial tcp: connection refused", "tools": "dial tcp: connection refused",
		"image": "dial tcp: connection refused", "thinking": "dial tcp: connection refused",
	}}
	typeName := registerProbingDriver(t, "probe-down", d)
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)
	seedProbeModel(t, q, prov.ID, modelmeta.Capabilities{ToolUse: true})

	resp, err := svc.ProbeUserModel(ctxAs(user), connect.NewRequest(&psmithv1.ProbeUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "probe-me",
		Apply:               true,
	}))
	if err != nil {
		t.Fatalf("a provider outage should not fail the RPC: %v", err)
	}
	if len(resp.Msg.Enabled) != 0 {
		t.Errorf("nothing should be enabled from a total outage, got %v", resp.Msg.Enabled)
	}
	if len(resp.Msg.Contradicted) != 0 {
		t.Errorf("an outage is not a contradiction, got %v", resp.Msg.Contradicted)
	}
	row, _ := q.GetUserModel(context.Background(), store.GetUserModelParams{
		UserModelProviderID: prov.ID, ModelID: "probe-me",
	})
	var stored modelmeta.Capabilities
	_ = json.Unmarshal(row.Capabilities, &stored)
	if !stored.ToolUse {
		t.Error("an outage must leave the stored definition alone")
	}
}

func TestProbeUserModel_RejectsUnknownModel(t *testing.T) {
	t.Parallel()
	svc, q, _, _ := newTestService(t)
	user := mustUser(t, q, "erin", false)
	typeName := registerProbingDriver(t, "probe-404", &probingDriver{})
	prov := makeProvider(t, q, user.ID, typeName, "main", nil)

	_, err := svc.ProbeUserModel(ctxAs(user), connect.NewRequest(&psmithv1.ProbeUserModelRequest{
		UserModelProviderId: prov.ID.String(),
		ModelId:             "never-enabled",
	}))
	if err == nil {
		t.Fatal("probing a model that is not enabled should fail")
	}
	if connect.CodeOf(err) != connect.CodeNotFound {
		t.Errorf("code = %v want not_found", connect.CodeOf(err))
	}
}
