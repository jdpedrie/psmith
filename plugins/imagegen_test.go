package plugins

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestImagegen_DefaultsAndDescriptor(t *testing.T) {
	t.Parallel()
	pl, err := newImagegen(nil)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	if pl.Name() != ImagegenName {
		t.Errorf("Name=%q want %q", pl.Name(), ImagegenName)
	}
	if pl.Description() == "" {
		t.Error("Description must be non-empty")
	}
	if _, ok := pl.(ToolProvider); !ok {
		t.Error("must implement ToolProvider")
	}
	if _, ok := pl.(Configurable); !ok {
		t.Error("must implement Configurable")
	}
}

func TestImagegen_RejectsMissingAPIKey(t *testing.T) {
	t.Parallel()
	pl, _ := newImagegen(nil)
	tp := pl.(ToolProvider)
	_, err := tp.ExecuteTool(context.Background(), "generate_image", json.RawMessage(`{"prompt":"a cat"}`))
	if err == nil {
		t.Fatal("expected error when api_key is unset")
	}
	if !strings.Contains(err.Error(), "api_key") {
		t.Errorf("error should mention api_key: %v", err)
	}
}

func TestImagegen_RejectsMissingPrompt(t *testing.T) {
	t.Parallel()
	pl, _ := newImagegen(json.RawMessage(`{"api_key":"k"}`))
	tp := pl.(ToolProvider)
	_, err := tp.ExecuteTool(context.Background(), "generate_image", json.RawMessage(`{}`))
	if err == nil {
		t.Fatal("expected error for empty prompt")
	}
	if !strings.Contains(err.Error(), "prompt") {
		t.Errorf("error should mention prompt: %v", err)
	}
}

func TestImagegen_PostsToEndpointAndReturnsImage(t *testing.T) {
	t.Parallel()
	// Tiny 1×1 PNG bytes (valid file header) so the test exercises
	// real base64 round-tripping rather than asserting bytewise
	// against a fixed payload.
	pngBytes := []byte{
		0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
		0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	}
	encoded := base64.StdEncoding.EncodeToString(pngBytes)

	var capturedBody []byte
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		capturedBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[{"b64_json":"` + encoded + `","revised_prompt":"a smiling tabby"}]}`))
	}))
	defer srv.Close()

	cfg, _ := json.Marshal(imagegenConfig{
		APIKey:           "sk-test",
		Model:            "gpt-image-1",
		Size:             "1024x1024",
		Quality:          "high",
		EndpointOverride: srv.URL,
	})
	pl, err := newImagegen(cfg)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	tp := pl.(ToolProvider)
	out, err := tp.ExecuteTool(context.Background(), "generate_image", json.RawMessage(`{"prompt":"a cat"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}

	// Auth header check.
	if gotAuth != "Bearer sk-test" {
		t.Errorf("Authorization=%q want %q", gotAuth, "Bearer sk-test")
	}
	// Body must include the prompt + model + size + quality.
	for _, want := range []string{`"prompt":"a cat"`, `"model":"gpt-image-1"`, `"size":"1024x1024"`, `"quality":"high"`} {
		if !strings.Contains(string(capturedBody), want) {
			t.Errorf("request body missing %q\nfull: %s", want, capturedBody)
		}
	}
	// gpt-image-1 must NOT include response_format (only dall-e-3 does).
	if strings.Contains(string(capturedBody), "response_format") {
		t.Errorf("gpt-image-1 must not include response_format; body: %s", capturedBody)
	}

	// Output JSON should round-trip the prompt + revised_prompt.
	var got map[string]any
	if err := json.Unmarshal(out.Output, &got); err != nil {
		t.Fatalf("decode output: %v", err)
	}
	if got["prompt"] != "a cat" {
		t.Errorf("prompt round-trip: got %v", got["prompt"])
	}
	if got["revised_prompt"] != "a smiling tabby" {
		t.Errorf("revised_prompt round-trip: got %v", got["revised_prompt"])
	}

	// Attachment shape: 1 image, mime image/png, bytes match.
	if len(out.Attachments) != 1 {
		t.Fatalf("attachments=%d want 1", len(out.Attachments))
	}
	att := out.Attachments[0]
	if att.Kind != "image" || att.MimeType != "image/png" {
		t.Errorf("attachment kind/mime wrong: %+v", att)
	}
	if string(att.Data) != string(pngBytes) {
		t.Errorf("attachment data didn't round-trip; got %d bytes", len(att.Data))
	}
}

func TestImagegen_DallE3SetsResponseFormat(t *testing.T) {
	t.Parallel()
	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"data":[{"b64_json":"` + base64.StdEncoding.EncodeToString([]byte{0x89, 0x50}) + `"}]}`))
	}))
	defer srv.Close()

	cfg, _ := json.Marshal(imagegenConfig{
		APIKey:           "sk-test",
		Model:            "dall-e-3",
		Size:             "1024x1024",
		Quality:          "hd",
		EndpointOverride: srv.URL,
	})
	pl, _ := newImagegen(cfg)
	tp := pl.(ToolProvider)
	if _, err := tp.ExecuteTool(context.Background(), "generate_image", json.RawMessage(`{"prompt":"x"}`)); err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if !strings.Contains(string(capturedBody), `"response_format":"b64_json"`) {
		t.Errorf("dall-e-3 must include response_format=b64_json; body: %s", capturedBody)
	}
}

func TestImagegen_RejectsUnknownTool(t *testing.T) {
	t.Parallel()
	pl, _ := newImagegen(json.RawMessage(`{"api_key":"k"}`))
	tp := pl.(ToolProvider)
	_, err := tp.ExecuteTool(context.Background(), "wat", json.RawMessage(`{}`))
	if err == nil {
		t.Fatal("expected error for unknown tool")
	}
}

func TestImagegen_PerCallSizeOverride(t *testing.T) {
	t.Parallel()
	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"data":[{"b64_json":"` + base64.StdEncoding.EncodeToString([]byte{0x89}) + `"}]}`))
	}))
	defer srv.Close()

	cfg, _ := json.Marshal(imagegenConfig{
		APIKey:           "k",
		Model:            "gpt-image-1",
		Size:             "1024x1024", // default
		Quality:          "high",
		EndpointOverride: srv.URL,
	})
	pl, _ := newImagegen(cfg)
	tp := pl.(ToolProvider)
	if _, err := tp.ExecuteTool(context.Background(), "generate_image", json.RawMessage(`{"prompt":"x","size":"1536x1024"}`)); err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if !strings.Contains(string(capturedBody), `"size":"1536x1024"`) {
		t.Errorf("per-call size override should win over plugin default; body: %s", capturedBody)
	}
}
