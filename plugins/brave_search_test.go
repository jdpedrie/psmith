package plugins

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBraveSearch_Describe(t *testing.T) {
	d, err := Describe(BraveSearchName)
	if err != nil {
		t.Fatalf("Describe: %v", err)
	}
	if !d.Capabilities.ToolProvider {
		t.Errorf("expected ToolProvider capability")
	}
	if !d.Capabilities.Configurable {
		t.Errorf("expected Configurable capability")
	}
	if got := len(d.ConfigFields); got < 2 {
		t.Errorf("expected at least 2 config fields, got %d", got)
	}
}

func TestBraveSearch_NewWithMissingAPIKey(t *testing.T) {
	// Empty config → constructor must succeed (Describe contract). Missing
	// API key only blows up at ExecuteTool time.
	p, err := newBraveSearch(nil)
	if err != nil {
		t.Fatalf("newBraveSearch(nil): %v", err)
	}
	bs := p.(*braveSearch)
	_, err = bs.ExecuteTool(context.Background(), "web_search", json.RawMessage(`{"query":"x"}`))
	if err == nil || !strings.Contains(err.Error(), "api_key") {
		t.Errorf("expected api_key error, got %v", err)
	}
}

func TestBraveSearch_RejectsBadSafeSearch(t *testing.T) {
	cfg := json.RawMessage(`{"api_key":"k","safesearch":"yolo"}`)
	if _, err := newBraveSearch(cfg); err == nil {
		t.Errorf("expected error on invalid safesearch")
	}
}

func TestBraveSearch_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("X-Subscription-Token"); got != "testkey" {
			t.Errorf("missing/bad subscription token header: %q", got)
		}
		q := r.URL.Query()
		if q.Get("q") != "anthropic claude" {
			t.Errorf("unexpected q: %q", q.Get("q"))
		}
		if q.Get("count") != "3" {
			t.Errorf("expected count=3, got %q", q.Get("count"))
		}
		if q.Get("safesearch") != "moderate" {
			t.Errorf("expected safesearch=moderate, got %q", q.Get("safesearch"))
		}
		if q.Get("freshness") != "pw" {
			t.Errorf("expected freshness=pw, got %q", q.Get("freshness"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"web": {
				"results": [
					{"title":"Anthropic","url":"https://anthropic.com","description":"AI safety","age":"2 days ago"},
					{"title":"Claude","url":"https://claude.ai","description":"Anthropic's assistant","age":""}
				]
			}
		}`))
	}))
	defer srv.Close()

	cfg, _ := json.Marshal(braveSearchConfig{
		APIKey:           "testkey",
		DefaultCount:     5,
		SafeSearch:       "moderate",
		EndpointOverride: srv.URL,
	})
	p, err := newBraveSearch(cfg)
	if err != nil {
		t.Fatalf("newBraveSearch: %v", err)
	}
	bs := p.(*braveSearch)

	input := json.RawMessage(`{"query":"anthropic claude","count":3,"freshness":"pw"}`)
	out, err := bs.ExecuteTool(context.Background(), "web_search", input)
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}

	var decoded braveSearchOutput
	if err := json.Unmarshal(out.Output, &decoded); err != nil {
		t.Fatalf("decode output: %v", err)
	}
	if decoded.Query != "anthropic claude" {
		t.Errorf("query roundtrip: %q", decoded.Query)
	}
	if len(decoded.Results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(decoded.Results))
	}
	if decoded.Results[0].URL != "https://anthropic.com" {
		t.Errorf("result[0] url: %q", decoded.Results[0].URL)
	}
	if decoded.Results[0].Age != "2 days ago" {
		t.Errorf("result[0] age: %q", decoded.Results[0].Age)
	}
}

func TestBraveSearch_NonOKStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"bad token"}`))
	}))
	defer srv.Close()

	cfg, _ := json.Marshal(braveSearchConfig{
		APIKey:           "x",
		EndpointOverride: srv.URL,
	})
	p, _ := newBraveSearch(cfg)
	bs := p.(*braveSearch)

	_, err := bs.ExecuteTool(context.Background(), "web_search", json.RawMessage(`{"query":"hi"}`))
	if err == nil {
		t.Fatalf("expected error on 401")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("expected status in error, got: %v", err)
	}
}

func TestBraveSearch_RejectsEmptyQuery(t *testing.T) {
	cfg, _ := json.Marshal(braveSearchConfig{APIKey: "x"})
	p, _ := newBraveSearch(cfg)
	bs := p.(*braveSearch)
	_, err := bs.ExecuteTool(context.Background(), "web_search", json.RawMessage(`{"query":"   "}`))
	if err == nil || !strings.Contains(err.Error(), "query is required") {
		t.Errorf("expected query-required error, got: %v", err)
	}
}

func TestBraveSearch_UnknownToolName(t *testing.T) {
	cfg, _ := json.Marshal(braveSearchConfig{APIKey: "x"})
	p, _ := newBraveSearch(cfg)
	bs := p.(*braveSearch)
	_, err := bs.ExecuteTool(context.Background(), "fetch_page", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Errorf("expected unknown-tool error, got: %v", err)
	}
}
