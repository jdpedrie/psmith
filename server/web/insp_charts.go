package web

import (
	"context"
	"fmt"
	"sort"
	"strings"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// The Context tab's charts, as the Mac draws them: how big the context got
// after each reply, and what each reply cost. Both are drawn server-side as
// SVG in a 100-wide box that stretches to the column.

const (
	chartW     = 100.0
	growthH    = 84.0
	costH      = 56.0
	cacheFloor = 4096 // prompts below this don't count as a cache miss, as on the Mac
)

// turnSample is one reply's numbers.
type turnSample struct {
	Tokens    int64
	Cost      float64
	Priced    bool
	CacheMiss bool
}

// runChartsVM is what the two charts draw.
type runChartsVM struct {
	Replies int
	Line    string // polyline points
	WarnY   float64
	Warn    bool
	Label   string // the growth chart's accessible description

	Bars      []chartBarVM
	AnyMiss   bool
	CostLabel string
}

type chartBarVM struct {
	X, Y, W, H float64
	Miss       bool
}

// turnSamples reads each reply's usage. A reply's context is its whole
// prompt plus what it wrote; a reply that read under 30% of a large prompt
// from the cache missed it. The first reply has nothing to hit.
func turnSamples(msgs []*psmithv1.Message) []turnSample {
	var out []turnSample
	for _, m := range msgs {
		u := m.GetUsage()
		if m.GetRole() != psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT || u == nil || u.InputTokens == nil {
			continue
		}
		in, read := int64(u.GetInputTokens()), int64(u.GetCacheReadTokens())
		prompt := in
		if read > in {
			prompt = in + read
		}
		s := turnSample{Tokens: prompt + int64(u.GetOutputTokens())}
		if u.TotalCostUsd != nil {
			s.Cost, s.Priced = u.GetTotalCostUsd(), true
		}
		reports := u.CacheReadTokens != nil || u.CacheWriteTokens != nil
		if len(out) > 0 && reports && prompt >= cacheFloor && float64(read)/float64(max(prompt, 1)) < 0.3 {
			s.CacheMiss = true
		}
		out = append(out, s)
	}
	return out
}

// runCharts lays out both charts, or returns nil with fewer than two
// replies: one point isn't a line.
func runCharts(samples []turnSample, warn int64) *runChartsVM {
	n := len(samples)
	if n < 2 {
		return nil
	}
	vm := &runChartsVM{Replies: n}
	top := warn
	for _, s := range samples {
		top = max(top, s.Tokens)
	}
	ceil := float64(top) * 1.08
	pts := make([]string, n)
	for i, s := range samples {
		pts[i] = fmt.Sprintf("%.2f,%.2f", float64(i)/float64(n-1)*chartW, growthH-float64(s.Tokens)/ceil*growthH)
	}
	vm.Line = strings.Join(pts, " ")
	if warn > 0 {
		vm.Warn, vm.WarnY = true, growthH-float64(warn)/ceil*growthH
	}
	vm.Label = "Context size by reply, from " + abbrevTokens(int32(samples[0].Tokens)) + " to " + abbrevTokens(int32(samples[n-1].Tokens)) + " tokens"

	var priced []turnSample
	hi, lo := 0.0, -1.0
	for _, s := range samples {
		if !s.Priced {
			continue
		}
		priced = append(priced, s)
		hi = max(hi, s.Cost)
		if lo < 0 || s.Cost < lo {
			lo = s.Cost
		}
	}
	if len(priced) == 0 || hi <= 0 {
		return vm
	}
	slot := chartW / float64(len(priced))
	w := slot * 0.62
	for i, s := range priced {
		h := s.Cost / hi * costH
		vm.Bars = append(vm.Bars, chartBarVM{X: float64(i)*slot + (slot-w)/2, Y: costH - h, W: w, H: h, Miss: s.CacheMiss})
		vm.AnyMiss = vm.AnyMiss || s.CacheMiss
	}
	vm.CostLabel = fmt.Sprintf("Cost per reply, from $%.3f to $%.3f", lo, hi)
	return vm
}

// unpricedModels names the models whose replies have usage but no cost, so
// the tab can say the total leaves them out.
func (h *Handler) unpricedModels(ctx context.Context, msgs []*psmithv1.Message) string {
	seen := map[string]bool{}
	var names []string
	for _, m := range msgs {
		u := m.GetUsage()
		if m.GetRole() != psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT || u == nil || u.TotalCostUsd != nil || m.GetModelId() == "" {
			continue
		}
		name := h.modelName(ctx, m.GetProviderId(), m.GetModelId())
		if !seen[name] {
			seen[name] = true
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

func f2(v float64) string { return fmt.Sprintf("%.2f", v) }
