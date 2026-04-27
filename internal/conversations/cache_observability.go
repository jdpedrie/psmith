package conversations

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/clark/internal/providers"
	"github.com/jdpedrie/clark/internal/store"
)

// hashWireMessages produces the per-position content-hash list used for
// cache observability. One hash per message, in send order. The hash domain
// is (role, content) — that's what determines whether the wire bytes change
// for prompt-cache purposes.
//
// Thinking and tool blocks are deliberately NOT in the hash domain yet. When
// we round-trip those on the wire (currently only thinking, partially), the
// hashing should extend to them too. Tracked alongside tool-use end-to-end
// in the architecture's Open Threads.
func hashWireMessages(msgs []providers.WireMessage) []string {
	out := make([]string, len(msgs))
	for i, m := range msgs {
		h := sha256.New()
		// Length-prefix the role to disambiguate "user"+"hi" from "use"+"rhi".
		var lenBuf [4]byte
		binaryPutUint32(lenBuf[:], uint32(len(m.Role)))
		h.Write(lenBuf[:])
		h.Write([]byte(m.Role))
		h.Write([]byte(m.Content))
		out[i] = hex.EncodeToString(h.Sum(nil))
	}
	return out
}

// binaryPutUint32 writes a 4-byte little-endian uint32, avoiding a dependency
// on encoding/binary for one length prefix.
func binaryPutUint32(dst []byte, v uint32) {
	dst[0] = byte(v)
	dst[1] = byte(v >> 8)
	dst[2] = byte(v >> 16)
	dst[3] = byte(v >> 24)
}

// stablePrefixLength returns the count of leading positions whose hashes
// match between cur and prev. When either is empty, returns 0.
func stablePrefixLength(cur, prev []string) int {
	n := len(cur)
	if len(prev) < n {
		n = len(prev)
	}
	for i := 0; i < n; i++ {
		if cur[i] != prev[i] {
			return i
		}
	}
	return n
}

// cacheObservation is the per-turn diagnostic recorded against a stream_run.
// PreviousLength is the length of the previous turn's prefix; with
// StablePrefixLength it determines TrailingDepth = PreviousLength - Stable.
//
// All fields except CurHashes are zero/nil when there is no previous turn
// for this context (first send).
type cacheObservation struct {
	CurHashes          []string
	PreviousLength     int
	StablePrefixLength int
	TrailingDepth      int
	HasPrevious        bool
}

// observePrefixCache hashes the current prefix and (if a previous turn for
// the same context recorded hashes) computes stable-prefix-length and
// trailing-edge depth. Errors from the lookup are non-fatal — the caller
// should still record the current hashes for the next turn's comparison.
func observePrefixCache(
	ctx context.Context,
	q *store.Queries,
	contextID uuid.UUID,
	prefix []providers.WireMessage,
) (cacheObservation, error) {
	obs := cacheObservation{
		CurHashes: hashWireMessages(prefix),
	}
	prev, err := q.GetLatestStreamRunWithPrefixForContext(ctx, contextID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return obs, nil // first turn for this context
		}
		return obs, fmt.Errorf("lookup previous prefix: %w", err)
	}
	if len(prev.PrefixHashes) == 0 {
		// Defensive: row exists but column is empty/null; treat as no-prev.
		return obs, nil
	}
	var prevHashes []string
	if err := json.Unmarshal(prev.PrefixHashes, &prevHashes); err != nil {
		return obs, fmt.Errorf("decode previous prefix_hashes: %w", err)
	}
	obs.HasPrevious = true
	obs.PreviousLength = len(prevHashes)
	obs.StablePrefixLength = stablePrefixLength(obs.CurHashes, prevHashes)
	obs.TrailingDepth = obs.PreviousLength - obs.StablePrefixLength
	return obs, nil
}

// recordPrefixObservation persists the observation onto the stream_run row
// via UPDATE. Should be called after supervisor.Start has created the row.
// On the first turn for a context (HasPrevious=false), stable/trailing are
// stored as NULL so consumers can distinguish "no comparison possible" from
// "comparison ran and matched everything."
func recordPrefixObservation(
	ctx context.Context,
	q *store.Queries,
	runID uuid.UUID,
	obs cacheObservation,
) error {
	hashesJSON, err := json.Marshal(obs.CurHashes)
	if err != nil {
		return fmt.Errorf("encode prefix hashes: %w", err)
	}
	prefixLen := int32(len(obs.CurHashes))
	var stable, trailing *int32
	if obs.HasPrevious {
		s := int32(obs.StablePrefixLength)
		t := int32(obs.TrailingDepth)
		stable = &s
		trailing = &t
	}
	return q.SetStreamRunPrefixHashes(ctx, store.SetStreamRunPrefixHashesParams{
		ID:                      runID,
		PrefixHashes:            hashesJSON,
		PrefixLength:            &prefixLen,
		CacheStablePrefixLength: stable,
		CacheTrailingDepth:      trailing,
	})
}
