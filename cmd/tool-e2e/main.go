// tool-e2e exercises the conversations-side tool loop end-to-end against a
// running reeved. It logs in, finds the Personal Assistant profile (which
// has the brave_search plugin attached), creates a fresh conversation,
// sends a search-prompting message, subscribes to the stream, prints
// every chunk it sees, and finally re-reads the persisted assistant
// message to verify tool_calls JSONB is populated.
//
// The test does not assume the Brave API key is valid — what we're
// verifying is the loop machinery (model emits tool_use → loop dispatches
// → tool_result spliced back → model continues), not Brave itself. A 4xx
// from Brave still produces a tool_result with .error set; the model
// reacts; the loop terminates cleanly.
//
// Usage:
//
//	go run ./cmd/tool-e2e -addr http://localhost:8080 -u john -p password
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"time"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/gen/reeve/v1/reevev1connect"
)

const (
	probeText = "Search the web for: 'who won the 2026 Kentucky Derby'. Use the web_search tool. After you get results, summarise the top hit in one sentence."
)

type bearerTransport struct {
	token string
	base  http.RoundTripper
}

func (b *bearerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req.Header.Set("Authorization", "Bearer "+b.token)
	if b.base == nil {
		return http.DefaultTransport.RoundTrip(req)
	}
	return b.base.RoundTrip(req)
}

func main() {
	addr := flag.String("addr", "http://localhost:8080", "reeved base URL")
	user := flag.String("u", "john", "username")
	pass := flag.String("p", "password", "password")
	profile := flag.String("profile", "Personal Assistant", "profile name to send under")
	prompt := flag.String("prompt", probeText, "user prompt")
	providerName := flag.String("provider", "", "optional per-turn provider label override (e.g. 'Anthropic')")
	modelID := flag.String("model", "", "optional per-turn model id override (e.g. 'claude-haiku-4-5-20251001')")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// 1. Login.
	rawClient := http.DefaultClient
	authClient := reevev1connect.NewAuthServiceClient(rawClient, *addr)
	loginResp, err := authClient.Login(ctx, connect.NewRequest(&reevev1.LoginRequest{
		Username: *user,
		Password: *pass,
	}))
	if err != nil {
		log.Fatalf("login failed: %v", err)
	}
	token := loginResp.Msg.SessionToken
	fmt.Printf("✓ logged in as %s\n", *user)

	// 2. Authed clients (every subsequent call carries the bearer).
	authedHTTP := &http.Client{Transport: &bearerTransport{token: token}}
	profilesClient := reevev1connect.NewProfilesServiceClient(authedHTTP, *addr)
	convClient := reevev1connect.NewConversationsServiceClient(authedHTTP, *addr)
	streamsClient := reevev1connect.NewStreamsServiceClient(authedHTTP, *addr)
	mpClient := reevev1connect.NewModelProvidersServiceClient(authedHTTP, *addr)

	// 3. Find the target profile.
	listProf, err := profilesClient.ListProfiles(ctx, connect.NewRequest(&reevev1.ListProfilesRequest{}))
	if err != nil {
		log.Fatalf("list profiles: %v", err)
	}
	var profileID string
	for _, p := range listProf.Msg.Profiles {
		if p.Name == *profile {
			profileID = p.Id
			break
		}
	}
	if profileID == "" {
		log.Fatalf("profile %q not found", *profile)
	}
	fmt.Printf("✓ profile %q id=%s\n", *profile, profileID)

	// 4. Verify the profile actually has brave_search attached.
	pluginsResp, err := profilesClient.GetProfilePlugins(ctx, connect.NewRequest(&reevev1.GetProfilePluginsRequest{
		ProfileId: profileID,
	}))
	if err != nil {
		log.Fatalf("get plugins: %v", err)
	}
	hasBrave := false
	for _, pl := range pluginsResp.Msg.Plugins {
		if pl.PluginName == "brave_search" {
			hasBrave = true
		}
	}
	if !hasBrave {
		log.Fatalf("profile %q does not have brave_search attached", *profile)
	}
	fmt.Printf("✓ brave_search plugin attached\n")

	// 5. Fresh conversation.
	createResp, err := convClient.CreateConversation(ctx, connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: profileID,
	}))
	if err != nil {
		log.Fatalf("create conversation: %v", err)
	}
	convID := createResp.Msg.Conversation.Id
	fmt.Printf("✓ conversation id=%s\n", convID)

	// 6. Resolve optional provider/model override into ids.
	sendReq := &reevev1.SendMessageRequest{
		ConversationId: convID,
		Content:        *prompt,
	}
	if *providerName != "" || *modelID != "" {
		listProv, err := mpClient.ListUserModelProviders(ctx, connect.NewRequest(&reevev1.ListUserModelProvidersRequest{}))
		if err != nil {
			log.Fatalf("list providers: %v", err)
		}
		var resolvedProviderID string
		for _, p := range listProv.Msg.Providers {
			if p.Label == *providerName {
				resolvedProviderID = p.Id
				break
			}
		}
		if resolvedProviderID == "" {
			log.Fatalf("provider label %q not found", *providerName)
		}
		sendReq.ProviderId = &resolvedProviderID
		sendReq.ModelId = modelID
		fmt.Printf("✓ override: provider=%s id=%s model=%s\n", *providerName, resolvedProviderID, *modelID)
	}

	// 7. SendMessage — the server returns immediately with the user msg + run.
	sendResp, err := convClient.SendMessage(ctx, connect.NewRequest(sendReq))
	if err != nil {
		log.Fatalf("send message: %v", err)
	}
	runID := sendResp.Msg.StreamRun.Id
	fmt.Printf("✓ stream run id=%s; subscribing…\n", runID)

	// 7. Subscribe + drain. Print every chunk type so we can see the loop run.
	sub, err := streamsClient.SubscribeStream(ctx, connect.NewRequest(&reevev1.SubscribeStreamRequest{
		StreamRunId:  runID,
		FromSequence: 0,
	}))
	if err != nil {
		log.Fatalf("subscribe: %v", err)
	}

	var counts = map[string]int{}
	for sub.Receive() {
		ev := sub.Msg()
		if ch := ev.GetChunk(); ch != nil {
			counts[ch.Type.String()]++
			switch ch.Type {
			case reevev1.ChunkType_CHUNK_TYPE_TOOL_USE_START,
				reevev1.ChunkType_CHUNK_TYPE_TOOL_USE_END,
				reevev1.ChunkType_CHUNK_TYPE_TOOL_RESULT,
				reevev1.ChunkType_CHUNK_TYPE_ERROR,
				reevev1.ChunkType_CHUNK_TYPE_USAGE:
				fmt.Printf("  [%d] %s payload=%s\n", ch.Sequence, ch.Type, string(ch.Payload))
			}
		}
		if term := ev.GetTerminal(); term != nil {
			fmt.Printf("✓ stream terminal status=%s\n", term.Status)
			if term.ResultMessageId != nil {
				readBackAndVerify(ctx, convClient, *term.ResultMessageId, counts)
			}
			break
		}
	}
	if err := sub.Err(); err != nil {
		log.Fatalf("subscribe stream error: %v", err)
	}
}

