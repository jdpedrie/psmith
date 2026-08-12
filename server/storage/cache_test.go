package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
)

// countingStore records how often each blob was actually read, which is the
// only thing worth asserting here: the cache changes no behaviour, only how
// many times the backend is touched.
type countingStore struct {
	mu    sync.Mutex
	data  map[string][]byte
	reads map[string]int
}

func newCountingStore() *countingStore {
	return &countingStore{data: map[string][]byte{}, reads: map[string]int{}}
}

func (c *countingStore) Put(_ context.Context, u uuid.UUID, sha, _ string, r io.Reader) error {
	b, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.data[cacheKey(u, sha)] = b
	return nil
}

func (c *countingStore) Get(_ context.Context, u uuid.UUID, sha string) (io.ReadCloser, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	k := cacheKey(u, sha)
	b, ok := c.data[k]
	if !ok {
		return nil, ErrNotFound
	}
	c.reads[k]++
	return io.NopCloser(strings.NewReader(string(b))), nil
}

func (c *countingStore) Delete(_ context.Context, u uuid.UUID, sha string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.data, cacheKey(u, sha))
	return nil
}

func (c *countingStore) readCount(u uuid.UUID, sha string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reads[cacheKey(u, sha)]
}

func mustRead(t *testing.T, s Storage, u uuid.UUID, sha string) string {
	t.Helper()
	rc, err := s.Get(context.Background(), u, sha)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	defer rc.Close()
	b, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	return string(b)
}

// The whole point: a conversation's attachments are read once, not once per
// send.
func TestReadCache_ReadsTheBackendOnce(t *testing.T) {
	t.Parallel()
	inner := newCountingStore()
	u := uuid.New()
	_ = inner.Put(context.Background(), u, "sha-a", "image/png", strings.NewReader("PAYLOAD"))

	c := NewReadCache(inner, 1024)
	for i := 0; i < 20; i++ {
		if got := mustRead(t, c, u, "sha-a"); got != "PAYLOAD" {
			t.Fatalf("read %d returned %q", i, got)
		}
	}
	if n := inner.readCount(u, "sha-a"); n != 1 {
		t.Errorf("backend read %d times, want 1", n)
	}
}

// Each reader must be independent: history builds inline the same blob into
// several requests, and a shared reader would come back empty the second time.
func TestReadCache_ReturnsAFreshReaderEachTime(t *testing.T) {
	t.Parallel()
	inner := newCountingStore()
	u := uuid.New()
	_ = inner.Put(context.Background(), u, "sha-a", "image/png", strings.NewReader("PAYLOAD"))
	c := NewReadCache(inner, 1024)

	first := mustRead(t, c, u, "sha-a")
	second := mustRead(t, c, u, "sha-a")
	if first != "PAYLOAD" || second != "PAYLOAD" {
		t.Errorf("readers are not independent: %q then %q", first, second)
	}
}

// Bounded by bytes, LRU. The recently used entry survives; the idle one goes.
func TestReadCache_EvictsLeastRecentlyUsed(t *testing.T) {
	t.Parallel()
	inner := newCountingStore()
	u := uuid.New()
	for _, k := range []string{"a", "b", "c"} {
		_ = inner.Put(context.Background(), u, k, "text/plain", strings.NewReader(strings.Repeat("x", 100)))
	}
	c := NewReadCache(inner, 250) // room for two

	mustRead(t, c, u, "a")
	mustRead(t, c, u, "b")
	mustRead(t, c, u, "a") // a is now the most recently used
	mustRead(t, c, u, "c") // evicts b

	mustRead(t, c, u, "a")
	if n := inner.readCount(u, "a"); n != 1 {
		t.Errorf("a should have survived eviction, backend reads = %d", n)
	}
	mustRead(t, c, u, "b")
	if n := inner.readCount(u, "b"); n != 2 {
		t.Errorf("b should have been evicted and re-read, backend reads = %d", n)
	}
}

// One oversized file must not empty the cache for the many small ones that
// benefit most.
func TestReadCache_SkipsBlobsLargerThanTheBudget(t *testing.T) {
	t.Parallel()
	inner := newCountingStore()
	u := uuid.New()
	_ = inner.Put(context.Background(), u, "small", "text/plain", strings.NewReader("s"))
	_ = inner.Put(context.Background(), u, "huge", "text/plain", strings.NewReader(strings.Repeat("x", 5000)))
	c := NewReadCache(inner, 100)

	mustRead(t, c, u, "small")
	mustRead(t, c, u, "huge")
	mustRead(t, c, u, "small")
	if n := inner.readCount(u, "small"); n != 1 {
		t.Errorf("an oversized blob evicted the small one: small read %d times", n)
	}
	mustRead(t, c, u, "huge")
	if n := inner.readCount(u, "huge"); n != 2 {
		t.Errorf("an oversized blob should not be cached, read %d times", n)
	}
}

// Entries are scoped per user, so the cache cannot reveal that another account
// holds a given file.
func TestReadCache_DoesNotLeakAcrossUsers(t *testing.T) {
	t.Parallel()
	inner := newCountingStore()
	alice, bob := uuid.New(), uuid.New()
	_ = inner.Put(context.Background(), alice, "same-sha", "text/plain", strings.NewReader("alice"))
	c := NewReadCache(inner, 1024)

	mustRead(t, c, alice, "same-sha")
	// Bob has no such blob; a hash-only cache would hand him Alice's bytes.
	if _, err := c.Get(context.Background(), bob, "same-sha"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound for another user's blob, got %v", err)
	}
}

// Deleting must drop the entry, or a re-uploaded file would serve stale bytes
// under a key that legitimately came back.
func TestReadCache_DeleteEvicts(t *testing.T) {
	t.Parallel()
	inner := newCountingStore()
	u := uuid.New()
	_ = inner.Put(context.Background(), u, "a", "text/plain", strings.NewReader("v1"))
	c := NewReadCache(inner, 1024)

	mustRead(t, c, u, "a")
	if err := c.Delete(context.Background(), u, "a"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := c.Get(context.Background(), u, "a"); !errors.Is(err, ErrNotFound) {
		t.Errorf("deleted blob still served from cache: %v", err)
	}
}

// Disabling is a config change, not a code path.
func TestNewReadCache_ZeroBudgetReturnsTheInnerStore(t *testing.T) {
	t.Parallel()
	inner := newCountingStore()
	if got := NewReadCache(inner, 0); got != Storage(inner) {
		t.Error("a zero budget should return the inner store unwrapped")
	}
}

func TestReadCache_ConcurrentReadsAreSafe(t *testing.T) {
	t.Parallel()
	inner := newCountingStore()
	u := uuid.New()
	for i := 0; i < 8; i++ {
		_ = inner.Put(context.Background(), u, fmt.Sprintf("k%d", i), "text/plain",
			strings.NewReader(strings.Repeat("y", 50)))
	}
	c := NewReadCache(inner, 200) // forces eviction churn under load

	var wg sync.WaitGroup
	for g := 0; g < 16; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 40; i++ {
				rc, err := c.Get(context.Background(), u, fmt.Sprintf("k%d", (g+i)%8))
				if err != nil {
					t.Errorf("Get: %v", err)
					return
				}
				_, _ = io.ReadAll(rc)
				_ = rc.Close()
			}
		}(g)
	}
	wg.Wait()
}
