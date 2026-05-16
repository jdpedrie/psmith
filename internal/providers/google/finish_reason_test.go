package google

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/reeve/internal/providers"
)

func TestGeminiFinishReasonErrorMessage_FailureReasonsHaveText(t *testing.T) {
	for _, reason := range []string{
		"MALFORMED_FUNCTION_CALL",
		"SAFETY",
		"RECITATION",
		"BLOCKLIST",
		"PROHIBITED_CONTENT",
		"SPII",
		"IMAGE_SAFETY",
		"OTHER",
	} {
		got := geminiFinishReasonErrorMessage(reason)
		if got == "" {
			t.Errorf("expected error message for %q; got empty", reason)
		}
	}
}

func TestGeminiFinishReasonErrorMessage_NormalReasonsEmpty(t *testing.T) {
	for _, reason := range []string{"STOP", "MAX_TOKENS", "", "FINISH_REASON_UNSPECIFIED"} {
		if got := geminiFinishReasonErrorMessage(reason); got != "" {
			t.Errorf("expected empty error message for %q; got %q", reason, got)
		}
	}
}

func TestGeminiFinishReasonErrorMessage_MalformedMentionsTool(t *testing.T) {
	// The most common failure shape — the message should explicitly
	// name the cause so the user can correlate it with their
	// configured tools.
	msg := geminiFinishReasonErrorMessage("MALFORMED_FUNCTION_CALL")
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
		// Single event: zero parts in candidate content + the
		// MALFORMED_FUNCTION_CALL finish reason + usage. Matches the
		// real-world shape we saw in the DB (1520 prompt tokens, 0
		// candidate tokens, finish_reason set).
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

	// First non-Done chunk must be Usage, NOT Error. Subsequent
	// chunks can include Error + Done. The exact length isn't pinned
	// (driver may add more chunks later) but the ordering invariant
	// is what protects against the retry storm.
	if len(types) < 2 {
		t.Fatalf("expected at least Usage + Done; got %v", types)
	}
	if types[0] != providers.ChunkUsage {
		t.Errorf("first chunk must be Usage (so openStreamWithRetry sees success); got %q (full sequence: %v)", types[0], types)
	}
	// Error must be present somewhere after usage.
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
