package plugins

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeResolver returns a fixed (provider_type, api_key, base_url)
// triple for any (provider_id, model_id) lookup. Tests mount it
// via plugins.WithProviderResolver to drive imagegen's dispatch.
type fakeResolver struct {
	providerType string
	apiKey       string
	baseURL      string
}

func (f fakeResolver) ResolveModel(_ context.Context, providerID, modelID string) (ResolvedModel, error) {
	if f.apiKey == "" {
		return ResolvedModel{}, fmt.Errorf("fake resolver: no key configured")
	}
	return ResolvedModel{
		ProviderType: f.providerType,
		ProviderID:   providerID,
		ModelID:      modelID,
		APIKey:       f.apiKey,
		BaseURL:      f.baseURL,
	}, nil
}

func TestImagegen_DefaultsAndDescriptor(t *testing.T) {
	t.Parallel()
	pl, err := newImagegen(nil)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	if pl.Name() != ImagegenName {
		t.Errorf("Name=%q want %q", pl.Name(), ImagegenName)
	}
	if _, ok := pl.(ToolProvider); !ok {
		t.Error("must implement ToolProvider")
	}
	c, ok := pl.(Configurable)
	if !ok {
		t.Fatal("must implement Configurable")
	}
	fields := c.ConfigFields()
	// First field is the model picker with the
	// generates_images filter — UIs must see this to render the
	// chooser, so pin it.
	if len(fields) == 0 || fields[0].Name != "model" || fields[0].Type != ConfigFieldModelPicker {
		t.Fatalf("expected first field to be a model_picker named 'model', got %+v", fields)
	}
	if !fields[0].ModelPickerFilter.RequiresGeneratesImages {
		t.Error("model picker must require generates_images capability")
	}
}

func TestImagegen_RejectsMissingModel(t *testing.T) {
	t.Parallel()
	pl, _ := newImagegen(nil)
	tp := pl.(ToolProvider)
	ctx := WithProviderResolver(context.Background(), fakeResolver{providerType: "openai-compatible", apiKey: "k"})
	_, err := tp.ExecuteTool(ctx, "generate_image", json.RawMessage(`{"prompt":"a cat"}`))
	if err == nil || !strings.Contains(err.Error(), "model is not configured") {
		t.Fatalf("expected model-not-configured error, got %v", err)
	}
}

func TestImagegen_RejectsMissingResolver(t *testing.T) {
	t.Parallel()
	cfg, _ := json.Marshal(imagegenConfig{
		Model: imagegenModelRef{ProviderID: "p", ModelID: "gpt-image-1"},
	})
	pl, _ := newImagegen(cfg)
	tp := pl.(ToolProvider)
	_, err := tp.ExecuteTool(context.Background(), "generate_image", json.RawMessage(`{"prompt":"x"}`))
	if err == nil || !strings.Contains(err.Error(), "ProviderResolver") {
		t.Fatalf("expected resolver-missing error, got %v", err)
	}
}

func TestImagegen_OpenAIDispatch(t *testing.T) {
	t.Parallel()
	pngBytes := []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52}
	encoded := base64.StdEncoding.EncodeToString(pngBytes)

	var capturedBody []byte
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		capturedBody, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"data":[{"b64_json":"` + encoded + `","revised_prompt":"a smiling tabby"}]}`))
	}))
	defer srv.Close()

	cfg, _ := json.Marshal(imagegenConfig{
		Model:            imagegenModelRef{ProviderID: "p", ModelID: "gpt-image-1"},
		Size:             "1024x1024",
		Quality:          "high",
		EndpointOverride: srv.URL,
	})
	pl, _ := newImagegen(cfg)
	tp := pl.(ToolProvider)
	ctx := WithProviderResolver(context.Background(), fakeResolver{
		providerType: "openai-compatible",
		apiKey:       "sk-test",
	})
	out, err := tp.ExecuteTool(ctx, "generate_image", json.RawMessage(`{"prompt":"a cat"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if gotAuth != "Bearer sk-test" {
		t.Errorf("Authorization=%q want %q", gotAuth, "Bearer sk-test")
	}
	for _, want := range []string{`"prompt":"a cat"`, `"model":"gpt-image-1"`, `"size":"1024x1024"`, `"quality":"high"`} {
		if !strings.Contains(string(capturedBody), want) {
			t.Errorf("openai body missing %q\nfull: %s", want, capturedBody)
		}
	}
	if strings.Contains(string(capturedBody), "response_format") {
		t.Errorf("gpt-image-1 must not include response_format; body: %s", capturedBody)
	}
	if len(out.Attachments) != 1 || string(out.Attachments[0].Data) != string(pngBytes) {
		t.Errorf("attachment data didn't round-trip; got %d bytes", len(out.Attachments))
	}
	var meta map[string]any
	_ = json.Unmarshal(out.Output, &meta)
	if meta["revised_prompt"] != "a smiling tabby" {
		t.Errorf("revised_prompt round-trip failed: %v", meta["revised_prompt"])
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
		Model:            imagegenModelRef{ProviderID: "p", ModelID: "dall-e-3"},
		Size:             "1024x1024",
		Quality:          "hd",
		EndpointOverride: srv.URL,
	})
	pl, _ := newImagegen(cfg)
	tp := pl.(ToolProvider)
	ctx := WithProviderResolver(context.Background(), fakeResolver{
		providerType: "openai-compatible",
		apiKey:       "k",
	})
	if _, err := tp.ExecuteTool(ctx, "generate_image", json.RawMessage(`{"prompt":"x"}`)); err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if !strings.Contains(string(capturedBody), `"response_format":"b64_json"`) {
		t.Errorf("dall-e-3 must include response_format=b64_json; body: %s", capturedBody)
	}
}

