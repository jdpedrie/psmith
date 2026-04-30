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

func TestCountTokens(t *testing.T) {
	var captured string
	mux := http.NewServeMux()
	mux.HandleFunc("/v1beta/models/gemini-test:countTokens",
		func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost {
				t.Errorf("method=%s want POST", r.Method)
			}
			if got := r.URL.Query().Get("key"); got == "" {
				t.Errorf("missing key query param")
			}
			buf := make([]byte, 64*1024)
			n, _ := r.Body.Read(buf)
			captured = string(buf[:n])
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(countTokensResponse{TotalTokens: 42})
		})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	n, err := d.CountTokens(context.Background(), "gemini-test", []providers.WireMessage{
		{Role: "system", Content: "be brief"},
		{Role: "user", Content: "hello world"},
		{Role: "assistant", Content: "hi"},
	})
	if err != nil {
		t.Fatalf("CountTokens: %v", err)
	}
	if n != 42 {
		t.Errorf("n=%d want 42", n)
	}

	// Body must contain system_instruction + 2 contents.
	var parsed countTokensRequest
	if err := json.Unmarshal([]byte(captured), &parsed); err != nil {
		t.Fatalf("parse: %v; body=%s", err, captured)
	}
	if parsed.SystemInstruction == nil ||
		len(parsed.SystemInstruction.Parts) != 1 ||
		parsed.SystemInstruction.Parts[0].Text != "be brief" {
		t.Errorf("system_instruction wrong: %+v", parsed.SystemInstruction)
	}
	if len(parsed.Contents) != 2 {
		t.Errorf("contents=%d want 2", len(parsed.Contents))
	}
	// Roles user → "user", assistant → "model".
	if parsed.Contents[0].Role != "user" || parsed.Contents[1].Role != "model" {
		t.Errorf("contents roles=%v %v", parsed.Contents[0].Role, parsed.Contents[1].Role)
	}
}

func TestCountTokens_MissingModelID(t *testing.T) {
	d := newDriverWithBaseURL(t, "http://unused", providers.Deps{})
	_, err := d.CountTokens(context.Background(), "", []providers.WireMessage{
		{Role: "user", Content: "hi"},
	})
	if err == nil {
		t.Error("expected error for missing model_id")
	}
}

func TestCountTokens_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":403,"message":"denied"}}`))
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	_, err := d.CountTokens(context.Background(), "gemini-test", []providers.WireMessage{
		{Role: "user", Content: "hi"},
	})
	if err == nil {
		t.Fatal("expected error from upstream 403")
	}
	if !strings.Contains(err.Error(), "403") {
		t.Errorf("error=%v should mention 403", err)
	}
}
