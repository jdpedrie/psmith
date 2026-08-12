package conversations

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/store"
)

// attachCouncil wires a two-member council onto the fixture's profile, both
// members pointing at the fixture's own model so the fake serves every hop.
func attachCouncil(t *testing.T, q *store.Queries, f sendFixture, extra string) {
	t.Helper()
	ctx := context.Background()

	mk := func(name string) uuid.UUID {
		id, _ := uuid.NewV7()
		sys := name + " speaks."
		p, err := q.CreateProfile(ctx, store.CreateProfileParams{
			ID: id, UserID: f.user.ID, Name: name, SystemMessage: &sys,
		})
		if err != nil {
			t.Fatalf("CreateProfile(%s): %v", name, err)
		}
		defaults := fmt.Sprintf(`{"default_provider_id":%q,"default_model_id":%q}`,
			f.provider.ID.String(), f.modelID)
		if err := q.UpdateProfileDefaultSettings(ctx, store.UpdateProfileDefaultSettingsParams{
			ID: p.ID, DefaultSettings: []byte(defaults),
		}); err != nil {
			t.Fatalf("defaults(%s): %v", name, err)
		}
		return p.ID
	}
	a, b := mk("Skeptic"), mk("Optimist")

	cfg := fmt.Sprintf(`{"members":[
	  {"id":"m1","name":"Skeptic","profile_id":%q},
	  {"id":"m2","name":"Optimist","profile_id":%q}]%s}`, a.String(), b.String(), extra)

	if err := q.ReplaceProfilePlugins(ctx, f.profile.ID); err != nil {
		t.Fatalf("clear plugins: %v", err)
	}
	if _, err := q.InsertProfilePlugin(ctx, store.InsertProfilePluginParams{
		ProfileID: f.profile.ID, PluginName: "council", Ordinal: 0,
		ConfigEncrypted: []byte(cfg),
	}); err != nil {
		t.Fatalf("attach council: %v", err)
	}
}

// maxTokensFromBody digs the output cap out of a captured request, whichever
// name the driver used. The names differ per API — Anthropic's max_tokens,
// Chat Completions' max_completion_tokens, Responses' max_output_tokens — and
// guessing one is how this went unverified the first time.
func maxTokensFromBody(t *testing.T, body []byte) (int, string) {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("request body was not JSON: %v\n%s", err, body)
	}
	for _, k := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if v, ok := m[k]; ok {
			if f, ok := v.(float64); ok {
				return int(f), k
			}
		}
	}
	return 0, ""
}

// The per-hop cap is the only lever that actually stops a model rather than
// asking it to stop, so "answer in one word" depends entirely on it reaching
// the wire. Asserted against the real outgoing HTTP body.
func TestCouncil_PerHopTokenCapReachesTheWire(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for i := 0; i < 4; i++ {
		fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}}})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	// Small, distinctive numbers so a default cannot masquerade as the cap.
	attachCouncil(t, q, f, `,"opening_tokens":777,"discussion_tokens":33,"max_exchanges":4`)

	// Opening turn.
	_, a1 := runOneTurn(t, svc, sup, q, f, "should we roll back?")

	reqs := fake.Requests()
	if len(reqs) == 0 {
		t.Fatal("no upstream request captured")
	}
	got, field := maxTokensFromBody(t, reqs[len(reqs)-1].Body)
	if field == "" {
		t.Fatalf("no output cap on the wire at all:\n%s", reqs[len(reqs)-1].Body)
	}
	if got != 777 {
		t.Errorf("opening hop sent %s=%d, want 777", field, got)
	}
	t.Logf("opening hop: %s=%d", field, got)

	// Continue: the discussion cap, which is the one that makes a one-word
	// answer possible.
	leaf := a1.ID.String()
	if _, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:     f.conv.ID.String(),
		ParentMessageId:    &leaf,
		ContinueDiscussion: true,
	})); err != nil {
		t.Fatalf("continue: %v", err)
	}
	// The continue's stream runs in the supervisor; wait for the extra
	// request rather than for view-model state that does not exist here.
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if len(fake.Requests()) > len(reqs) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	reqs = fake.Requests()
	got, field = maxTokensFromBody(t, reqs[len(reqs)-1].Body)
	if got != 33 {
		t.Errorf("discussion hop sent %s=%d, want 33", field, got)
	}
	t.Logf("discussion hop: %s=%d", field, got)
}

// An ordinary conversation must not inherit a council's caps.
func TestCouncil_NoCapWithoutARoutedTurn(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	runOneTurn(t, svc, sup, q, f, "hello")

	reqs := fake.Requests()
	got, field := maxTokensFromBody(t, reqs[len(reqs)-1].Body)
	if got == 777 || got == 33 {
		t.Errorf("an unrouted turn picked up a council cap: %s=%d", field, got)
	}
	t.Logf("unrouted turn: %s=%d (driver default)", field, got)
}

// The direction has to reach the wire as its own user turn, or two persona
// turns end up adjacent and the provider silently merges them.
func TestCouncil_DirectionReachesTheWire(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for i := 0; i < 3; i++ {
		fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}}})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	attachCouncil(t, q, f, `,"max_exchanges":4`)

	runOneTurn(t, svc, sup, q, f, "should we roll back?")

	reqs := fake.Requests()
	body := string(reqs[len(reqs)-1].Body)
	if !strings.Contains(body, "[panel]") {
		t.Fatalf("no moderator direction on the wire:\n%s", body)
	}
	if !strings.Contains(body, "Skeptic") {
		t.Errorf("direction did not name the speaker:\n%s", body)
	}
}
