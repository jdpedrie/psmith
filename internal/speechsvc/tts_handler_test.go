package speechsvc

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
)

// seedSpokenMessage creates user → profile → conversation → context →
// assistant message directly via queries, returning the message id and
// a live bearer token for the user.
func seedSpokenMessage(t *testing.T, q *store.Queries, username, content string) (msgID uuid.UUID, token string, user store.User) {
	t.Helper()
	ctx := context.Background()
	user = mustCreateUser(t, q, username)

	raw := "tok-" + username
	h := sha256.Sum256([]byte(raw))
	if err := q.CreateSession(ctx, store.CreateSessionParams{
		TokenHash: hex.EncodeToString(h[:]),
		UserID:    user.ID,
		ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("session: %v", err)
	}

	pid, _ := uuid.NewV7()
	prof, err := q.CreateProfile(ctx, store.CreateProfileParams{ID: pid, UserID: user.ID, Name: "p"})
	if err != nil {
		t.Fatalf("profile: %v", err)
	}
	cvid, _ := uuid.NewV7()
	conv, err := q.CreateConversation(ctx, store.CreateConversationParams{ID: cvid, UserID: user.ID, ProfileID: prof.ID})
	if err != nil {
		t.Fatalf("conversation: %v", err)
	}
	cxid, _ := uuid.NewV7()
	cx, err := q.CreateContext(ctx, store.CreateContextParams{ID: cxid, ConversationID: conv.ID, ContextActivationTime: time.Now()})
	if err != nil {
		t.Fatalf("context: %v", err)
	}
	mid, _ := uuid.NewV7()
	msg, err := q.CreateMessage(ctx, store.CreateMessageParams{
		ID: mid, ContextID: cx.ID, Role: "assistant", Content: content,
	})
	if err != nil {
		t.Fatalf("message: %v", err)
	}
	return msg.ID, raw, user
}

func postTTS(t *testing.T, handler http.HandlerFunc, token, messageID string) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"message_id": messageID})
	req := httptest.NewRequest(http.MethodPost, "/tts", strings.NewReader(string(body)))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler(rec, req)
	return rec
}

func TestTTSHandler_StreamsAudioAndRecordsCost(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)

	audio := make([]byte, 9600)
	var providerCalls int
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerCalls++
		_, _ = w.Write(audio)
	}))
	defer fake.Close()

	msgID, token, user := seedSpokenMessage(t, q, "alice",
		"Here is the first full sentence of the reply for synthesis. And a second one follows to force two segments.\n\n```go\nsecret()\n```")

	// grok via provider_ref, pointed at the fake endpoint.
	prov := mustCreateProvider(t, q, cipher, user.ID, `{"api_key":"xai-shared"}`)
	if _, err := svc.UpdateSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Kind: strPtr("grok"), BaseUrl: strPtr(fake.URL), ProviderRef: strPtr(prov.ID.String()),
	})); err != nil {
		t.Fatalf("config: %v", err)
	}

	rec := postTTS(t, svc.TTSHandler(), token, msgID.String())
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "audio/pcm" {
		t.Errorf("content type %q", ct)
	}
	if rec.Header().Get("X-Speech-Normalizer") == "" || rec.Header().Get("X-Speech-Sample-Rate") != "24000" {
		t.Errorf("cache-key headers missing: %v", rec.Header())
	}
	got, _ := io.ReadAll(rec.Body)
	if len(got) != providerCalls*len(audio) || providerCalls < 2 {
		t.Errorf("audio: %d bytes over %d provider calls (want >=2 segments)", len(got), providerCalls)
	}

	// Cost attributed to the referenced provider via the totals view
	// the cost screen reads.
	totals, err := q.ListProviderCostTotals(context.Background(), store.ListProviderCostTotalsParams{UserID: user.ID})
	if err != nil {
		t.Fatalf("cost totals: %v", err)
	}
	foundCost := false
	for _, tr := range totals {
		if tr.ProviderID == prov.ID {
			f, _ := tr.TotalCostUsd.Float64Value()
			if f.Float64 > 0 {
				foundCost = true
			}
		}
	}
	if !foundCost {
		t.Errorf("want a positive cost total for the referenced provider, got %+v", totals)
	}
}

func TestTTSHandler_AuthAndOwnership(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher

	msgID, _, _ := seedSpokenMessage(t, q, "alice", "Some content that is long enough to speak.")
	_, bobToken, _ := seedSpokenMessage(t, q, "bob", "Bob's own message content, long enough to speak.")

	// No token.
	if rec := postTTS(t, svc.TTSHandler(), "", msgID.String()); rec.Code != http.StatusUnauthorized {
		t.Errorf("no token: %d", rec.Code)
	}
	// Bob asking for Alice's message: masked as not found.
	if rec := postTTS(t, svc.TTSHandler(), bobToken, msgID.String()); rec.Code != http.StatusNotFound {
		t.Errorf("cross-user: %d", rec.Code)
	}
	// Garbage id.
	if rec := postTTS(t, svc.TTSHandler(), bobToken, "not-a-uuid"); rec.Code != http.StatusBadRequest {
		t.Errorf("bad id: %d", rec.Code)
	}
}

func TestTTSHandler_AppleLocalRefused(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher
	msgID, token, _ := seedSpokenMessage(t, q, "alice", "Content long enough to be spoken aloud today.")

	// No config row = apple_local default: server refuses, device speaks.
	rec := postTTS(t, svc.TTSHandler(), token, msgID.String())
	if rec.Code != http.StatusPreconditionFailed {
		t.Errorf("apple_local: want 412, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestTTSHandler_ProviderFailureBeforeAudio(t *testing.T) {
	t.Parallel()
	svc, q, cipher := newTestSvc(t)
	_ = cipher

	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":"voice service down"}`))
	}))
	defer fake.Close()

	msgID, token, user := seedSpokenMessage(t, q, "alice", "Content long enough to be spoken aloud today.")
	if _, err := svc.UpdateSpeechConfig(ctxAs(user), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{
		Kind: strPtr("openai-compatible"), BaseUrl: strPtr(fake.URL),
	})); err != nil {
		t.Fatalf("config: %v", err)
	}

	rec := postTTS(t, svc.TTSHandler(), token, msgID.String())
	if rec.Code != http.StatusBadGateway {
		t.Errorf("provider failure: want 502, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "voice service down") {
		t.Errorf("provider error should surface: %s", rec.Body.String())
	}
}
