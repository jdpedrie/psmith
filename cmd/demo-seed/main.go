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
	"io"
	"log"
	"net/http"
	"strings"
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

// pickResponse routes a prompt to a repro payload. The scroll-debug
// prompts each stress a distinct client behavior:
//
//	"count …"  → numbered words, one per chunk — viewport position is
//	             readable off any screenshot frame (identical filler
//	             text made mid-stream frames indistinguishable and
//	             burned debugging rounds).
//	"wide …"   → unbreakable token + wide code fence + wide table —
//	             the horizontal break-out / margin-loss trigger.
//	"essay …"  → long multi-section markdown — exercises the
//	             follow-then-park path on a response taller than the
//	             viewport.
//	"filler K" → short varied-height markdown, streamed fast — bulk
//	             seeding of long conversations.
//
// Returns the full text, the chunk size (0 = word-per-chunk), and a
// delay override (<0 = use the flag value).
func pickResponse(prompt string) (text string, chunkSize int, delayOverride time.Duration) {
	p := strings.ToLower(prompt)
	switch {
	case strings.Contains(p, "count"):
		var b strings.Builder
		b.WriteString("Counting run for scroll tracing.\n\n")
		for i := 0; i < 400; i++ {
			fmt.Fprintf(&b, "w%03d ", i)
			if i%20 == 19 {
				b.WriteString("\n\n")
			}
		}
		b.WriteString("\nDone counting.")
		return b.String(), 0, -1
	case strings.Contains(p, "wide"):
		var b strings.Builder
		b.WriteString("Wide-content stress test coming up.\n\nFirst an unbreakable inline token:\n\n")
		b.WriteString(strings.Repeat("Wxyz0123", 30))
		b.WriteString("\n\nNow a wide code block:\n\n```text\n")
		for i := 0; i < 8; i++ {
			fmt.Fprintf(&b, "row-%d: %s END\n", i, strings.Repeat("column-data ", 24))
		}
		b.WriteString("```\n\nAnd a wide table:\n\n")
		b.WriteString("| alpha | bravo | charlie | delta | echo | foxtrot | golf | hotel |\n")
		b.WriteString("|---|---|---|---|---|---|---|---|\n")
		for i := 0; i < 4; i++ {
			b.WriteString("| some longer cell content | more cell content here | and again for width | keeps going wider | even wider now | almost there | nearly done | last column |\n")
		}
		b.WriteString("\nIf the margins held through all of that, the clamp works.")
		return b.String(), 24, -1
	case strings.Contains(p, "heavy"):
		// ~800 words of varied markdown per reply — the user's real
		// conversation scale (200 messages × ~800 words) where
		// LazyVStack estimate churn becomes user-visible. Streams
		// fast: these exist to be SEEDED in bulk.
		var b strings.Builder
		n := len(prompt)
		fmt.Fprintf(&b, "## Reply %d\n\n", n)
		for para := 0; para < 8; para++ {
			fmt.Fprintf(&b, "Paragraph %d.%d — ", n, para)
			for s := 0; s < 6; s++ {
				b.WriteString("the quick brown fox jumps over the lazy dog while the estimate machinery realizes rows and refines the content height it previously guessed at. ")
			}
			b.WriteString("\n\n")
		}
		if n%3 == 0 {
			b.WriteString("```go\nfunc measure(rows []Row) int {\n    total := 0\n    for _, r := range rows {\n        total += r.height\n    }\n    return total\n}\n```\n\n")
		}
		if n%4 == 0 {
			b.WriteString("- **A bulleted point** that wraps across a few lines to vary the block structure between replies in the seeded conversation\n- Another item with `inline code` for measurement variety\n\n")
		}
		b.WriteString("That is the end of this reply.")
		return b.String(), 2048, time.Millisecond
	case strings.Contains(p, "bullet"):
		// Mimics real model output shape: long list items with bold
		// leads, inline code, links, and source-wrapped continuation
		// lines — the Mac bullet-truncation report class.
		var b strings.Builder
		b.WriteString("Here are the tradeoffs to weigh:\n\n")
		b.WriteString("- **Latency versus throughput** — batching requests amortizes connection setup and lets the server pipeline work, but every request in the batch waits for the slowest member, so p99 latency degrades exactly when the queue is deepest and users notice it most\n")
		b.WriteString("- **The `staged backfill` approach** keeps the viewport anchored while history mounts in small batches, which bounds the estimate error any single re-solve can observe, at the cost of a short window where scrolling up hits the mounted boundary before the next batch lands\n")
		b.WriteString("- Short one for contrast\n")
		b.WriteString("- **Cache locality** matters more than algorithmic\n  complexity for these row sizes, because the whole working set\n  fits in L2 and the branch predictor learns the access pattern\n  within a few iterations of the inner loop\n")
		b.WriteString("- A final long item written without any inline styling at all so we can tell whether the truncation correlates with formatting spans or applies to any list item that wraps past the second line of rendered text\n")
		b.WriteString("\nThat's the full list.")
		return b.String(), 24, -1
	case strings.Contains(p, "essay"):
		var b strings.Builder
		b.WriteString("# A Long Essay for Scroll Testing\n\n")
		for s := 1; s <= 8; s++ {
			fmt.Fprintf(&b, "## Section %d\n\n", s)
			for para := 0; para < 2; para++ {
				fmt.Fprintf(&b, "Paragraph %d.%d — this is deliberately verbose filler that wraps across several lines so each section contributes real height to the transcript, letting the follow-then-park behavior engage well before the stream finishes. ", s, para)
				b.WriteString("The quick brown fox jumps over the lazy dog while the scroll anchor holds the bottom edge pinned.\n\n")
			}
			if s%2 == 0 {
				fmt.Fprintf(&b, "```go\nfunc section%d() int {\n    total := 0\n    for i := 0; i < %d; i++ {\n        total += i\n    }\n    return total\n}\n```\n\n", s, s*10)
			}
		}
		b.WriteString("That concludes the essay.")
		return b.String(), 24, -1
	case strings.Contains(p, "filler"):
		var b strings.Builder
		n := len(prompt) // cheap deterministic variance per prompt
		fmt.Fprintf(&b, "Reply for %q.\n\n", prompt)
		for para := 0; para <= n%3; para++ {
			b.WriteString("A short paragraph of settled history so the seeded conversation has believable, varied-height rows for scroll testing.\n\n")
		}
		if n%3 == 0 {
			b.WriteString("```sh\necho seeded\n```\n")
		} else if n%5 == 0 {
			b.WriteString("| k | v |\n|---|---|\n| a | 1 |\n| b | 2 |\n")
		} else if n%7 == 0 {
			b.WriteString("> A blockquote for height variance.\n")
		}
		return b.String(), 512, time.Millisecond
	default:
		return canned, 24, -1
	}
}

