package speech

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"
)

// collectAudio drains the frame + error channels, returning the joined
// PCM and the terminal error.
func collectAudio(frames <-chan Frame, errs <-chan error) ([]byte, error) {
	var out []byte
	for f := range frames {
		out = append(out, f.PCM...)
	}
	return out, <-errs
}

func segmentsChan(segs ...string) <-chan string {
	in := make(chan string, len(segs))
	for _, s := range segs {
		in <- s
	}
	close(in)
	return in
}

func TestRunHTTPSegments_RetriesTransientFailure(t *testing.T) {
	t.Parallel()
	calls := 0
	fetch := func(_ context.Context, seg string) (io.ReadCloser, error) {
		calls++
		// Segment two fails twice with a transient upstream error
		// before succeeding — the flake shape xAI's edge produces.
		if seg == "two" && calls < 4 {
			return nil, &ProviderStatusError{StatusCode: 500, Excerpt: "upstream connect error"}
		}
		return io.NopCloser(strings.NewReader(seg + "-audio")), nil
	}
	frames, errs := RunHTTPSegments(context.Background(), segmentsChan("one", "two"), fetch)
	audio, err := collectAudio(frames, errs)
	if err != nil {
		t.Fatalf("retry should absorb transient failures: %v", err)
	}
	if got := string(audio); got != "one-audiotwo-audio" {
		t.Errorf("audio %q", got)
	}
	if calls != 4 {
		t.Errorf("calls = %d, want 4 (one + two failures + success)", calls)
	}
}

func TestRunHTTPSegments_NoRetryOn4xx(t *testing.T) {
	t.Parallel()
	calls := 0
	fetch := func(_ context.Context, _ string) (io.ReadCloser, error) {
		calls++
		return nil, &ProviderStatusError{StatusCode: 401, Excerpt: "bad key"}
	}
	frames, errs := RunHTTPSegments(context.Background(), segmentsChan("one"), fetch)
	_, err := collectAudio(frames, errs)
	var pse *ProviderStatusError
	if !errors.As(err, &pse) || pse.StatusCode != 401 {
		t.Fatalf("want ProviderStatusError 401, got %v", err)
	}
	if calls != 1 {
		t.Errorf("4xx must not retry, got %d calls", calls)
	}
}

func TestRunHTTPSegments_GivesUpAfterRetryBudget(t *testing.T) {
	t.Parallel()
	calls := 0
	fetch := func(_ context.Context, _ string) (io.ReadCloser, error) {
		calls++
		return nil, &ProviderStatusError{StatusCode: 503, Excerpt: "down"}
	}
	frames, errs := RunHTTPSegments(context.Background(), segmentsChan("one"), fetch)
	_, err := collectAudio(frames, errs)
	if err == nil {
		t.Fatal("want terminal error after exhausted retries")
	}
	if calls != 1+fetchRetries {
		t.Errorf("calls = %d, want %d", calls, 1+fetchRetries)
	}
}
