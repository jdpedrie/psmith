package speech

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// frameSize is how much PCM each Frame carries: 8KB ≈ 170ms of audio,
// small enough for prompt playback start, large enough to keep channel
// overhead irrelevant.
const frameSize = 8 << 10

// Per-segment fetch retry budget. Sentence-sized requests are cheap to
// re-issue and providers fail transiently (xAI's edge intermittently
// returns 500 "upstream connect error"); without retries one blip
// truncates the whole narration at a sentence boundary.
const (
	fetchRetries       = 2
	fetchRetryBaseWait = 400 * time.Millisecond
)

// ProviderStatusError is a non-2xx provider response. Typed so the
// retry logic can distinguish transient upstream failures (5xx, 429)
// from request errors (4xx) that would fail identically on retry.
type ProviderStatusError struct {
	StatusCode int
	Excerpt    string
}

func (e *ProviderStatusError) Error() string {
	return fmt.Sprintf("speech: provider returned %d: %s", e.StatusCode, e.Excerpt)
}

// RunHTTPSegments is the shared engine for shape-1 (HTTP-per-segment)
// drivers: for each text segment arriving on in, fetch opens one
// provider request and returns its audio body, which is streamed out
// as frames. Segments are processed strictly in order — no pipelining
// in v1, so audio order is trivially correct. The error channel
// carries exactly one terminal value: nil after in closes and all
// audio is flushed, or the first failure.
//
// Each segment's fetch is retried on transient failures (network
// errors, 5xx, 429) before the stream gives up. Retries only apply to
// the fetch itself — once a segment's audio has started flowing, a
// mid-body failure terminates the stream rather than re-fetching,
// because replaying a segment would duplicate audio the consumer
// already heard.
func RunHTTPSegments(ctx context.Context, in <-chan string, fetch func(ctx context.Context, segment string) (io.ReadCloser, error)) (<-chan Frame, <-chan error) {
	frames := make(chan Frame, 4)
	errs := make(chan error, 1)
	go func() {
		defer close(frames)
		for {
			select {
			case <-ctx.Done():
				errs <- ctx.Err()
				return
			case seg, ok := <-in:
				if !ok {
					errs <- nil
					return
				}
				if strings.TrimSpace(seg) == "" {
					continue
				}
				if err := streamOne(ctx, seg, fetch, frames); err != nil {
					errs <- err
					return
				}
			}
		}
	}()
	return frames, errs
}

func streamOne(ctx context.Context, seg string, fetch func(context.Context, string) (io.ReadCloser, error), frames chan<- Frame) error {
	body, err := fetchWithRetry(ctx, seg, fetch)
	if err != nil {
		return err
	}
	defer body.Close()
	for {
		buf := make([]byte, frameSize)
		n, err := io.ReadFull(body, buf)
		if n > 0 {
			select {
			case frames <- Frame{PCM: buf[:n]}:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("speech: read audio: %w", err)
		}
	}
}

func fetchWithRetry(ctx context.Context, seg string, fetch func(context.Context, string) (io.ReadCloser, error)) (io.ReadCloser, error) {
	for attempt := 0; ; attempt++ {
		body, err := fetch(ctx, seg)
		if err == nil {
			return body, nil
		}
		if attempt >= fetchRetries || !retryableFetchError(err) || ctx.Err() != nil {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(fetchRetryBaseWait << attempt):
		}
	}
}

// retryableFetchError: provider 5xx and 429 are transient; other
// statuses (auth, validation) fail identically on retry. Anything that
// isn't a status error is a network-level failure, assumed transient.
func retryableFetchError(err error) bool {
	var pse *ProviderStatusError
	if errors.As(err, &pse) {
		return pse.StatusCode >= 500 || pse.StatusCode == http.StatusTooManyRequests
	}
	return true
}

// CheckHTTPResponse converts a non-2xx provider response into a
// *ProviderStatusError carrying a bounded excerpt of the body
// (provider errors are JSON envelopes worth surfacing) and closes it.
// On success the caller owns the body.
func CheckHTTPResponse(resp *http.Response) (io.ReadCloser, error) {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp.Body, nil
	}
	excerpt, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	_ = resp.Body.Close()
	return nil, &ProviderStatusError{StatusCode: resp.StatusCode, Excerpt: strings.TrimSpace(string(excerpt))}
}
