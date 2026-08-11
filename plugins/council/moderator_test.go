package council

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/pluginapi/host"
)

// fakeCompleter records what it was asked and returns a canned reply.
type fakeCompleter struct {
	reply     string
	err       error
	gotSystem string
	gotUser   string
	gotModel  string
	calls     int
}

func (f *fakeCompleter) Complete(_ context.Context, _, modelID, system, user string, _ int) (string, error) {
	f.calls++
	f.gotSystem, f.gotUser, f.gotModel = system, user, modelID
	return f.reply, f.err
}

const moderated = `{"members":[
  {"id":"a","name":"Skeptic","profile_id":"p-a"},
  {"id":"b","name":"Optimist","profile_id":"p-b"},
  {"id":"c","name":"Historian","profile_id":"p-c"}],
  "moderator_model":{"provider_id":"prov-1","model_id":"cheap-1"},
  "max_exchanges":6}`

func withCompleter(t *testing.T, c *council, f *fakeCompleter, d *discussion) (decision, bool) {
	t.Helper()
	ctx := host.WithCompleter(context.Background(), f)
	return c.moderate(ctx, d)
}

// The whole point: the moderator overrides roster order. Round-robin would
// pick Skeptic first; the moderator picks Historian.
func TestModerator_OverridesRoundRobin(t *testing.T) {
	c := build(t, moderated)
	f := &fakeCompleter{reply: `{"speaker":"Historian","length":"short","end":false}`}
	got, ok := withCompleter(t, c, f, &discussion{})
	if !ok {
		t.Fatal("moderator should have claimed the turn")
	}
	if got.MemberID != "c" {
		t.Errorf("expected Historian (c), got %q", got.MemberID)
	}
	if got.MaxTokens != defaultDiscussionTokens {
		t.Errorf("short should use the discussion cap, got %d", got.MaxTokens)
	}
	if f.gotModel != "cheap-1" {
		t.Errorf("wrong model called: %q", f.gotModel)
	}
}

func TestModerator_LongUsesTheOpeningBudget(t *testing.T) {
	c := build(t, moderated)
	f := &fakeCompleter{reply: `{"speaker":"Skeptic","length":"long","end":false}`}
	got, _ := withCompleter(t, c, f, &discussion{})
	if got.MaxTokens != defaultOpeningTokens {
		t.Errorf("long should use the opening cap, got %d", got.MaxTokens)
	}
	if !strings.Contains(got.Direction, "at length") {
		t.Errorf("direction should ask for length: %q", got.Direction)
	}
}

// Ending early is a good outcome, not a failure.
func TestModerator_CanEndTheDiscussion(t *testing.T) {
	c := build(t, moderated)
	f := &fakeCompleter{reply: `{"end":true}`}
	got, ok := withCompleter(t, c, f, &discussion{Hops: []hop{{MemberID: "a"}}})
	if !ok || !got.End {
		t.Fatalf("moderator should be able to end the discussion: ok=%v end=%v", ok, got.End)
	}
}

// Models wrap JSON in prose or fences even when told not to. A routing
// decision is too small a thing to lose to a stray preamble.
func TestModerator_ToleratesWrappedJSON(t *testing.T) {
	for _, reply := range []string{
		"Here you go:\n```json\n{\"speaker\":\"Optimist\",\"length\":\"short\"}\n```",
		"  {\"speaker\":\"Optimist\"}  ",
		"Sure! {\"speaker\":\"Optimist\",\"end\":false} Hope that helps.",
	} {
		c := build(t, moderated)
		got, ok := withCompleter(t, c, &fakeCompleter{reply: reply}, &discussion{})
		if !ok || got.MemberID != "b" {
			t.Errorf("failed to parse %q: ok=%v member=%q", reply, ok, got.MemberID)
		}
	}
}

// Every failure falls back to round-robin. A panel that goes silent when a
// cheap model times out is worse than a panel that takes turns in order.
func TestModerator_DeclinesOnEveryFailure(t *testing.T) {
	cases := map[string]*fakeCompleter{
		"call errored":    {err: errors.New("timeout")},
		"empty reply":     {reply: ""},
		"not json":        {reply: "I think Skeptic should go next."},
		"unknown speaker": {reply: `{"speaker":"Nobody"}`},
		"speaker missing": {reply: `{"length":"short"}`},
	}
	for name, f := range cases {
		t.Run(name, func(t *testing.T) {
			c := build(t, moderated)
			if _, ok := withCompleter(t, c, f, &discussion{}); ok {
				t.Error("expected the moderator to decline so round-robin takes over")
			}
		})
	}
}

