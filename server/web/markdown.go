package web

import (
	"bytes"
	"sync"

	"github.com/microcosm-cc/bluemonday"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/renderer/html"
)

// Markdown rendering for message content. The output is model-generated, so it
// is rendered then sanitized before it reaches the page. Both the goldmark
// instance and the sanitizer policy are stateless and safe to share.
var (
	mdOnce   sync.Once
	mdEngine goldmark.Markdown
	mdPolicy *bluemonday.Policy
)

func mdInit() {
	mdEngine = goldmark.New(
		goldmark.WithExtensions(extension.GFM),
		goldmark.WithRendererOptions(html.WithHardWraps()),
	)
	p := bluemonday.UGCPolicy()
	// Allow fenced-code language hints (class="language-go") that goldmark emits.
	p.AllowAttrs("class").Matching(bluemonday.SpaceSeparatedTokens).OnElements("code", "span", "pre")
	mdPolicy = p
}

// renderMarkdown turns message text into sanitized HTML. On a render error it
// falls back to the sanitized raw text so content is never dropped.
func renderMarkdown(src string) string {
	mdOnce.Do(mdInit)
	var buf bytes.Buffer
	if err := mdEngine.Convert([]byte(src), &buf); err != nil {
		return mdPolicy.Sanitize(src)
	}
	return string(mdPolicy.SanitizeBytes(buf.Bytes()))
}
