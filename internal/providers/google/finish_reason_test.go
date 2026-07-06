package google

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/psmith/internal/providers"
)

// Hard-failure finish reasons (system-level failures where retry chrome
// makes sense) must produce a non-empty error message.
func TestGeminiHardFailureMessage_HardReasonsHaveText(t *testing.T) {
	for _, reason := range []string{
		"MALFORMED_FUNCTION_CALL",
		"OTHER",
	} {
		if got := geminiHardFailureMessage(reason); got == "" {
			t.Errorf("expected hard-failure message for %q; got empty", reason)
		}
	}
}

// Safety-block finish reasons (model's deliberate refusal) must NOT
// produce an error message — finish_reason alone carries the signal,
// the message lands in history with a "Stopped: …" hint instead of the
// red error banner.
func TestGeminiHardFailureMessage_SafetyReasonsAreSoft(t *testing.T) {
	for _, reason := range []string{
		"SAFETY",
		"RECITATION",
		"BLOCKLIST",
		"PROHIBITED_CONTENT",
		"SPII",
		"IMAGE_SAFETY",
	} {
		if got := geminiHardFailureMessage(reason); got != "" {
			t.Errorf("expected empty hard-failure message for safety reason %q; got %q", reason, got)
		}
	}
}

func TestGeminiHardFailureMessage_NormalReasonsEmpty(t *testing.T) {
	for _, reason := range []string{"STOP", "MAX_TOKENS", "", "FINISH_REASON_UNSPECIFIED"} {
		if got := geminiHardFailureMessage(reason); got != "" {
			t.Errorf("expected empty error message for %q; got %q", reason, got)
		}
	}
}

func TestGeminiHardFailureMessage_MalformedMentionsTool(t *testing.T) {
	msg := geminiHardFailureMessage("MALFORMED_FUNCTION_CALL")
	if !strings.Contains(strings.ToLower(msg), "tool") {
		t.Errorf("expected MALFORMED_FUNCTION_CALL message to mention 'tool'; got %q", msg)
	}
}

// TestSend_MalformedFunctionCallEmitsUsageBeforeError pins the chunk
// ordering. openStreamWithRetry treats a ChunkError as the FIRST chunk
// as "retry from scratch"; for a deterministic Gemini failure
// (MALFORMED_FUNCTION_CALL with zero text + zero tool-use chunks) that
// would burn 3x prompt billing for the same outcome. Usage must come
// first so openOnce sees a non-error first chunk → success path → the
// trailing error gets captured by the consume loop and the message
// materialises as errored without a retry storm.
func TestSend_MalformedFunctionCallEmitsUsageBeforeError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Accel-Buffering", "no")
		evt := `{"candidates":[{"content":{"parts":[]},"finishReason":"MALFORMED_FUNCTION_CALL"}],"usageMetadata":{"promptTokenCount":1520,"totalTokenCount":1520}}`
		fmt.Fprintf(w, "data: %s\n\n", evt)
		w.(http.Flusher).Flush()
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ch, err := d.Send(ctx, providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var types []providers.ChunkType
	for c := range ch {
		types = append(types, c.Type)
	}

	if len(types) < 2 {
		t.Fatalf("expected at least Usage + Done; got %v", types)
	}
	if types[0] != providers.ChunkUsage {
		t.Errorf("first chunk must be Usage (so openStreamWithRetry sees success); got %q (full sequence: %v)", types[0], types)
	}
	sawError := false
	for _, t := range types {
		if t == providers.ChunkError {
			sawError = true
		}
	}
	if !sawError {
		t.Errorf("expected ChunkError somewhere in the sequence; got %v", types)
	}
}

// TestSend_ProhibitedContentEmitsFinishReasonOnly pins the new soft-
// failure semantics: when Gemini blocks the response under a safety
// filter (PROHIBITED_CONTENT here), the driver must NOT emit a
// ChunkError. The finish_reason rides the usage chunk so the message
// row lands in history with a "Stopped: prohibited_content" hint
// instead of the red error banner.
func TestSend_ProhibitedContentEmitsFinishReasonOnly(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Accel-Buffering", "no")
		evt := `{"candidates":[{"content":{"parts":[]},"finishReason":"PROHIBITED_CONTENT"}],"usageMetadata":{"promptTokenCount":50,"totalTokenCount":50}}`
		fmt.Fprintf(w, "data: %s\n\n", evt)
		w.(http.Flusher).Flush()
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ch, err := d.Send(ctx, providers.SendRequest{
		ModelID:  "gemini-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var (
		types       []providers.ChunkType
		usageReason string
	)
	for c := range ch {
		types = append(types, c.Type)
		if c.Type == providers.ChunkUsage {
			// Pull the finish_reason out of the usage payload so the
			// test can assert it survived to the supervisor.
			var u providers.Usage
			_ = json.Unmarshal(c.Payload, &u)
			if u.FinishReason != nil {
				usageReason = *u.FinishReason
			}
		}
	}

	for _, ty := range types {
		if ty == providers.ChunkError {
			t.Errorf("safety-block finish reason must not emit ChunkError; got sequence %v", types)
		}
	}
	if usageReason != "PROHIBITED_CONTENT" {
		t.Errorf("expected finish_reason=PROHIBITED_CONTENT on the usage chunk; got %q", usageReason)
	}
}
