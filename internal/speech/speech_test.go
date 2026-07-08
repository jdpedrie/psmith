package speech

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// --- registry ---

type nopSynth struct{}

func (nopSynth) Synthesize(ctx context.Context, req Request, in <-chan string) (<-chan Frame, <-chan error) {
	frames := make(chan Frame)
	errs := make(chan error, 1)
	go func() {
		defer close(frames)
		for range in {
		}
		errs <- nil
	}()
	return frames, errs
}

func TestRegistry_BuildAndUnknown(t *testing.T) {
	Register("test-nop", func(json.RawMessage) (Synthesizer, error) { return nopSynth{}, nil })
	if _, err := Build("test-nop", nil); err != nil {
		t.Fatalf("Build registered kind: %v", err)
	}
	if _, err := Build("no-such-kind", nil); err == nil {
		t.Fatal("Build unknown kind should error")
	}
	found := false
	for _, k := range Kinds() {
		if k == "test-nop" {
			found = true
		}
	}
	if !found {
		t.Error("Kinds should list registered kind")
	}
}

// --- segmenter ---

func TestSegmentAll_SentencesAndMinimum(t *testing.T) {
	text := "Yes. This is a short opener that gets batched with the next sentence. And here is the second full sentence of the reply. Done."
	segs := SegmentAll(text)
	if len(segs) < 2 {
		t.Fatalf("want multiple segments, got %d: %q", len(segs), segs)
	}
	// The leading "Yes." is under the minimum and must be batched, not
	// emitted alone.
	if segs[0] == "Yes." {
		t.Errorf("short sentence should batch with its successor, got %q alone", segs[0])
	}
	// Reassembly must lose nothing but boundary whitespace.
	joined := strings.Join(segs, " ")
	if collapseSpaces(joined) != collapseSpaces(text) {
		t.Errorf("segments lost content:\n got: %q\nwant: %q", joined, text)
	}
}

func TestSegmenter_IncrementalDeltas(t *testing.T) {
	var s Segmenter
	var got []string
	// Feed a two-sentence reply in tiny deltas, the live-tee shape.
	full := "The first sentence arrives in small pieces over the stream. The second one follows right after it, also in pieces."
	for i := 0; i < len(full); i += 7 {
		end := min(i+7, len(full))
		got = append(got, s.Write(full[i:end])...)
	}
	if tail := s.Flush(); tail != "" {
		got = append(got, tail)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 segments, got %d: %q", len(got), got)
	}
	if !strings.HasSuffix(got[0], "stream.") {
		t.Errorf("first segment should end at the sentence boundary, got %q", got[0])
	}
}

func TestSegmenter_AbbreviationsAndDecimals(t *testing.T) {
	// Periods not followed by whitespace are not boundaries.
	text := "The value of pi is 3.14159 approximately, which suffices for most engineering work here."
	segs := SegmentAll(text)
	if len(segs) != 1 {
		t.Errorf("decimal point must not split, got %d segments: %q", len(segs), segs)
	}
}

func TestSegmenter_ParagraphBreakFlushesShort(t *testing.T) {
	segs := SegmentAll("Short one\n\nAnd then a completely separate paragraph follows here.")
	if len(segs) != 2 {
		t.Fatalf("paragraph break should flush regardless of length, got %q", segs)
	}
	if segs[0] != "Short one" {
		t.Errorf("first segment: %q", segs[0])
	}
}

func TestSegmenter_RunawayTextForcesSplit(t *testing.T) {
	word := "waffle "
	text := strings.Repeat(word, 300) // ~2100 chars, zero punctuation
	segs := SegmentAll(text)
	if len(segs) < 2 {
		t.Fatalf("unpunctuated wall should force-split, got %d segments", len(segs))
	}
	for i, seg := range segs {
		if len(seg) > maxSegmentChars {
			t.Errorf("segment %d exceeds cap: %d chars", i, len(seg))
		}
	}
}

// --- normalizer ---

func TestNormalizeMarkdown_CodeAnnounced(t *testing.T) {
	src := "Here is the function:\n\n```go\nfunc main() {}\n```\n\nCall it from your entry point."
	got := NormalizeMarkdown(src)
	if !strings.Contains(got, "Code omitted.") {
		t.Errorf("code fence should be announced, got %q", got)
	}
	if strings.Contains(got, "func main") {
		t.Errorf("code body must not be spoken, got %q", got)
	}
}

func TestNormalizeMarkdown_LinksEmphasisHeadings(t *testing.T) {
	src := "## The plan\n\nRead the *quick* guide at [the docs](https://example.com/docs) first."
	got := NormalizeMarkdown(src)
	if strings.Contains(got, "example.com") || strings.Contains(got, "##") || strings.Contains(got, "*") {
		t.Errorf("markup leaked into speech text: %q", got)
	}
	if !strings.Contains(got, "The plan.") {
		t.Errorf("heading should be spoken with terminal punctuation, got %q", got)
	}
	if !strings.Contains(got, "the docs") {
		t.Errorf("link label should be spoken, got %q", got)
	}
}

func TestNormalizeMarkdown_ListsTerminate(t *testing.T) {
	src := "- first item\n- second item\n- third item"
	got := NormalizeMarkdown(src)
	for _, item := range []string{"first item.", "second item.", "third item."} {
		if !strings.Contains(got, item) {
			t.Errorf("list item should be terminated for the segmenter, got %q", got)
		}
	}
	if strings.Contains(got, "- ") {
		t.Errorf("bullet markers leaked: %q", got)
	}
}

func TestNormalizeMarkdown_TableAnnouncedAndInlineCodeSpoken(t *testing.T) {
	src := "| a | b |\n|---|---|\n| 1 | 2 |\n\nSet `maxRetries` to three."
	got := NormalizeMarkdown(src)
	if !strings.Contains(got, "Table omitted.") {
		t.Errorf("table should be announced, got %q", got)
	}
	if !strings.Contains(got, "maxRetries") {
		t.Errorf("inline code should be spoken literally, got %q", got)
	}
}

func TestNormalizeMarkdown_PlainTextPassesThrough(t *testing.T) {
	src := "Just a plain sentence with nothing special about it."
	if got := NormalizeMarkdown(src); got != src {
		t.Errorf("plain text should pass through, got %q", got)
	}
}
