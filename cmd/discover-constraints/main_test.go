package main

import "testing"

func TestRedactURLSecrets(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{
			name: "key in URL within error message",
			in:   `google: send: Post "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:streamGenerateContent?alt=sse&key=REDACTED-LEAKED-GEMINI-KEY": context deadline exceeded`,
			want: `google: send: Post "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:streamGenerateContent?alt=sse&key=REDACTED": context deadline exceeded`,
		},
		{
			name: "key as first param",
			in:   `https://api.example.com/x?key=secret123&other=val`,
			want: `https://api.example.com/x?key=REDACTED&other=val`,
		},
		{
			name: "api_key spelling",
			in:   `failed: ?api_key=AKIA123 invalid`,
			want: `failed: ?api_key=REDACTED invalid`,
		},
		{
			name: "access_token",
			in:   `bad: access_token=foo&bar=baz`,
			want: `bad: access_token=REDACTED&bar=baz`,
		},
		{
			name: "token uppercase",
			in:   `?TOKEN=ABC123`,
			want: `?TOKEN=REDACTED`,
		},
		{
			name: "no leak — preserved",
			in:   `context deadline exceeded: no URL here`,
			want: `context deadline exceeded: no URL here`,
		},
		{
			name: "empty",
			in:   ``,
			want: ``,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := redactURLSecrets(tc.in); got != tc.want {
				t.Errorf("redactURLSecrets():\n got:  %q\n want: %q", got, tc.want)
			}
		})
	}
}
