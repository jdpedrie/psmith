package speech

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// frameSize is how much PCM each Frame carries: 8KB ≈ 170ms of audio,
// small enough for prompt playback start, large enough to keep channel
// overhead irrelevant.
const frameSize = 8 << 10

// RunHTTPSegments is the shared engine for shape-1 (HTTP-per-segment)
// drivers: for each text segment arriving on in, fetch opens one
// provider request and returns its audio body, which is streamed out
// as frames. Segments are processed strictly in order — no pipelining
// in v1, so audio order is trivially correct. The error channel
// carries exactly one terminal value: nil after in closes and all
// audio is flushed, or the first failure.
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
	body, err := fetch(ctx, seg)
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

// CheckHTTPResponse converts a non-2xx provider response into an error
// carrying a bounded excerpt of the body (provider errors are JSON
// envelopes worth surfacing) and closes it. On success the caller owns
// the body.
func CheckHTTPResponse(resp *http.Response) (io.ReadCloser, error) {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp.Body, nil
	}
	excerpt, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	_ = resp.Body.Close()
	return nil, fmt.Errorf("speech: provider returned %d: %s", resp.StatusCode, strings.TrimSpace(string(excerpt)))
}