func TestImagegen_GoogleDispatch(t *testing.T) {
	t.Parallel()
	pngBytes := []byte{0x89, 0x50, 0x4e, 0x47}
	encoded := base64.StdEncoding.EncodeToString(pngBytes)

	var gotKey string
	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotKey = r.Header.Get("x-goog-api-key")
		capturedBody, _ = io.ReadAll(r.Body)
		// Gemini-shaped response: candidates[0].content.parts[]
		// with one text part + one inlineData image part.
		_, _ = w.Write([]byte(`{
			"candidates": [{
				"content": {
					"parts": [
						{"text": "Here is the image you requested."},
						{"inlineData": {"mimeType": "image/png", "data": "` + encoded + `"}}
					]
				}
			}]
		}`))
	}))
	defer srv.Close()

	cfg, _ := json.Marshal(imagegenConfig{
		Model:            imagegenModelRef{ProviderID: "p", ModelID: "gemini-2.5-flash-image-preview"},
		EndpointOverride: srv.URL,
	})
	pl, _ := newImagegen(cfg)
	tp := pl.(ToolProvider)
	ctx := WithProviderResolver(context.Background(), fakeResolver{
		providerType: "google",
		apiKey:       "AIza-test",
	})
	out, err := tp.ExecuteTool(ctx, "generate_image", json.RawMessage(`{"prompt":"a watercolor of a fox"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if gotKey != "AIza-test" {
		t.Errorf("x-goog-api-key=%q want %q", gotKey, "AIza-test")
	}
	if !strings.Contains(string(capturedBody), `"responseModalities":["TEXT","IMAGE"]`) {
		t.Errorf("google body missing responseModalities; full: %s", capturedBody)
	}
	if !strings.Contains(string(capturedBody), `"text":"a watercolor of a fox"`) {
		t.Errorf("google body missing prompt; full: %s", capturedBody)
	}
	if len(out.Attachments) != 1 || string(out.Attachments[0].Data) != string(pngBytes) {
		t.Errorf("google attachment didn't round-trip; got %d attachments", len(out.Attachments))
	}
	var meta map[string]any
	_ = json.Unmarshal(out.Output, &meta)
	if meta["narration"] != "Here is the image you requested." {
		t.Errorf("narration round-trip failed: %v", meta["narration"])
	}
}

func TestImagegen_RejectsUnknownProviderType(t *testing.T) {
	t.Parallel()
	cfg, _ := json.Marshal(imagegenConfig{
		Model: imagegenModelRef{ProviderID: "p", ModelID: "claude-3-5-sonnet"},
	})
	pl, _ := newImagegen(cfg)
	tp := pl.(ToolProvider)
	ctx := WithProviderResolver(context.Background(), fakeResolver{
		providerType: "anthropic",
		apiKey:       "k",
	})
	_, err := tp.ExecuteTool(ctx, "generate_image", json.RawMessage(`{"prompt":"x"}`))
	if err == nil || !strings.Contains(err.Error(), "anthropic") {
		t.Fatalf("expected provider-type error, got %v", err)
	}
}
