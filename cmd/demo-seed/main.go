// demo-seed stands up a believable demo environment against a running
// psmithd: an embedded fake OpenAI-compatible LLM (streaming canned
// markdown), a provider + manual model pointed at it, a default
// profile with a welcome message, and a few conversations with real
// streamed turns. Built for visual verification of the clients
// without spending provider money; also handy for screenshots.
//
// Usage:
//
//	go run ./cmd/demo-seed -addr http://127.0.0.1:18080 -u admin -p secret [-llm-port 19090] [-keep]
//
// With -keep the process stays alive serving the fake LLM so the
// seeded conversations can continue interactively; without it the
// program exits after seeding (the fake LLM dies with it).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/gen/psmith/v1/psmithv1connect"
)

const canned = `Here's a quick rundown of what you asked about.

## The short version

Psmith keeps **credentials on the server** and lets every client — Mac, iOS, web — share the same conversations, profiles, and providers.

- Conversations fork like git branches
- Compaction summarizes long history into a fresh context
- Plugins shape every turn without touching the model

` + "```go\nfunc main() {\n    fmt.Println(\"hello from the demo seed\")\n}\n```" + `

That's the tour. Ask me anything else.`

func main() {
	addr := flag.String("addr", "http://127.0.0.1:18080", "psmithd base URL")
	user := flag.String("u", "admin", "username")
	pass := flag.String("p", "", "password")
	llmPort := flag.Int("llm-port", 19090, "port for the embedded fake LLM")
	keep := flag.Bool("keep", false, "stay alive serving the fake LLM after seeding")
	flag.Parse()

	// --- Embedded fake OpenAI-compatible streaming endpoint ---
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fl, _ := w.(http.Flusher)
		emit := func(delta string) {
			chunk := map[string]any{
				"id": "demo", "object": "chat.completion.chunk",
				"choices": []map[string]any{{"index": 0, "delta": map[string]any{"content": delta}}},
			}
			b, _ := json.Marshal(chunk)
			fmt.Fprintf(w, "data: %s\n\n", b)
			if fl != nil {
				fl.Flush()
			}
		}
		// Stream in small pieces so clients exercise their live path.
		text := canned
		for len(text) > 0 {
			n := 24
			if n > len(text) {
				n = len(text)
			}
			emit(text[:n])
			text = text[n:]
			time.Sleep(20 * time.Millisecond)
		}
		done := map[string]any{
			"id": "demo", "object": "chat.completion.chunk",
			"choices": []map[string]any{{"index": 0, "delta": map[string]any{}, "finish_reason": "stop"}},
			"usage":   map[string]any{"prompt_tokens": 420, "completion_tokens": 128},
		}
		b, _ := json.Marshal(done)
		fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n", b)
		if fl != nil {
			fl.Flush()
		}
	})
	llmAddr := fmt.Sprintf("127.0.0.1:%d", *llmPort)
	go func() {
		log.Printf("fake LLM listening on http://%s", llmAddr)
		if err := http.ListenAndServe(llmAddr, mux); err != nil {
			log.Fatalf("fake llm: %v", err)
		}
	}()

	ctx := context.Background()
	hc := http.DefaultClient

	// --- Login ---
	authc := psmithv1connect.NewAuthServiceClient(hc, *addr)
	login, err := authc.Login(ctx, connect.NewRequest(&psmithv1.LoginRequest{Username: *user, Password: *pass}))
	if err != nil {
		log.Fatalf("login: %v", err)
	}
	token := login.Msg.SessionToken
	auth := connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			req.Header().Set("Authorization", "Bearer "+token)
			return next(ctx, req)
		}
	}))

	provc := psmithv1connect.NewModelProvidersServiceClient(hc, *addr, auth)
	profc := psmithv1connect.NewProfilesServiceClient(hc, *addr, auth)
	convc := psmithv1connect.NewConversationsServiceClient(hc, *addr, auth)

	// --- Provider + manual model ---
	cfg, _ := json.Marshal(map[string]string{
		"base_url": "http://" + llmAddr + "/v1",
		"api_key":  "demo-key",
	})
	prov, err := provc.CreateUserModelProvider(ctx, connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{
		Type: "openai-compatible", Label: "Demo LLM", Config: cfg,
	}))
	if err != nil {
		log.Fatalf("create provider: %v", err)
	}
	provID := prov.Msg.Provider.Id
	ctxWindow := int32(128_000)
	maxOut := int32(8_192)
	model, err := provc.AddManualModel(ctx, connect.NewRequest(&psmithv1.AddManualModelRequest{
		UserModelProviderId: provID,
		ModelId:             "demo-model-1",
		DisplayName:         "Demo Model",
		ContextWindow:       &ctxWindow,
		MaxOutputTokens:     &maxOut,
		Modalities:          []string{"text"},
	}))
	if err != nil {
		log.Fatalf("add model: %v", err)
	}
	_ = model

	// --- Profile (default, with welcome) ---
	system := "You are a concise, helpful assistant used for demo screenshots."
	welcome := "Welcome! I'm the demo profile — ask me anything and I'll stream back a canned but pretty answer."
	profile, err := profc.CreateProfile(ctx, connect.NewRequest(&psmithv1.CreateProfileRequest{
		Name:           "Demo Assistant",
		SystemMessage:  &system,
		WelcomeMessage: &welcome,
		DefaultSettings: &psmithv1.ProfileDefaults{
			DefaultProviderId: &provID,
			DefaultModelId:    func() *string { s := "demo-model-1"; return &s }(),
		},
	}))
	if err != nil {
		log.Fatalf("create profile: %v", err)
	}
	profID := profile.Msg.Profile.Id
	if _, err := profc.SetDefaultProfile(ctx, connect.NewRequest(&psmithv1.SetDefaultProfileRequest{
		ProfileId: profID,
	})); err != nil {
		log.Printf("set default profile: %v (continuing)", err)
	}

	// --- Conversations with real streamed turns ---
	prompts := []struct{ title, ask string }{
		{"Architecture tour", "Give me a quick tour of how this app works."},
		{"Branching demo", "How do conversation forks work?"},
		{"Markdown showcase", "Show me some formatted output."},
	}
	for _, p := range prompts {
		title := p.title
		conv, err := convc.CreateConversation(ctx, connect.NewRequest(&psmithv1.CreateConversationRequest{
			ProfileId: profID, Title: &title,
		}))
		if err != nil {
			log.Fatalf("create conversation: %v", err)
		}
		send, err := convc.SendMessage(ctx, connect.NewRequest(&psmithv1.SendMessageRequest{
			ConversationId: conv.Msg.Conversation.Id,
			Content:        p.ask,
		}))
		if err != nil {
			log.Fatalf("send: %v", err)
		}
		// Wait for the run to finish so the seeded rows are settled.
		runID := send.Msg.StreamRun.Id
		streamc := psmithv1connect.NewStreamsServiceClient(hc, *addr, auth)
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			got, err := streamc.GetStreamRun(ctx, connect.NewRequest(&psmithv1.GetStreamRunRequest{StreamRunId: runID}))
			if err == nil && got.Msg.StreamRun.Status != psmithv1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING {
				break
			}
			time.Sleep(300 * time.Millisecond)
		}
		log.Printf("seeded conversation %q", p.title)
	}

	log.Printf("done — provider, model, default profile, and %d conversations seeded", len(prompts))
	if *keep {
		log.Printf("staying alive to serve the fake LLM (ctrl-c to stop)")
		select {}
	}
}
