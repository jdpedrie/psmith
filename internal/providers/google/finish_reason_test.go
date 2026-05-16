package google

import (
	"strings"
	"testing"
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
