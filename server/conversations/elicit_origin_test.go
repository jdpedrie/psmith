package conversations

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/pluginapi/host"
	"github.com/jdpedrie/psmith/server/elicit"
)

type originProbe struct{ got elicit.Origin }

func (*originProbe) Name() string        { return "probe" }
func (*originProbe) DisplayName() string { return "Probe Tools" }
func (*originProbe) Description() string { return "" }
func (*originProbe) Tools() []pluginapi.ToolDef {
	return []pluginapi.ToolDef{{Name: "ask_user"}}
}
func (p *originProbe) ExecuteTool(ctx context.Context, _ string, _ json.RawMessage) (pluginapi.ToolResult, error) {
	p.got = elicit.OriginFrom(ctx)
	return pluginapi.ToolResult{}, nil
}

// A tool that prompts the user runs with its plugin and tool name attached,
// which is what the elicit chunk reports as who is asking.
func TestToolDispatch_AttachesTheAskingTool(t *testing.T) {
	p := &originProbe{}
	dispatch := buildToolDispatch(pluginapi.Pipeline{p}, nil, nil, host.CallerInfo{}, nil)
	if _, err := dispatch(context.Background(), "ask_user", nil); err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if p.got != (elicit.Origin{Source: "Probe Tools", Tool: "ask_user"}) {
		t.Errorf("origin = %+v", p.got)
	}
}

// The client hands the origin from the calling context to the chunk emitter.
func TestElicitClient_EmitsTheOrigin(t *testing.T) {
	b := newElicitBroker()
	var got elicit.Origin
	done := make(chan struct{})
	c := newElicitClient(b, uuid.New(), func(_ uuid.UUID, _ elicit.Request, o elicit.Origin) {
		got = o
		close(done)
	})
	ctx, cancel := context.WithCancel(elicit.WithOrigin(context.Background(), elicit.Origin{Source: "GitHub", Tool: "create_issue"}))
	go func() { <-done; cancel() }()
	_, _ = c.Elicit(ctx, elicit.Request{Message: "?"})
	if got != (elicit.Origin{Source: "GitHub", Tool: "create_issue"}) {
		t.Errorf("origin = %+v", got)
	}
}

// The wire fragment keeps its author, so a client can route its actions.
func TestContentPartsToProto_KeepsThePlugin(t *testing.T) {
	part := pluginapi.NewFragmentPart("choice_list", []byte(`{}`), "k")
	part.Fragment.Plugin = "context_packs"
	out := contentPartsToProto([]pluginapi.ContentPart{part})
	if len(out) != 1 || out[0].GetPlugin() != "context_packs" {
		t.Errorf("fragments = %+v", out)
	}
}