func TestModerator_SkippedWithoutAModelOrCompleter(t *testing.T) {
	// No model configured.
	c := build(t, threeMembers)
	f := &fakeCompleter{reply: `{"speaker":"Optimist"}`}
	if _, ok := withCompleter(t, c, f, &discussion{}); ok {
		t.Error("no moderator model configured should mean no moderator call")
	}
	if f.calls != 0 {
		t.Errorf("should not have called a model at all, got %d calls", f.calls)
	}

	// Model configured but nothing wired.
	c2 := build(t, moderated)
	if _, ok := c2.moderate(context.Background(), &discussion{}); ok {
		t.Error("no completer in context should decline")
	}
}

// The brief is a window, not the transcript. Routing must not cost as much as
// answering.
func TestModeratorBrief_IsWindowedAndNamesMembers(t *testing.T) {
	c := build(t, moderated)
	d := &discussion{}
	for i := 0; i < 12; i++ {
		d.Hops = append(d.Hops, hop{MemberID: "a", Excerpt: "turn " + itoa(i)})
	}
	brief := c.moderatorBrief(d)
	if strings.Contains(brief, "turn 0") {
		t.Error("brief should not carry the whole discussion")
	}
	if !strings.Contains(brief, "turn 11") {
		t.Error("brief should carry the most recent turns")
	}
	for _, name := range []string{"Skeptic", "Optimist", "Historian"} {
		if !strings.Contains(brief, name) {
			t.Errorf("brief should list %q so the moderator can name it", name)
		}
	}
}

func TestModeratorBrief_MarksTheOpeningTurn(t *testing.T) {
	c := build(t, moderated)
	if !strings.Contains(c.moderatorBrief(&discussion{}), "opening turn") {
		t.Error("an empty discussion should be described as the opener")
	}
}

// The excerpt is what makes the moderator's view more than a list of names.
func TestExcerpt_CollapsesAndTruncates(t *testing.T) {
	got := excerpt("line one\n\n   line two   \n", 200)
	if got != "line one line two" {
		t.Errorf("whitespace not collapsed: %q", got)
	}
	long := excerpt(strings.Repeat("x", 500), 10)
	if len([]rune(long)) != 11 { // 10 + ellipsis
		t.Errorf("expected truncation to 10 runes plus ellipsis, got %q", long)
	}
}

func TestTransformAssistantContent_CapturesExcerptWithoutRewriting(t *testing.T) {
	c := build(t, moderated)
	c.pendingHop = &hop{MemberID: "a"}
	const reply = "The rollback path is untested.\n\nWe should wait."
	if out := c.TransformAssistantContent(reply); out != reply {
		t.Errorf("content must pass through unchanged, got %q", out)
	}
	if !strings.Contains(c.pendingHop.Excerpt, "rollback path") {
		t.Errorf("excerpt not captured: %q", c.pendingHop.Excerpt)
	}
}

// The moderator must not be able to spend a budget it does not control.
func TestModerator_CannotExceedTheExchangeCap(t *testing.T) {
	c := build(t, `{"members":[{"id":"a","name":"A","profile_id":"p"},{"id":"b","name":"B","profile_id":"q"}],
	  "moderator_model":{"provider_id":"p1","model_id":"m1"},"max_exchanges":2}`)
	d := &discussion{Hops: []hop{{MemberID: "a"}, {MemberID: "b"}}}
	// route() is consulted before the moderator, and it has already ended.
	if got := c.route(d); !got.End {
		t.Fatal("round-robin should refuse past the cap")
	}
}

// A roster past the palette's discriminating range is rejected while someone
// is still editing it, rather than two members quietly sharing a rail later.
func TestConfig_RejectsAnOversizedRoster(t *testing.T) {
	var members []string
	for i := 0; i < maxMembers+1; i++ {
		members = append(members, `{"id":"`+itoa(i)+`","name":"M`+itoa(i)+`","profile_id":"p"}`)
	}
	_, err := newCouncil(json.RawMessage(`{"members":[` + strings.Join(members, ",") + `]}`))
	if err == nil {
		t.Fatalf("a roster of %d should be rejected", maxMembers+1)
	}
	if !strings.Contains(err.Error(), "maximum") {
		t.Errorf("error should say what the limit is: %v", err)
	}
}
