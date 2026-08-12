package storage

import (
	"bytes"
	"container/list"
	"context"
	"io"
	"sync"

	"github.com/google/uuid"
)

// ReadCache is a bounded in-process cache of blob bytes, wrapping any Storage.
//
// It exists because history assembly re-reads every attachment in a
// conversation on every single send. A conversation with four images attached
// on turn two reads those four images again on turns three through fifty, from
// disk or from an object store, before the request can even be built.
//
// Correctness is free here: blobs are content-addressed by sha256, so an entry
// can never go stale. The only way to invalidate one is for the content to
// change, which changes the key. That is what makes caching safe to do without
// any coordination with writes.
//
// Bounded by total bytes rather than entry count, because the entries are
// images and documents whose sizes differ by three orders of magnitude. LRU
// eviction: a conversation being actively worked on should stay resident while
// one abandoned an hour ago should not.
type ReadCache struct {
	inner    Storage
	maxBytes int64

	mu      sync.Mutex
	bytes   int64
	entries map[string]*list.Element
	lru     *list.List // front = most recently used
}

type cacheEntry struct {
	key  string
	data []byte
}

// NewReadCache wraps s with a cache holding at most maxBytes of blob data.
// A maxBytes of zero or less disables caching and returns the inner Storage
// unchanged, so turning it off is a config change rather than a code path.
func NewReadCache(s Storage, maxBytes int64) Storage {
	if maxBytes <= 0 {
		return s
	}
	return &ReadCache{
		inner:    s,
		maxBytes: maxBytes,
		entries:  map[string]*list.Element{},
		lru:      list.New(),
	}
}

// key scopes entries per user as well as per hash.
//
// The hash alone would be enough for correctness, since identical content
// hashes identically. Scoping by user anyway keeps the cache from becoming a
// side channel that reveals whether another account holds a given file.
func cacheKey(userID uuid.UUID, sha256 string) string {
	return userID.String() + "/" + sha256
}

func (c *ReadCache) Get(ctx context.Context, userID uuid.UUID, sha256 string) (io.ReadCloser, error) {
	k := cacheKey(userID, sha256)

	c.mu.Lock()
	if el, ok := c.entries[k]; ok {
		c.lru.MoveToFront(el)
		data := el.Value.(*cacheEntry).data
		c.mu.Unlock()
		return io.NopCloser(bytes.NewReader(data)), nil
	}
	c.mu.Unlock()

	// Read outside the lock. Two concurrent misses on one key both read and
	// both store, which wastes one read and is much cheaper than serializing
	// every miss behind a single mutex.
	rc, err := c.inner.Get(ctx, userID, sha256)
	if err != nil {
		return nil, err
	}
	data, err := io.ReadAll(rc)
	_ = rc.Close()
	if err != nil {
		return nil, err
	}
	c.store(k, data)
	return io.NopCloser(bytes.NewReader(data)), nil
}

func (c *ReadCache) store(k string, data []byte) {
	size := int64(len(data))
	// An object larger than the whole budget would evict everything and then
	// not fit. Skip it: one big file should not empty the cache for the many
	// small ones that benefit most.
	if size > c.maxBytes {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if el, ok := c.entries[k]; ok {
		c.lru.MoveToFront(el)
		return
	}
	for c.bytes+size > c.maxBytes && c.lru.Len() > 0 {
		oldest := c.lru.Back()
		ent := oldest.Value.(*cacheEntry)
		c.lru.Remove(oldest)
		delete(c.entries, ent.key)
		c.bytes -= int64(len(ent.data))
	}
	c.entries[k] = c.lru.PushFront(&cacheEntry{key: k, data: data})
	c.bytes += size
}

// Put writes through and does not populate the cache.
//
// A freshly uploaded file is usually read back moments later, so populating
// would help. It is skipped anyway because Put takes an io.Reader the caller
// owns, and buffering it here to cache it would double peak memory on the
// upload path for a benefit the first Get provides regardless.
func (c *ReadCache) Put(ctx context.Context, userID uuid.UUID, sha256, mime string, data io.Reader) error {
	return c.inner.Put(ctx, userID, sha256, mime, data)
}

func (c *ReadCache) Delete(ctx context.Context, userID uuid.UUID, sha256 string) error {
	k := cacheKey(userID, sha256)
	c.mu.Lock()
	if el, ok := c.entries[k]; ok {
		ent := el.Value.(*cacheEntry)
		c.lru.Remove(el)
		delete(c.entries, k)
		c.bytes -= int64(len(ent.data))
	}
	c.mu.Unlock()
	return c.inner.Delete(ctx, userID, sha256)
}
