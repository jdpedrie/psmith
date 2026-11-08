package web

import (
	"strconv"
	"strings"
	"sync"
	"time"
)

// The server keeps no record of a provider's last connection test or of what
// its last discovery found, but the provider pages show both: the list's
// status dot and the "3 new" badge. This process remembers them until it
// restarts. A provider nobody has tested since then reads "Not tested".

type provStatus struct {
	At        time.Time
	OK        bool
	LatencyMS int64
	Msg       string
}

func (s provStatus) vm(now time.Time) *testVM {
	if s.OK {
		return &testVM{OK: true, Message: "Connected in " + strconv.FormatInt(s.LatencyMS, 10) + " ms, " + saAgo(now, s.At)}
	}
	msg := "Connection failed"
	if s.Msg != "" {
		msg += ": " + s.Msg
	}
	return &testVM{Message: msg}
}

var (
	saTests      sync.Map // provider id -> provStatus
	saDiscovered sync.Map // provider id -> []string model ids
)

func rememberTest(id string, s provStatus) { saTests.Store(id, s) }

func lastTest(id string) (provStatus, bool) {
	v, ok := saTests.Load(id)
	if !ok {
		return provStatus{}, false
	}
	return v.(provStatus), true
}

func rememberDiscovered(id string, ids []string) { saDiscovered.Store(id, ids) }

func lastDiscovered(id string) ([]string, bool) {
	v, ok := saDiscovered.Load(id)
	if !ok {
		return nil, false
	}
	return v.([]string), true
}

func forgetProvider(id string) {
	saTests.Delete(id)
	saDiscovered.Delete(id)
}

// A masked key shows twelve dots on a desktop and eight on a phone; these
// split it so the extra four can hide.
const saDots8 = "••••••••"

func saKeySplit(k string) (head, wide, tail string) {
	i := strings.Index(k, saDots8+"••••")
	if i < 0 {
		return k, "", ""
	}
	return k[:i+len(saDots8)], "••••", k[i+len(saDots8)+len("••••"):]
}

func saKeyHead(k string) string { h, _, _ := saKeySplit(k); return h }
func saKeyWide(k string) string { _, w, _ := saKeySplit(k); return w }
func saKeyTail(k string) string { _, _, t := saKeySplit(k); return t }
