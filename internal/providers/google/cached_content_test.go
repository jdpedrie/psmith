package google

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jdpedrie/clark/internal/providers"
)

// TestCreateCachedContent_HappyPath asserts the request body shape and that
// the response is decoded into a CachedContent struct with the expected
// fields populated.
func TestCreateCachedContent_HappyPath(t *testing.T) {
	var capturedBody string
	var capturedKey string

	mux := http.NewServeMux()
	mux.HandleFunc("/v1beta/cachedContents", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method=%s want POST", r.Method)
		}
		buf := make([]byte, 64*1024)
		n, _ := r.Body.Read(buf)
		capturedBody = string(buf[:n])
		capturedKey = r.URL.Query().Get("key")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"name": "cachedContents/abc123",
			"model": "models/gemini-2.5-flash",
			"displayName": "test-cache",
			"createTime": "2026-04-30T00:00:00Z",
			"expireTime": "2026-04-30T00:05:00Z",
			"usageMetadata": { "totalTokenCount": 4321 }
		}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	cc, err := d.CreateCachedContent(context.Background(), CreateCachedContentRequest{
		ModelID:           "gemini-2.5-flash",
		DisplayName:       "test-cache",
		SystemInstruction: "You are a helpful assistant.",
		Messages: []providers.WireMessage{
			{Role: "user", Content: "ping"},
			{Role: "assistant", Content: "pong"},
		},
		TTL: "300s",
	})
	if err != nil {
		t.Fatalf("CreateCachedContent: %v", err)
	}

	if capturedKey != "test-key" {
		t.Errorf("key query param=%q want test-key", capturedKey)
	}

	// Wire shape: model is "models/<id>", systemInstruction has the seed +
	// nothing else, contents has one user + one model role, ttl set.
	var body createCachedContentBody
	if err := json.Unmarshal([]byte(capturedBody), &body); err != nil {
		t.Fatalf("parse body: %v; body=%s", err, capturedBody)
	}
	if body.Model != "models/gemini-2.5-flash" {
		t.Errorf("model=%q want models/gemini-2.5-flash", body.Model)
	}
	if body.DisplayName != "test-cache" {
		t.Errorf("displayName=%q", body.DisplayName)
	}
	if body.TTL != "300s" {
		t.Errorf("ttl=%q want 300s", body.TTL)
	}
	if body.SystemInstruction == nil ||
		len(body.SystemInstruction.Parts) != 1 ||
		body.SystemInstruction.Parts[0].Text != "You are a helpful assistant." {
		t.Errorf("systemInstruction wrong: %+v", body.SystemInstruction)
	}
	if len(body.Contents) != 2 {
		t.Fatalf("contents count=%d want 2", len(body.Contents))
	}
	if body.Contents[0].Role != "user" || body.Contents[1].Role != "model" {
		t.Errorf("roles=[%s,%s] want [user,model]",
			body.Contents[0].Role, body.Contents[1].Role)
	}

	// Decoded response.
	if cc.Name != "cachedContents/abc123" {
		t.Errorf("name=%q", cc.Name)
	}
	if cc.Model != "models/gemini-2.5-flash" {
		t.Errorf("model=%q", cc.Model)
	}
	if cc.UsageMetadata == nil || cc.UsageMetadata.TotalTokenCount != 4321 {
		t.Errorf("usageMetadata=%+v", cc.UsageMetadata)
	}
}

func TestCreateCachedContent_RequiresContent(t *testing.T) {
	d := newDriverWithBaseURL(t, "http://unused", providers.Deps{})
	_, err := d.CreateCachedContent(context.Background(), CreateCachedContentRequest{
		ModelID: "gemini-2.5-flash",
	})
	if err == nil || !strings.Contains(err.Error(), "system_instruction or messages") {
		t.Errorf("want empty-content error, got %v", err)
	}
}

