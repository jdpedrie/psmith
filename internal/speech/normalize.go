package speech

import (
	"strings"
	"sync"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/text"
)

// NormalizeMarkdown reduces assistant markdown to speakable prose.
// Decisions per docs/design/speech.md: code fences are announced as
// "Code omitted." rather than skipped (the narration stays honest
// about what it isn't reading), tables likewise, links speak their
// text, images announce themselves, emphasis and heading markers
// strip. Blocks are joined with blank lines so the segmenter treats
// each as a paragraph boundary, and every block is closed with
// sentence punctuation so list items don't run together.
//
// Bump NormalizerVersion when changing anything here audibly — client
// replay caches key on it.
func NormalizeMarkdown(src string) string {
	doc := speechParser().Parser().Parse(text.NewReader([]byte(src)))
	var blocks []string
	for n := doc.FirstChild(); n != nil; n = n.NextSibling() {
		emitBlock(n, []byte(src), &blocks)
	}
	return strings.Join(blocks, "\n\n")
}

var (
	parserOnce sync.Once
	parserInst goldmark.Markdown
)

// speechParser is a shared goldmark instance with GFM so tables and
// strikethrough parse the same way the web renderer sees them.
func speechParser() goldmark.Markdown {
	parserOnce.Do(func() {
		parserInst = goldmark.New(goldmark.WithExtensions(extension.GFM))
	})
	return parserInst
}

// emitBlock appends the speakable form of one block-level node.
func emitBlock(n ast.Node, src []byte, out *[]string) {
	switch v := n.(type) {
	case *ast.FencedCodeBlock, *ast.CodeBlock:
		*out = append(*out, "Code omitted.")
	case *east.Table:
		*out = append(*out, "Table omitted.")
	case *ast.ThematicBreak:
		// A horizontal rule is a visual pause; the paragraph join
		// already provides one.
	case *ast.HTMLBlock:
		// Raw HTML has no speakable form.
	case *ast.Heading:
		if t := inlineText(v, src); t != "" {
			*out = append(*out, ensureTerminated(t))
		}
	case *ast.Paragraph, *ast.TextBlock:
		if t := inlineText(v, src); t != "" {
			*out = append(*out, ensureTerminated(t))
		}
	case *ast.Blockquote:
		for c := v.FirstChild(); c != nil; c = c.NextSibling() {
			emitBlock(c, src, out)
		}
	case *ast.List:
		for item := v.FirstChild(); item != nil; item = item.NextSibling() {
			for c := item.FirstChild(); c != nil; c = c.NextSibling() {
				emitBlock(c, src, out)
			}
		}
	default:
		// Unknown block kind: fall back to its inline text rather
		// than dropping content silently.
		if t := inlineText(n, src); t != "" {
			*out = append(*out, ensureTerminated(t))
		}
	}
}

// inlineText flattens an inline tree to speakable text: links speak
// their label, autolinks announce "link", images announce "Image",
// code spans speak their literal, emphasis passes through.
func inlineText(n ast.Node, src []byte) string {
	var b strings.Builder
	var walk func(ast.Node)
	walk = func(n ast.Node) {
		for c := n.FirstChild(); c != nil; c = c.NextSibling() {
			switch v := c.(type) {
			case *ast.Text:
				b.Write(v.Segment.Value(src))
				if v.SoftLineBreak() || v.HardLineBreak() {
					b.WriteByte(' ')
				}
			case *ast.String:
				b.Write(v.Value)
			case *ast.CodeSpan:
				// CodeSpan's literal is the concatenation of its
				// child text segments (Node.Text is deprecated).
				for t := v.FirstChild(); t != nil; t = t.NextSibling() {
					if tn, ok := t.(*ast.Text); ok {
						b.Write(tn.Segment.Value(src))
					}
				}
			case *ast.Link:
				walk(v) // the label
			case *ast.AutoLink:
				b.WriteString("link")
			case *ast.Image:
				b.WriteString("Image")
			case *ast.RawHTML:
				// unspeakable; drop
			default:
				walk(c)
			}
		}
	}
	walk(n)
	return strings.TrimSpace(collapseSpaces(b.String()))
}

// ensureTerminated closes a block with sentence punctuation so the
// segmenter hears a boundary — otherwise consecutive list items or a
// heading and its first paragraph would run together as one breathless
// sentence.
func ensureTerminated(s string) string {
	if s == "" {
		return s
	}
	switch s[len(s)-1] {
	case '.', '!', '?', ':', ';':
		return s
	}
	return s + "."
}

func collapseSpaces(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
