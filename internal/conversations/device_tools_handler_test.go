package conversations

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/reeve/internal/devicetools"
	"github.com/jdpedrie/reeve/internal/store"
)

// handlerFixture mounts the DeviceToolsHandler against an httptest
// server with a real session row so the auth + ownership gates run
// for real.
type handlerFixture struct {
	svc      *Service
	queries  *store.Queries
	user     store.User
	conv     store.Conversation
	httpURL  string
	bearer   string
	closeAll func()
}

func newHandlerFixture(t *testing.T) handlerFixture {
	t.Helper()
	svc, q, _ := newFullSvc(t)
	user, conv, _ := seedUserAndConversation(t, q)

	raw := "device-tool-test-" + uuid.NewString()[:8]
	if err := q.CreateSession(context.Background(), store.CreateSessionParams{
		TokenHash: hashTokenForHandlerTest(raw),
		UserID:    user.ID,
		ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("CreateSession: %v", err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Map the test URL to the routed handler — strip the
		// "/conversations/{id}/device-tools/{call_id}/respond"
		// path and pass through. httptest.NewServer doesn't run a
		// mux, so we wire the path params manually.
		mux := http.NewServeMux()
		mux.Handle("POST /conversations/{id}/device-tools/{call_id}/respond",
			svc.DeviceToolsHandler())
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)

	return handlerFixture{
		svc: svc, queries: q,
		user: user, conv: conv,
		httpURL: srv.URL, bearer: raw,
		closeAll: srv.Close,
	}
}

func TestDeviceToolsHandler_HappyPathDeliversToWaiter(t *testing.T) {
	t.Parallel()
	f := newHandlerFixture(t)

	// Register a pending call directly with the broker so the
	// HTTP endpoint has a slot to drain.
	type result struct {
		out json.RawMessage
		err error
	}
	done := make(chan result, 1)
	var emittedID uuid.UUID
	var mu sync.Mutex
	go func() {
		out, err := f.svc.deviceToolBroker.Invoke(
			context.Background(), f.conv.ID, "calendar_list_events",
			json.RawMessage(`{}`), 5*time.Second,
			func(req devicetools.Request) {
				mu.Lock()
				emittedID = req.CallID
				mu.Unlock()
			})
		done <- result{out, err}
	}()

	// Wait for the broker to register + emit.
	deadline := time.Now().Add(2 * time.Second)
	for {
		mu.Lock()
		id := emittedID
		mu.Unlock()
		if id != uuid.Nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("broker never emitted")
		}
		time.Sleep(2 * time.Millisecond)
	}

	// POST a response. The handler should auth, look up the
	// conversation, deliver to broker, return 204.
	url := f.httpURL + "/conversations/" + f.conv.ID.String() +
		"/device-tools/" + emittedID.String() + "/respond"
	body := `{"output":{"events":["lunch"]}}`
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+f.bearer)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		b, _ := io.ReadAll(resp.Body)
		t.Errorf("status=%d body=%s", resp.StatusCode, string(b))
	}

	// Broker waiter should unblock with the structured output.
	r := <-done
	if r.err != nil {
		t.Fatalf("waiter err=%v", r.err)
	}
	var got map[string]any
	_ = json.Unmarshal(r.out, &got)
	events, _ := got["events"].([]any)
	if len(events) != 1 || events[0] != "lunch" {
		t.Errorf("output=%v", got)
	}
}

func TestDeviceToolsHandler_AuthRejected(t *testing.T) {
	t.Parallel()
	f := newHandlerFixture(t)

	url := f.httpURL + "/conversations/" + f.conv.ID.String() +
		"/device-tools/" + uuid.New().String() + "/respond"
	// Missing Authorization header.
	resp, err := http.Post(url, "application/json", strings.NewReader(`{"output":{}}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status=%d want 401", resp.StatusCode)
	}
}

func TestDeviceToolsHandler_CrossUserReturns404(t *testing.T) {
	t.Parallel()
	f := newHandlerFixture(t)

	// Another user with a valid session but the URL points at the
	// first user's conversation. Should look like "not found"
	// rather than leaking conversation-ownership info.
	otherUser, _, _ := seedUserAndConversation(t, f.queries)
	otherRaw := "cross-user-" + uuid.NewString()[:8]
	if err := f.queries.CreateSession(context.Background(), store.CreateSessionParams{
		TokenHash: hashTokenForHandlerTest(otherRaw),
		UserID:    otherUser.ID,
		ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("CreateSession other: %v", err)
	}

	url := f.httpURL + "/conversations/" + f.conv.ID.String() +
		"/device-tools/" + uuid.New().String() + "/respond"
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(`{"output":{}}`))
	req.Header.Set("Authorization", "Bearer "+otherRaw)
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("status=%d want 404", resp.StatusCode)
	}
}

func TestDeviceToolsHandler_UnknownCallReturns404(t *testing.T) {
	t.Parallel()
	f := newHandlerFixture(t)

	url := f.httpURL + "/conversations/" + f.conv.ID.String() +
		"/device-tools/" + uuid.New().String() + "/respond"
	req, _ := http.NewRequest(http.MethodPost, url,
		strings.NewReader(`{"output":{"x":1}}`))
	req.Header.Set("Authorization", "Bearer "+f.bearer)
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("status=%d want 404", resp.StatusCode)
	}
}

func TestDeviceToolsHandler_EmptyResponseRejected(t *testing.T) {
	t.Parallel()
	f := newHandlerFixture(t)

	url := f.httpURL + "/conversations/" + f.conv.ID.String() +
		"/device-tools/" + uuid.New().String() + "/respond"
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader([]byte(`{}`)))
	req.Header.Set("Authorization", "Bearer "+f.bearer)
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("status=%d want 400", resp.StatusCode)
	}
}

func TestDeviceToolsHandler_BadMethodReturns405(t *testing.T) {
	t.Parallel()
	f := newHandlerFixture(t)
	url := f.httpURL + "/conversations/" + f.conv.ID.String() +
		"/device-tools/" + uuid.New().String() + "/respond"
	// http.NewServeMux routes by method; GET to a POST-only path
	// gets 405 from the mux. (The handler's own method check is
	// defence-in-depth in case it's mounted differently.)
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer "+f.bearer)
	resp, _ := http.DefaultClient.Do(req)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("status=%d want 405", resp.StatusCode)
	}
}

func hashTokenForHandlerTest(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}
