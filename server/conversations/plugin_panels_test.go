package conversations

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	_ "github.com/jdpedrie/psmith/plugins/all"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/store"
)

const packsConfigJSON = `{"packs":[
  {"id":"runbook","name":"Deploy runbook","description":"Release steps","body":"RUNBOOK BODY"},
  {"id":"schema","name":"Schema notes","description":"Table layout","body":"SCHEMA BODY"}
]}`

// panelFixture wires a conversation whose profile carries context_packs.
func panelFixture(t *testing.T, prefix string) (*Service, *store.Queries, context.Context, uuid.UUID) {
	t.Helper()
	svc, q := newTestSvc(t)
	u := mustCreateUser(t, q, prefix)
	ctx := ctxAs(u)

	profID := uuid.New()
	if _, err := q.CreateProfile(context.Background(), store.CreateProfileParams{
		ID: profID, UserID: u.ID, Name: "packs-" + prefix,
	}); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	sealed, err := crypto.Nop{}.Encrypt([]byte(packsConfigJSON))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if _, err := q.InsertProfilePlugin(context.Background(), store.InsertProfilePluginParams{
		ProfileID: profID, Ordinal: 0, PluginName: "context_packs", ConfigEncrypted: sealed,
	}); err != nil {
		t.Fatalf("InsertProfilePlugin: %v", err)
	}

	convID := uuid.New()
	if _, err := q.CreateConversation(context.Background(), store.CreateConversationParams{
		ID: convID, UserID: u.ID, ProfileID: profID,
	}); err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	return svc, q, ctx, convID
}

// The panel must arrive as a card_list: that is what lets every client render
// it with the fragment renderer it already has instead of a view per plugin.
func TestGetPluginPanel_RendersFragments(t *testing.T) {
	t.Parallel()
	svc, _, ctx, convID := panelFixture(t, "panel-render")

	resp, err := svc.GetPluginPanel(ctx, connect.NewRequest(&psmithv1.GetPluginPanelRequest{
		ConversationId: convID.String(),
		PluginName:     "context_packs",
	}))
	if err != nil {
		t.Fatalf("GetPluginPanel: %v", err)
	}
	if len(resp.Msg.Fragments) == 0 {
		t.Fatal("expected a panel body")
	}
	if got := resp.Msg.Fragments[0].Component; got != "card_list" {
		t.Errorf("component: got %q want card_list", got)
	}
	if !strings.Contains(string(resp.Msg.Fragments[0].Props), "Deploy runbook") {
		t.Errorf("pack names missing from the panel: %s", resp.Msg.Fragments[0].Props)
	}
	// Bodies are the thing being deferred; a panel listing them would defeat it.
	if strings.Contains(string(resp.Msg.Fragments[0].Props), "RUNBOOK BODY") {
		t.Error("pack bodies must not travel to the client")
	}
}

// The whole return path: an action reaches the plugin, mutates its state, and
// the re-rendered panel reflects it in the same round trip.
func TestInvokePluginAction_ArmsAndReRenders(t *testing.T) {
	t.Parallel()
	svc, _, ctx, convID := panelFixture(t, "panel-arm")

	resp, err := svc.InvokePluginAction(ctx, connect.NewRequest(&psmithv1.InvokePluginActionRequest{
		ConversationId: convID.String(),
		PluginName:     "context_packs",
		Action:         "arm",
		Params:         map[string]string{"id": "runbook"},
	}))
	if err != nil {
		t.Fatalf("InvokePluginAction: %v", err)
	}
	if len(resp.Msg.Fragments) == 0 {
		t.Fatal("expected the re-rendered panel")
	}
	var props struct {
		Items []struct {
			Title  string   `json:"title"`
			Badges []string `json:"badges"`
		} `json:"items"`
	}
	if err := json.Unmarshal(resp.Msg.Fragments[0].Props, &props); err != nil {
		t.Fatalf("unmarshal props: %v", err)
	}
	for _, it := range props.Items {
		if it.Title == "Deploy runbook" {
			if len(it.Badges) == 0 || it.Badges[0] != "Sends next" {
				t.Errorf("armed pack should say so in the same response: %+v", it)
			}
			return
		}
	}
	t.Error("armed pack not found in the re-rendered panel")
}

// A client newer than the server is a real deployment state; an action the
// plugin has never heard of must be reported, not guessed at.
func TestInvokePluginAction_UnknownActionIsFailedPrecondition(t *testing.T) {
	t.Parallel()
	svc, _, ctx, convID := panelFixture(t, "panel-unknown")

	_, err := svc.InvokePluginAction(ctx, connect.NewRequest(&psmithv1.InvokePluginActionRequest{
		ConversationId: convID.String(),
		PluginName:     "context_packs",
		Action:         "teleport",
		Params:         map[string]string{"id": "runbook"},
	}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}

// A plugin that is not on this conversation must not be reachable, or a panel
// would be a way to poke at plugins the profile never enabled.
func TestGetPluginPanel_RejectsInactivePlugin(t *testing.T) {
	t.Parallel()
	svc, _, ctx, convID := panelFixture(t, "panel-inactive")

	_, err := svc.GetPluginPanel(ctx, connect.NewRequest(&psmithv1.GetPluginPanelRequest{
		ConversationId: convID.String(),
		PluginName:     "brave_search",
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestGetPluginPanel_RejectsForeignConversation(t *testing.T) {
	t.Parallel()
	svc, q, _, convID := panelFixture(t, "panel-owner")
	other := mustCreateUser(t, q, "panel-stranger")

	_, err := svc.GetPluginPanel(ctxAs(other), connect.NewRequest(&psmithv1.GetPluginPanelRequest{
		ConversationId: convID.String(),
		PluginName:     "context_packs",
	}))
	if err == nil {
		t.Fatal("another user's conversation must not be readable")
	}
}
