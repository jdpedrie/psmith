package web

import (
	"strconv"
	"strings"
	"time"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// provStatus is a provider's connection test as the pages show it. The
// server records each test (UserModelProvider.last_test), so the list's dot
// and the page's line survive a restart.
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

// lastTest is the provider's recorded test, if it has been tested.
func lastTest(p *psmithv1.UserModelProvider) (provStatus, bool) {
	t := p.GetLastTest()
	if t == nil {
		return provStatus{}, false
	}
	return provStatus{At: t.GetTestedAt().AsTime(), OK: t.GetOk(), LatencyMS: t.GetLatencyMs(), Msg: t.GetMessage()}, true
}

// newModels counts what the provider's last discovery found that isn't on.
func newModels(p *psmithv1.UserModelProvider, enabled func(string) bool) int {
	n := 0
	for _, id := range p.GetLastDiscoveredModelIds() {
		if !enabled(id) {
			n++
		}
	}
	return n
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
