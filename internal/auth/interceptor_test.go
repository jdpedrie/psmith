package auth

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/gen/psmith/v1/psmithv1connect"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"
)

// captureSvc records the context seen by handlers so tests can assert what
// the interceptor attached.
type captureSvc struct {
	psmithv1connect.UnimplementedAuthServiceHandler
	got context.Context
}

func (c *captureSvc) WhoAmI(ctx context.Context, _ *connect.Request[psmithv1.WhoAmIRequest]) (*connect.Response[psmithv1.WhoAmIResponse], error) {
	c.got = ctx
	return connect.NewResponse(&psmithv1.WhoAmIResponse{}), nil
}

func (c *captureSvc) Login(ctx context.Context, _ *connect.Request[psmithv1.LoginRequest]) (*connect.Response[psmithv1.LoginResponse], error) {
	c.got = ctx
	return connect.NewResponse(&psmithv1.LoginResponse{SessionToken: "fake"}), nil
}

func newInterceptedServer(t *testing.T) (*captureSvc, *store.Queries, psmithv1connect.AuthServiceClient) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	capture := &captureSvc{}
	interceptor := NewInterceptor(q, psmithv1connect.AuthServiceLoginProcedure)
	mux := http.NewServeMux()
	mux.Handle(psmithv1connect.NewAuthServiceHandler(capture, connect.WithInterceptors(interceptor)))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	client := psmithv1connect.NewAuthServiceClient(srv.Client(), srv.URL)
	return capture, q, client
}

// loginAndGetToken establishes a real session row (created via the Service)
// and returns the bearer token.
func loginAndGetToken(t *testing.T, q *store.Queries, username, password string) string {
	t.Helper()
	mustCreateUser(t, q, username, password, false)
	svc := NewService(q)
	resp, err := svc.Login(context.Background(), connect.NewRequest(&psmithv1.LoginRequest{
		Username: username, Password: password,
	}))
	if err != nil {
		t.Fatalf("seed Login: %v", err)
	}
	return resp.Msg.SessionToken
}

func TestInterceptor_NoToken_Rejects(t *testing.T) {
	t.Parallel()
	_, _, client := newInterceptedServer(t)

	_, err := client.WhoAmI(context.Background(), connect.NewRequest(&psmithv1.WhoAmIRequest{}))
	var ce *connect.Error
	if !errors.As(err, &ce) {
		t.Fatalf("expected *connect.Error, got %T (%v)", err, err)
	}
	if ce.Code() != connect.CodeUnauthenticated {
		t.Errorf("got code %v want unauthenticated", ce.Code())
	}
}

func TestInterceptor_EmptyBearer_Rejects(t *testing.T) {
	t.Parallel()
	_, _, client := newInterceptedServer(t)

	req := connect.NewRequest(&psmithv1.WhoAmIRequest{})
	req.Header().Set("Authorization", "Bearer ")
	_, err := client.WhoAmI(context.Background(), req)
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeUnauthenticated {
		t.Errorf("expected unauthenticated, got %v", err)
	}
}

func TestInterceptor_InvalidToken_Rejects(t *testing.T) {
	t.Parallel()
	_, _, client := newInterceptedServer(t)

	req := connect.NewRequest(&psmithv1.WhoAmIRequest{})
	req.Header().Set("Authorization", "Bearer not-a-real-token")
	_, err := client.WhoAmI(context.Background(), req)
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeUnauthenticated {
		t.Errorf("expected unauthenticated, got %v", err)
	}
}

func TestInterceptor_ValidToken_AttachesUser(t *testing.T) {
	t.Parallel()
	capture, q, client := newInterceptedServer(t)
	token := loginAndGetToken(t, q, "alice", "x")

	req := connect.NewRequest(&psmithv1.WhoAmIRequest{})
	req.Header().Set("Authorization", "Bearer "+token)
	if _, err := client.WhoAmI(context.Background(), req); err != nil {
		t.Fatalf("WhoAmI: %v", err)
	}

	user, ok := FromContext(capture.got)
	if !ok {
		t.Fatal("interceptor did not attach user to context")
	}
	if user.Username != "alice" {
		t.Errorf("got username %q want alice", user.Username)
	}
}

func TestInterceptor_ValidToken_TouchesSession(t *testing.T) {
	t.Parallel()
	_, q, client := newInterceptedServer(t)
	token := loginAndGetToken(t, q, "alice", "x")

	row, err := q.GetSessionWithUser(context.Background(), hashToken(token))
	if err != nil {
		t.Fatalf("seed lookup: %v", err)
	}
	originalLastUsed := row.LastUsedAt

	// Wait a hair so the timestamp can differ, then call.
	req := connect.NewRequest(&psmithv1.WhoAmIRequest{})
	req.Header().Set("Authorization", "Bearer "+token)
	if _, err := client.WhoAmI(context.Background(), req); err != nil {
		t.Fatalf("WhoAmI: %v", err)
	}

	row2, err := q.GetSessionWithUser(context.Background(), hashToken(token))
	if err != nil {
		t.Fatalf("post lookup: %v", err)
	}
	if !row2.LastUsedAt.After(originalLastUsed) {
		t.Errorf("last_used_at not advanced: was %v, now %v", originalLastUsed, row2.LastUsedAt)
	}
}

func TestInterceptor_AllowlistedProcedure_PassesWithoutToken(t *testing.T) {
	t.Parallel()
	_, _, client := newInterceptedServer(t)

	// Login is on the allowlist — should not be rejected for missing auth.
	// (The captureSvc.Login stub doesn't require valid credentials.)
	resp, err := client.Login(context.Background(), connect.NewRequest(&psmithv1.LoginRequest{
		Username: "anyone", Password: "anything",
	}))
	if err != nil {
		t.Fatalf("Login should pass through: %v", err)
	}
	if resp.Msg.SessionToken == "" {
		t.Error("expected stub to return a token")
	}
}

func TestInterceptor_ExpiredSession_Rejects(t *testing.T) {
	t.Parallel()
	_, q, client := newInterceptedServer(t)
	user := mustCreateUser(t, q, "alice", "x", false)

	// Create a session row whose expires_at is already in the past.
	rawToken := "expired-token-raw"
	if err := q.CreateSession(context.Background(), store.CreateSessionParams{
		TokenHash: hashToken(rawToken),
		UserID:    user.ID,
		ExpiresAt: time.Now().Add(-time.Hour),
	}); err != nil {
		t.Fatalf("CreateSession: %v", err)
	}

	req := connect.NewRequest(&psmithv1.WhoAmIRequest{})
	req.Header().Set("Authorization", "Bearer "+rawToken)
	_, err := client.WhoAmI(context.Background(), req)
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeUnauthenticated {
		t.Errorf("expected unauthenticated for expired session, got %v", err)
	}
}
