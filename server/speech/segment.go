package speech

import "strings"

// minSegmentChars is the floor below which a sentence boundary doesn't
// flush: batching "Yes." with the sentence after it costs nothing
// audibly and halves request count on terse replies.
const minSegmentChars = 40

// maxSegmentChars force-flushes a segment that never hit a sentence
// boundary (a wall of unpunctuated text) so time-to-first-audio stays
// bounded and no provider request exceeds sane limits.
const maxSegmentChars = 800

// Segmenter accumulates text (deltas or whole documents — the caller
// decides the write granularity) and emits speech-sized segments at
// sentence and paragraph boundaries. Zero value is ready to use. Not
// safe for concurrent use.
//
// Read-aloud writes the whole normalized message once and calls
// Flush; the phase-2 live tee writes model deltas as they land and
// gets segments back as sentences complete.
type Segmenter struct {
	buf strings.Builder
}

// Write appends text and returns any segments completed by it.
func (s *Segmenter) Write(text string) []string {
	s.buf.WriteString(text)
	var out []string
	for {
		seg, rest, ok := s.take()
		if !ok {
			return out
		}
		out = append(out, seg)
		s.buf.Reset()
		s.buf.WriteString(rest)
	}
}

// Flush returns the remaining buffered text as a final segment ("" if
// nothing is buffered) and resets the segmenter.
func (s *Segmenter) Flush() string {
	rest := strings.TrimSpace(s.buf.String())
	s.buf.Reset()
	return rest
}

// take finds the earliest usable boundary in the buffer and splits
// there. A boundary is usable when the text before it meets
// minSegmentChars; a paragraph break is always usable; maxSegmentChars
// forces a split at the last whitespace before the cap.
func (s *Segmenter) take() (segment, rest string, ok bool) {
	text := s.buf.String()

	// Paragraph break: flush whatever precedes it, however short —
	// a paragraph boundary is a natural pause regardless of length.
	if i := strings.Index(text, "\n\n"); i >= 0 {
		seg := strings.TrimSpace(text[:i])
		rest := strings.TrimLeft(text[i:], "\n")
		if seg == "" {
			// Leading blank lines: drop them and go around again.
			s.buf.Reset()
			s.buf.WriteString(rest)
			return s.take()
		}
		return seg, rest, true
	}

	// Sentence boundaries past the minimum length.
	for i := 0; i < len(text); i++ {
		if !isSentenceTerminator(text[i]) {
			continue
		}
		// Consume any run of terminators/closers ("?!", ".\"", "…)").
		end := i + 1
		for end < len(text) && (isSentenceTerminator(text[end]) || text[end] == '"' || text[end] == '\'' || text[end] == ')') {
			end++
		}
		// Only a real boundary if followed by whitespace (or nothing
		// yet — in which case we can't know, so wait for more text).
		if end >= len(text) {
			return "", "", false
		}
		if text[end] != ' ' && text[end] != '\n' && text[end] != '\t' {
			continue // "3.14", "e.g.x" — not a boundary
		}
		if end < minSegmentChars {
			continue // batch short sentences with what follows
		}
		return strings.TrimSpace(text[:end]), strings.TrimLeft(text[end:], " \t"), true
	}

	// Runaway unpunctuated text: force a split at the last space
	// before the cap.
	if len(text) >= maxSegmentChars {
		cut := strings.LastIndexByte(text[:maxSegmentChars], ' ')
		if cut < minSegmentChars {
			cut = maxSegmentChars
		}
		return strings.TrimSpace(text[:cut]), strings.TrimLeft(text[cut:], " \t"), true
	}

	return "", "", false
}

func isSentenceTerminator(b byte) bool {
	return b == '.' || b == '!' || b == '?'
}

// SegmentAll runs the whole text through a Segmenter — the read-aloud
// path, where the full message is in hand.
func SegmentAll(text string) []string {
	var s Segmenter
	out := s.Write(text)
	if tail := s.Flush(); tail != "" {
		out = append(out, tail)
	}
	return out
}
