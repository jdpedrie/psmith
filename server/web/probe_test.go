package web

import (
	"bytes"
	"context"
	"encoding/base64"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/a-h/templ"
)

// The board probe renders each screen's templates with the content of its
// board on the "Psmith web design" canvas and writes standalone HTML (styles
// and fonts inlined) for comparison with board renders. It runs only when
// PSMITH_WEB_PROBE_OUT names a directory:
//
//	PSMITH_WEB_PROBE_OUT=/tmp/probe go test ./server/web -run TestProbe
//
// Each output is written once per appearance and theme the test asks for,
// named <Board>-<mode>-<theme>.html.

type probeCase struct {
	name string
	comp func() templ.Component
}

func probeOut(t *testing.T) string {
	dir := os.Getenv("PSMITH_WEB_PROBE_OUT")
	if dir == "" {
		t.Skip("PSMITH_WEB_PROBE_OUT not set")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

var fontURL = regexp.MustCompile(`url\(fonts/([a-z-]+\.woff2)\)`)

// inlineStyles is tokens.css + app.css (+ area files) with the fonts as data
// URIs, so a probe page renders with no server.
func inlineStyles(t *testing.T) string {
	var b strings.Builder
	entries, _ := assetsFS.ReadDir("assets")
	order := []string{"tokens.css", "app.css"}
	for _, a := range areaAssets {
		order = append(order, a+".css")
	}
	_ = entries
	for _, n := range order {
		data, err := assetsFS.ReadFile("assets/" + n)
		if err != nil {
			t.Fatal(err)
		}
		css := fontURL.ReplaceAllStringFunc(string(data), func(m string) string {
			f := fontURL.FindStringSubmatch(m)[1]
			raw, err := assetsFS.ReadFile("assets/fonts/" + f)
			if err != nil {
				t.Fatal(err)
			}
			return "url(data:font/woff2;base64," + base64.StdEncoding.EncodeToString(raw) + ")"
		})
		b.WriteString(css)
		b.WriteByte('\n')
	}
	return b.String()
}

var linkTags = regexp.MustCompile(`<link rel="stylesheet" href="/web-assets/[^"]+"/?>`)
var scriptTags = regexp.MustCompile(`<script[^>]*></script>`)

// writeProbe renders c under the given prefs and writes it to dir.
func writeProbe(t *testing.T, dir, name string, styles string, p uiPrefs, c templ.Component) {
	var buf bytes.Buffer
	ctx := withPrefs(context.Background(), p)
	if err := c.Render(ctx, &buf); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	html := buf.String()
	html = linkTags.ReplaceAllString(html, "")
	html = scriptTags.ReplaceAllString(html, "")
	html = strings.Replace(html, "</head>", "<style>"+styles+"</style></head>", 1)
	path := filepath.Join(dir, name+"-"+p.Mode+"-"+p.Theme+".html")
	if err := os.WriteFile(path, []byte(html), 0o644); err != nil {
		t.Fatal(err)
	}
}

// probeAll writes every case in both appearances under slate, plus every
// theme in dark and light for the cases named in themed.
func probeAll(t *testing.T, cases []probeCase, themed map[string]bool) {
	dir := probeOut(t)
	styles := inlineStyles(t)
	for _, c := range cases {
		for _, mode := range []string{"dark", "light"} {
			writeProbe(t, dir, c.name, styles, uiPrefs{Theme: "slate", Mode: mode}, c.comp())
			if themed[c.name] {
				for _, th := range themeIDs {
					if th != "slate" {
						writeProbe(t, dir, c.name, styles, uiPrefs{Theme: th, Mode: mode}, c.comp())
					}
				}
			}
		}
	}
}

func TestProbeShell(t *testing.T) {
	probeAll(t, []probeCase{
		{"Main", func() templ.Component { return conversationScreen(boardList(), boardConv()) }},
		{"Settings", func() templ.Component { return providerScreen(boardSettingsNav("providers"), boardProvider()) }},
	}, map[string]bool{"Main": true})
}

var _ = httptest.NewRecorder
