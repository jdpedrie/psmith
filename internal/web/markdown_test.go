package web

import (
	"strings"
	"testing"
)

func TestRenderMarkdown(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		in   string
		want []string // substrings that must appear
		deny []string // substrings that must NOT appear
	}{
		{
			name: "basic formatting",
			in:   "# Hi\n\nsome **bold** and `code`",
			want: []string{"<h1", "Hi</h1>", "<strong>bold</strong>", "<code>code</code>"},
		},
		{
			name: "fenced code keeps language class",
			in:   "```go\nfmt.Println(\"x\")\n```",
			want: []string{"<pre>", "language-go", "fmt.Println"},
		},
		{
			name: "links are allowed",
			in:   "[psmith](https://example.com)",
			want: []string{`href="https://example.com"`, ">psmith</a>"},
		},
		{
			name: "script tag is stripped",
			in:   "hello <script>alert(1)</script> world",
			want: []string{"hello", "world"},
			deny: []string{"<script"}, // inner text may survive as escaped content; the tag must not
		},
		{
			name: "javascript url is stripped",
			in:   "[x](javascript:alert(1))",
			deny: []string{"javascript:"},
		},
		{
			name: "raw html event handler stripped",
			in:   `<img src=x onerror="alert(1)">`,
			deny: []string{"onerror"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := renderMarkdown(tc.in)
			for _, w := range tc.want {
				if !strings.Contains(got, w) {
					t.Errorf("output missing %q\ngot: %s", w, got)
				}
			}
			for _, d := range tc.deny {
				if strings.Contains(got, d) {
					t.Errorf("output must not contain %q\ngot: %s", d, got)
				}
			}
		})
	}
}
