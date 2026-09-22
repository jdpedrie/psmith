package openai

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/server/providers"
)

func TestSend_Responses_ToolArguments(t *testing.T) {
	// Interleaved upstream calls must become contiguous start/delta/end
	// groups: the tool loop and persisted transcript consume one at a time.
	events := []string{
		`{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"get_profile","arguments":""}}`,
		`{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"get_profile","arguments":""}}`,
		`{"type":"response.function_call_arguments.delta","item_id":"fc_a","delta":"{\"id\":"}`,
		`{"type":"response.function_call_arguments.delta","item_id":"fc_b","delta":"{\"id\":\"beta\"}"}`,
		`{"type":"response.function_call_arguments.delta","item_id":"fc_a","delta":"\"alpha\"}"}`,
		`{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"get_profile","arguments":"{\"id\":\"beta\"}"}}`,
		`{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"get_profile","arguments":"{\"id\":\"alpha\"}"}}`,
		// The complete item is authoritative even without argument deltas.
		`{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_c","call_id":"call_c","name":"get_profile","arguments":"{\"id\":\"gamma\"}"}}`,
		`{"type":"response.completed","response":{"id":"r","status":"completed"}}`,
	}
	var sse strings.Builder
	for _, event := range events {
		sse.WriteString("data: " + event + "\n\n")
	}
	srv, _ := captureRequest(t, "/v1/responses", sse.String())
	p, err := New(providers.Deps{}, validConfig(t, srv.URL+"/v1", ""))
	if err != nil {
		t.Fatal(err)
	}
	p = forceResponsesAPI(t, p)
	ch, err := p.(providers.StatelessProvider).Send(context.Background(), providers.SendRequest{
		ModelID: "gpt-5", Messages: []providers.WireMessage{{Role: "user", Content: "Read profiles"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var chunks []providers.Chunk
	for chunk := range ch {
		switch chunk.Type {
		case providers.ChunkToolUseStart, providers.ChunkToolUseDelta, providers.ChunkToolUseEnd:
			chunks = append(chunks, chunk)
		case providers.ChunkError:
			t.Fatalf("stream error: %s", chunk.Payload)
		}
	}
	if len(chunks) != 9 {
		t.Fatalf("expected three complete tool calls; got %+v", chunks)
	}
	for i, want := range []struct{ callID, profileID string }{{"call_b", "beta"}, {"call_a", "alpha"}, {"call_c", "gamma"}} {
		group := chunks[i*3 : i*3+3]
		if group[0].Type != providers.ChunkToolUseStart || group[1].Type != providers.ChunkToolUseDelta || group[2].Type != providers.ChunkToolUseEnd {
			t.Fatalf("interleaved tool chunks: %+v", group)
		}
		var start struct{ ID, Name string }
		var delta struct {
			PartialJSON string `json:"partial_json"`
		}
		if err := json.Unmarshal(group[0].Payload, &start); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(group[1].Payload, &delta); err != nil {
			t.Fatal(err)
		}
		if start.ID != want.callID || start.Name != "get_profile" || delta.PartialJSON != `{"id":"`+want.profileID+`"}` {
			t.Errorf("wrong call or arguments: start=%+v delta=%+v", start, delta)
		}
	}
}

func TestBuildResponseParams_Tools(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"profile_id":{"type":"string"}},"required":[]}`)
	params, err := buildResponseParams(providers.SendRequest{
		ModelID: "gpt-5",
		Tools: []providers.ToolDef{
			{Name: "get_profile", Description: "Read a profile", InputSchema: schema},
			{Name: "list_profiles"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	var wire struct {
		Tools []struct {
			Type        string         `json:"type"`
			Name        string         `json:"name"`
			Description string         `json:"description"`
			Parameters  map[string]any `json:"parameters"`
			Strict      *bool          `json:"strict"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(body, &wire); err != nil {
		t.Fatal(err)
	}
	if len(wire.Tools) != 2 {
		t.Fatalf("expected both tools in Responses request: %s", body)
	}
	for _, tool := range wire.Tools {
		if tool.Type != "function" || tool.Strict == nil || *tool.Strict {
			t.Errorf("expected function tool with explicit strict=false: %+v", tool)
		}
	}
	var want map[string]any
	_ = json.Unmarshal(schema, &want)
	if got := wire.Tools[0]; got.Name != "get_profile" || got.Description != "Read a profile" || !reflect.DeepEqual(got.Parameters, want) {
		t.Errorf("tool definition changed: %+v", got)
	}
	if got := wire.Tools[1]; got.Name != "list_profiles" || got.Parameters["type"] != "object" {
		t.Errorf("missing default object schema: %+v", got)
	}
}

func TestBuildResponseParams_InvalidToolSchema(t *testing.T) {
	for _, schema := range []string{`{`, `[]`, `null`} {
		t.Run(schema, func(t *testing.T) {
			_, err := buildResponseParams(providers.SendRequest{
				ModelID: "gpt-5",
				Tools:   []providers.ToolDef{{Name: "broken_tool", InputSchema: json.RawMessage(schema)}},
			})
			if err == nil || !strings.Contains(err.Error(), "broken_tool") {
				t.Fatalf("expected error identifying the invalid tool; got %v", err)
			}
		})
	}
}

func TestBuildResponseParams_NoTools(t *testing.T) {
	params, err := buildResponseParams(providers.SendRequest{ModelID: "gpt-5"})
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]json.RawMessage
	if err := json.Unmarshal(body, &wire); err != nil {
		t.Fatal(err)
	}
	if _, exists := wire["tools"]; exists {
		t.Fatalf("unexpected tools field: %s", body)
	}
}