// lastUserContent digs the newest user message's text out of an
// OpenAI-compatible chat-completions request body. String content
// only — the demo seed never sends multi-part payloads.
func lastUserContent(body []byte) string {
	var req struct {
		Messages []struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return ""
	}
	for i := len(req.Messages) - 1; i >= 0; i-- {
		if req.Messages[i].Role != "user" {
			continue
		}
		var s string
		if err := json.Unmarshal(req.Messages[i].Content, &s); err == nil {
			return s
		}
	}
	return ""
}

func main() {
	addr := flag.String("addr", "http://127.0.0.1:18080", "psmithd base URL")
	user := flag.String("u", "admin", "username")
	pass := flag.String("p", "", "password")
	llmPort := flag.Int("llm-port", 19090, "port for the embedded fake LLM")
	keep := flag.Bool("keep", false, "stay alive serving the fake LLM after seeding")
	chunkDelay := flag.Duration("chunk-delay", 20*time.Millisecond, "delay between streamed chunks (scroll-debug prompts honor this; filler streams fast regardless)")
	xl := flag.Int("xl", 0, "also seed a long conversation with this many turns (scroll testing)")
	heavy := flag.Int("heavy", 0, "also seed a conversation with this many ~800-word replies (real-scale scroll testing)")
	llmOnly := flag.Bool("llm-only", false, "serve the fake LLM only; skip seeding (for re-serving an already-seeded environment)")
	flag.Parse()

	// --- Embedded fake OpenAI-compatible streaming endpoint ---
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
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
		text, chunkSize, delay := pickResponse(lastUserContent(body))
		if delay < 0 {
			delay = *chunkDelay
		}
		for len(text) > 0 {
			n := chunkSize
			if n == 0 {
				// Word-per-chunk: split at the next space so each
				// emitted delta is one readable token.
				if idx := strings.IndexByte(text[1:], ' '); idx >= 0 {
					n = idx + 2
				} else {
					n = len(text)
				}
			}
			if n > len(text) {
				n = len(text)
			}
			emit(text[:n])
			text = text[n:]
			time.Sleep(delay)
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

	if *llmOnly {
		log.Printf("llm-only mode: serving the fake LLM, no seeding (ctrl-c to stop)")
		select {}
	}

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
	var provID string
	var reusing bool
	prov, err := provc.CreateUserModelProvider(ctx, connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{
		Type: "openai-compatible", Label: "Demo LLM", Config: cfg,
	}))
	if err != nil {
		// Repeat runs against the same scratch server hit the unique
		// (user, type, label) constraint — reuse the existing seeded
		// provider so `-heavy` / `-xl` can extend an environment
		// without wiping it.
		list, lerr := provc.ListUserModelProviders(ctx, connect.NewRequest(&psmithv1.ListUserModelProvidersRequest{}))
		if lerr != nil {
			log.Fatalf("create provider: %v (list fallback failed: %v)", err, lerr)
		}
		for _, p := range list.Msg.Providers {
			if p.Label == "Demo LLM" {
				provID = p.Id
				reusing = true
			}
		}
		if provID == "" {
			log.Fatalf("create provider: %v", err)
		}
		log.Printf("reusing existing Demo LLM provider")
	} else {
		provID = prov.Msg.Provider.Id
	}
	ctxWindow := int32(128_000)
	maxOut := int32(8_192)
	if _, err := provc.AddManualModel(ctx, connect.NewRequest(&psmithv1.AddManualModelRequest{
		UserModelProviderId: provID,
		ModelId:             "demo-model-1",
		DisplayName:         "Demo Model",
		ContextWindow:       &ctxWindow,
		MaxOutputTokens:     &maxOut,
		Modalities:          []string{"text"},
	})); err != nil && !reusing {
		log.Fatalf("add model: %v", err)
	}

	// --- Profile (default, with welcome) ---
	system := "You are a concise, helpful assistant used for demo screenshots."
	welcome := "Welcome! I'm the demo profile — ask me anything and I'll stream back a canned but pretty answer."
	var profID string
	if reusing {
		// Profile names aren't unique server-side; on reuse runs,
		// find the existing Demo Assistant instead of stacking
		// duplicates.
		plist, perr := profc.ListProfiles(ctx, connect.NewRequest(&psmithv1.ListProfilesRequest{}))
		if perr == nil {
			for _, p := range plist.Msg.Profiles {
				if p.Name == "Demo Assistant" {
					profID = p.Id
				}
			}
		}
		if profID != "" {
			log.Printf("reusing existing Demo Assistant profile")
		}
	}
	if profID == "" {
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
		profID = profile.Msg.Profile.Id
	}
	if _, err := profc.SetDefaultProfile(ctx, connect.NewRequest(&psmithv1.SetDefaultProfileRequest{
		ProfileId: profID,
	})); err != nil {
		log.Printf("set default profile: %v (continuing)", err)
	}

	// --- Conversations with real streamed turns ---
	// Skipped on reuse runs: they exist from the first seeding, and
	// re-seeding them just clutters the sidebar.
	prompts := []struct{ title, ask string }{}
	if !reusing {
		prompts = []struct{ title, ask string }{
			{"Architecture tour", "Give me a quick tour of how this app works."},
			{"Branching demo", "How do conversation forks work?"},
			{"Markdown showcase", "Show me some formatted output."},
		}
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

	// --- Optional heavy conversation: real-scale rows ---
	if *heavy > 0 {
		title := fmt.Sprintf("Scroll Heavy — %d × 800w", *heavy)
		conv, err := convc.CreateConversation(ctx, connect.NewRequest(&psmithv1.CreateConversationRequest{
			ProfileId: profID, Title: &title,
		}))
		if err != nil {
			log.Fatalf("create heavy conversation: %v", err)
		}
		streamc := psmithv1connect.NewStreamsServiceClient(hc, *addr, auth)
		for i := 0; i < *heavy; i++ {
			ask := fmt.Sprintf("heavy filler %d — %s", i, strings.Repeat("q", i%7))
			send, err := convc.SendMessage(ctx, connect.NewRequest(&psmithv1.SendMessageRequest{
				ConversationId: conv.Msg.Conversation.Id,
				Content:        ask,
			}))
			if err != nil {
				log.Fatalf("heavy send %d: %v", i, err)
			}
			runID := send.Msg.StreamRun.Id
			deadline := time.Now().Add(60 * time.Second)
			for time.Now().Before(deadline) {
				got, err := streamc.GetStreamRun(ctx, connect.NewRequest(&psmithv1.GetStreamRunRequest{StreamRunId: runID}))
				if err == nil && got.Msg.StreamRun.Status != psmithv1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING {
					break
				}
				time.Sleep(50 * time.Millisecond)
			}
			if (i+1)%20 == 0 {
				log.Printf("heavy: %d/%d turns", i+1, *heavy)
			}
		}
		log.Printf("seeded %q", title)
	}

	// --- Optional long conversation for scroll testing ---
	if *xl > 0 {
		title := fmt.Sprintf("Scroll XL — %d turns", *xl)
		conv, err := convc.CreateConversation(ctx, connect.NewRequest(&psmithv1.CreateConversationRequest{
			ProfileId: profID, Title: &title,
		}))
		if err != nil {
			log.Fatalf("create xl conversation: %v", err)
		}
		streamc := psmithv1connect.NewStreamsServiceClient(hc, *addr, auth)
		for i := 0; i < *xl; i++ {
			ask := fmt.Sprintf("filler %d — %s", i, strings.Repeat("padding ", i%9))
			send, err := convc.SendMessage(ctx, connect.NewRequest(&psmithv1.SendMessageRequest{
				ConversationId: conv.Msg.Conversation.Id,
				Content:        ask,
			}))
			if err != nil {
				log.Fatalf("xl send %d: %v", i, err)
			}
			runID := send.Msg.StreamRun.Id
			deadline := time.Now().Add(30 * time.Second)
			for time.Now().Before(deadline) {
				got, err := streamc.GetStreamRun(ctx, connect.NewRequest(&psmithv1.GetStreamRunRequest{StreamRunId: runID}))
				if err == nil && got.Msg.StreamRun.Status != psmithv1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING {
					break
				}
				time.Sleep(50 * time.Millisecond)
			}
			if (i+1)%20 == 0 {
				log.Printf("xl: %d/%d turns", i+1, *xl)
			}
		}
		log.Printf("seeded %q", title)
	}

	log.Printf("done — provider, model, default profile, and %d conversations seeded", len(prompts))
	if *keep {
		log.Printf("staying alive to serve the fake LLM (ctrl-c to stop)")
		select {}
	}
}
