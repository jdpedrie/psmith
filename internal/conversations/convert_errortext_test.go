package conversations

import "testing"

// TestErrorTextFromPayload covers every provider error envelope shape we
// expect to encounter in production. The iOS / Mac UIs render
// `errorText` verbatim — surfacing raw JSON would read as broken — so
// the extraction logic owns the "make it human" contract.
func TestErrorTextFromPayload(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name    string
		payload string
		want    string
	}{
		{"empty", "", ""},
		{
			name:    "internal wrapper",
			payload: `{"message":"rate limit hit","raw":"{}"}`,
			want:    "rate limit hit",
		},
		{
			name:    "OpenAI/Anthropic envelope",
			payload: `{"error":{"message":"invalid_request_error: foo","type":"invalid_request_error","code":"x"}}`,
			want:    "invalid_request_error: foo",
		},
		{
			name:    "Google envelope",
			payload: `{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}`,
			want:    "API key not valid",
		},
		{
			name:    "error as bare string",
			payload: `{"error":"connection refused"}`,
			want:    "connection refused",
		},
		{
			name:    "GraphQL-style errors array",
			payload: `{"errors":[{"message":"bad query"},{"message":"second"}]}`,
			want:    "bad query",
		},
		{
			name:    "FastAPI detail string",
			payload: `{"detail":"Not authenticated"}`,
			want:    "Not authenticated",
		},
		{
			name:    "FastAPI detail validation array",
			payload: `{"detail":[{"msg":"field required","loc":["body","x"]}]}`,
			want:    "field required",
		},
		{
			name:    "OAuth error_description",
			payload: `{"error_description":"invalid_grant: bad refresh token"}`,
			want:    "invalid_grant: bad refresh token",
		},
		{
			name:    "bare JSON string",
			payload: `"upstream blew up"`,
			want:    "upstream blew up",
		},
		{
			name:    "plaintext",
			payload: `Cloudflare 524: A timeout occurred.`,
			want:    "Cloudflare 524: A timeout occurred.",
		},
		{
			// JSON we can't extract a message from — must NOT dump
			// raw braces; falls back to a generic placeholder.
			name:    "unrecognised JSON object",
			payload: `{"status":500,"code":"internal_error","trace":"x"}`,
			want:    "Upstream returned an error.",
		},
		{
			name:    "unrecognised JSON array",
			payload: `[1,2,3]`,
			want:    "Upstream returned an error.",
		},
		{
			// Multi-line plaintext gets collapsed to a single banner-friendly line.
			name:    "multiline plaintext collapses",
			payload: "line one\n  line two\tline three",
			want:    "line one line two line three",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := errorTextFromPayload([]byte(tc.payload))
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}