func readBackAndVerify(ctx context.Context, c reevev1connect.ConversationsServiceClient, msgID string, counts map[string]int) {
	fmt.Printf("\n--- chunk counts ---\n")
	for k, v := range counts {
		fmt.Printf("  %-32s %d\n", k, v)
	}

	resp, err := c.GetMessage(ctx, connect.NewRequest(&reevev1.GetMessageRequest{Id: msgID}))
	if err != nil {
		log.Fatalf("get materialised message: %v", err)
	}
	m := resp.Msg.Message
	fmt.Printf("\n--- materialised message ---\n")
	fmt.Printf("  role:          %s\n", m.Role)
	fmt.Printf("  content[:200]: %q\n", trim(m.Content, 200))
	if m.ErrorText != nil {
		fmt.Printf("  error_text:    %q\n", *m.ErrorText)
	}
	fmt.Printf("  tool_calls:    %d entries\n", len(m.ToolCalls))
	for i, tc := range m.ToolCalls {
		fmt.Printf("    [%d] id=%s name=%s elapsed=%dms\n", i, tc.Id, tc.Name, tc.ElapsedMs)
		fmt.Printf("        input:  %s\n", trim(string(tc.Input), 240))
		if len(tc.Output) > 0 {
			fmt.Printf("        output: %s\n", trim(string(tc.Output), 240))
		}
		if tc.Error != nil {
			fmt.Printf("        error:  %s\n", *tc.Error)
		}
	}

	if len(m.ToolCalls) == 0 {
		log.Fatalf("FAIL: tool_calls empty — the loop never recorded a tool invocation")
	}
	if counts["CHUNK_TYPE_TOOL_USE_START"] == 0 {
		log.Fatalf("FAIL: no ChunkToolUseStart chunks observed on the wire")
	}
	if counts["CHUNK_TYPE_TOOL_RESULT"] == 0 {
		log.Fatalf("FAIL: no ChunkToolResult chunks observed on the wire")
	}
	fmt.Printf("\n✓ end-to-end loop verified\n")
}

func trim(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
