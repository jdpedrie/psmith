package web

import "testing"

// The footer named every model by splitting its id on hyphens as if it were
// a Claude id: "demo-model-1" read "Demo model.1" and "gpt-4o-mini"
// "Gpt 4o.mini". It names the model by its display name now.
func TestFooterModel(t *testing.T) {
	for display, want := range map[string]string{
		"Claude Opus 4.7": "Opus 4.7",
		"GPT-4o mini":     "GPT-4o mini",
		"Gemini 2.5 Pro":  "Gemini 2.5 Pro",
		"demo-model-1":    "demo-model-1",
	} {
		if got := footerModel(display); got != want {
			t.Errorf("footerModel(%q) = %q, want %q", display, got, want)
		}
	}
}
