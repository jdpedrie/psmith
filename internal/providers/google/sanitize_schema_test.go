package google

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSanitizeGeminiSchema_StripsAdditionalProperties(t *testing.T) {
	in := json.RawMessage(`{"type":"object","additionalProperties":false,"properties":{"x":{"type":"string"}}}`)
	out := sanitizeGeminiSchema(in)
	if strings.Contains(string(out), "additionalProperties") {
		t.Errorf("expected additionalProperties stripped; got %s", string(out))
	}
	if !strings.Contains(string(out), `"type":"object"`) {
		t.Errorf("expected type:object preserved; got %s", string(out))
	}
	if !strings.Contains(string(out), `"properties"`) {
		t.Errorf("expected properties preserved; got %s", string(out))
	}
}

func TestSanitizeGeminiSchema_RecursesIntoNested(t *testing.T) {
	// Mirrors a real Gemini complaint at index 15:
	// "properties[1].value.items" had additionalProperties.
	in := json.RawMessage(`{
		"type":"object",
		"additionalProperties":false,
		"properties":{
			"plugins":{
				"type":"array",
				"items":{
					"type":"object",
					"additionalProperties":false,
					"properties":{"name":{"type":"string"}}
				}
			}
		}
	}`)
	out := sanitizeGeminiSchema(in)
	if strings.Contains(string(out), "additionalProperties") {
		t.Errorf("nested additionalProperties should be stripped; got %s", string(out))
	}
}

func TestSanitizeGeminiSchema_StripsSchemaMeta(t *testing.T) {
	in := json.RawMessage(`{"$schema":"http://json-schema.org/draft-07/schema#","type":"object"}`)
	out := sanitizeGeminiSchema(in)
	if strings.Contains(string(out), "$schema") {
		t.Errorf("$schema should be stripped; got %s", string(out))
	}
}

func TestSanitizeGeminiSchema_PreservesPlainSchema(t *testing.T) {
	in := json.RawMessage(`{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}`)
	out := sanitizeGeminiSchema(in)
	// Round-trip should preserve the shape — order may change but
	// every key is still present.
	var parsed map[string]any
	if err := json.Unmarshal(out, &parsed); err != nil {
		t.Fatalf("re-parse: %v", err)
	}
	if parsed["type"] != "object" {
		t.Errorf("type lost: %+v", parsed)
	}
	if _, ok := parsed["properties"]; !ok {
		t.Errorf("properties lost: %+v", parsed)
	}
	if _, ok := parsed["required"]; !ok {
		t.Errorf("required lost: %+v", parsed)
	}
}

func TestSanitizeGeminiSchema_MalformedFallsThrough(t *testing.T) {
	// Garbage in → garbage out (verbatim). The upstream call will
	// fail with a useful error; better than us silently dropping
	// the schema.
	in := json.RawMessage(`not json`)
	out := sanitizeGeminiSchema(in)
	if string(out) != string(in) {
		t.Errorf("malformed schema should pass through unchanged; got %s", string(out))
	}
}

func TestSanitizeGeminiSchema_EmptyPassesThrough(t *testing.T) {
	if got := sanitizeGeminiSchema(json.RawMessage{}); len(got) != 0 {
		t.Errorf("empty in, expected empty out; got %s", string(got))
	}
}