func TestCreateCachedContent_RequiresModelID(t *testing.T) {
	d := newDriverWithBaseURL(t, "http://unused", providers.Deps{})
	_, err := d.CreateCachedContent(context.Background(), CreateCachedContentRequest{
		SystemInstruction: "hi",
	})
	if err == nil || !strings.Contains(err.Error(), "model_id") {
		t.Errorf("want model_id error, got %v", err)
	}
}

func TestCreateCachedContent_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"prefix too short"}}`))
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	_, err := d.CreateCachedContent(context.Background(), CreateCachedContentRequest{
		ModelID:           "gemini-2.5-flash",
		SystemInstruction: "tiny",
	})
	if err == nil || !strings.Contains(err.Error(), "HTTP 400") {
		t.Errorf("want 400 surface, got %v", err)
	}
}

func TestGetCachedContent_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1beta/cachedContents/abc123" {
			t.Errorf("path=%s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"name":"cachedContents/abc123","model":"models/gemini-2.5-flash"}`))
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	cc, err := d.GetCachedContent(context.Background(), "cachedContents/abc123")
	if err != nil {
		t.Fatalf("GetCachedContent: %v", err)
	}
	if cc.Name != "cachedContents/abc123" {
		t.Errorf("name=%q", cc.Name)
	}
}

func TestGetCachedContent_RejectsBareID(t *testing.T) {
	d := newDriverWithBaseURL(t, "http://unused", providers.Deps{})
	if _, err := d.GetCachedContent(context.Background(), "abc123"); err == nil {
		t.Error("expected validation error for bare id")
	}
}

func TestDeleteCachedContent_HappyPath(t *testing.T) {
	var sawDelete bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete && r.URL.Path == "/v1beta/cachedContents/abc123" {
			sawDelete = true
			w.WriteHeader(http.StatusOK)
			return
		}
		t.Errorf("unexpected request method=%s path=%s", r.Method, r.URL.Path)
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	if err := d.DeleteCachedContent(context.Background(), "cachedContents/abc123"); err != nil {
		t.Fatalf("DeleteCachedContent: %v", err)
	}
	if !sawDelete {
		t.Error("expected DELETE request")
	}
}

// 404 is treated as success — already-gone resources are not an error
// for the "ensure deleted" semantics we want.
func TestDeleteCachedContent_404IsOK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	if err := d.DeleteCachedContent(context.Background(), "cachedContents/missing"); err != nil {
		t.Errorf("404 should be OK, got %v", err)
	}
}

func TestDeleteCachedContent_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"message":"boom"}}`))
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	err := d.DeleteCachedContent(context.Background(), "cachedContents/abc")
	if err == nil || !strings.Contains(err.Error(), "HTTP 500") {
		t.Errorf("want 500 surface, got %v", err)
	}
}

// TestSend_CachedContentRefThreadsToWire verifies that
// CallSettings.Google.CachedContent passes through to the streamGenerateContent
// request body as `cachedContent`.
func TestSend_CachedContentRefThreadsToWire(t *testing.T) {
	const term = "data: {}\n\n"
	srv, captured := captureRequest(t, "/v1beta/models/gemini-test:streamGenerateContent", term)

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	cacheRef := "cachedContents/abc123"

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: providers.CallSettings{
			Google: &providers.GoogleExtras{
				CachedContent: &cacheRef,
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	var parsed generateContentRequest
	if err := json.Unmarshal([]byte(*captured), &parsed); err != nil {
		t.Fatalf("parse: %v; body=%s", err, *captured)
	}
	if parsed.CachedContent != cacheRef {
		t.Errorf("cachedContent=%q want %q; body=%s", parsed.CachedContent, cacheRef, *captured)
	}
}

// Empty *string is treated as unset — should not appear on the wire.
func TestSend_EmptyCachedContentOmitted(t *testing.T) {
	const term = "data: {}\n\n"
	srv, captured := captureRequest(t, "/v1beta/models/gemini-test:streamGenerateContent", term)

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	empty := ""

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: providers.CallSettings{
			Google: &providers.GoogleExtras{CachedContent: &empty},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}
	if strings.Contains(*captured, "cachedContent") {
		t.Errorf("expected cachedContent omitted; body=%s", *captured)
	}
}
