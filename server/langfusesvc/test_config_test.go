package langfusesvc

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/testutil"
)

// TestTestLangfuseConfig_ReportsTheHostsAnswer: the test button answers
// with what the host said, so a host that isn't Langfuse (404) or a
// rejected key pair (401) reads as a failure, and only a 2xx as success.
func TestTestLangfuseConfig_ReportsTheHostsAnswer(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name    string
		status  int
		wantOK  bool
		wantErr string
	}{
		{"accepted", http.StatusOK, true, ""},
		{"multi-status", http.StatusMultiStatus, true, ""},
		{"not langfuse", http.StatusNotFound, false, "404"},
		{"bad keys", http.StatusUnauthorized, false, "401"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var hits atomic.Int32
			var gotAuth atomic.Bool
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/api/public/ingestion" {
					hits.Add(1)
					if u, p, ok := r.BasicAuth(); ok && u == "pk" && p == "sk" {
						gotAuth.Store(true)
					}
				}
				w.WriteHeader(tc.status)
			}))
			defer srv.Close()

			q := store.New(testutil.Pool(t))
			svc := NewService(q, crypto.Nop{}, nil, slog.Default())
			svc.probeClient = srv.Client()
			user := mustUser(t, q)
			host, pub, sec, on := srv.URL, "pk", "sk", true
			if _, err := svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&psmithv1.UpdateLangfuseConfigRequest{
				Host: &host, PublicKey: &pub, SecretKey: &sec, Enabled: &on,
			})); err != nil {
				t.Fatalf("Update: %v", err)
			}

			resp, err := svc.TestLangfuseConfig(ctxAsUser(user), connect.NewRequest(&psmithv1.TestLangfuseConfigRequest{}))
			if err != nil {
				t.Fatalf("TestLangfuseConfig: %v", err)
			}
			if hits.Load() != 1 || !gotAuth.Load() {
				t.Fatalf("ingestion hits = %d, auth seen = %v; want one authenticated POST", hits.Load(), gotAuth.Load())
			}
			if resp.Msg.Ok != tc.wantOK {
				t.Errorf("ok = %v, want %v (error %q)", resp.Msg.Ok, tc.wantOK, resp.Msg.ErrorMessage)
			}
			if tc.wantErr != "" && !strings.Contains(resp.Msg.ErrorMessage, tc.wantErr) {
				t.Errorf("error = %q, want it to name %q", resp.Msg.ErrorMessage, tc.wantErr)
			}
		})
	}
}

// TestTestLangfuseConfig_UnreachableHostFails: nothing listening is a
// failure too, not a quick "sent".
func TestTestLangfuseConfig_UnreachableHostFails(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.NotFoundHandler())
	dead := srv.URL
	srv.Close()

	q := store.New(testutil.Pool(t))
	svc := NewService(q, crypto.Nop{}, nil, slog.Default())
	user := mustUser(t, q)
	pub, sec, on := "pk", "sk", true
	if _, err := svc.UpdateLangfuseConfig(ctxAsUser(user), connect.NewRequest(&psmithv1.UpdateLangfuseConfigRequest{
		Host: &dead, PublicKey: &pub, SecretKey: &sec, Enabled: &on,
	})); err != nil {
		t.Fatalf("Update: %v", err)
	}
	resp, err := svc.TestLangfuseConfig(ctxAsUser(user), connect.NewRequest(&psmithv1.TestLangfuseConfigRequest{}))
	if err != nil {
		t.Fatalf("TestLangfuseConfig: %v", err)
	}
	if resp.Msg.Ok || resp.Msg.ErrorMessage == "" {
		t.Errorf("ok = %v, error %q; want a failure", resp.Msg.Ok, resp.Msg.ErrorMessage)
	}
}
