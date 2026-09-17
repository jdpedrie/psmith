package openai

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/server/providers"
)

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
