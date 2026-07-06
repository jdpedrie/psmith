package web

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/conversations"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/stream"
	"github.com/jdpedrie/psmith/internal/testutil"
)

func TestParseElicitFields(t *testing.T) {
	t.Parallel()
	schema := json.RawMessage(`{
		"type": "object",
		"properties": {
			"api_key": {"type": "string", "format": "password", "title": "API Key"},
			"count":   {"type": "integer"},
			"enabled": {"type": "boolean"},
			"name":    {"type": "string"}
		}
	}`)
	fields := parseElicitFields(schema)
	// Sorted by name: api_key, count, enabled, name.
	want := []elicitField{
		{Name: "api_key", Label: "API Key", Type: "password"},
		{Name: "count", Label: "count", Type: "number"},
		{Name: "enabled", Label: "enabled", Type: "checkbox"},
		{Name: "name", Label: "name", Type: "text"},
	}
	if len(fields) != len(want) {
		t.Fatalf("got %d fields, want %d: %+v", len(fields), len(want), fields)
	}
	for i, f := range fields {
		if f != want[i] {
			t.Errorf("field %d = %+v, want %+v", i, f, want[i])
		}
	}
}

func TestElicitFormRender(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	err := elicitForm("conv1", "eid1", "Enter your key", []elicitField{
		{Name: "api_key", Label: "API Key", Type: "password"},
	}).Render(context.Background(), &buf)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	out := buf.String()
	for _, want := range []string{
		"Enter your key",
		`name="field_api_key"`,
		`type="password"`,
		`hx-post="/c/conv1/elicit/eid1"`,
		`name="action" value="accept"`,
		`name="action" value="decline"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("elicit form missing %q\ngot: %s", want, out)
		}
	}
}

// TestElicitRespond_OwnershipNotFound proves the respond handler refuses a
// conversation the caller doesn't own (no panic, clean 404).
func TestElicitRespond_OwnershipNotFound(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Supervisor: sup, Logger: slog.Default()})

	userCtx, _ := seedUserCtx(t, q)
	cid, eid := uuid.New().String(), uuid.New().String()
	req := httptest.NewRequest("POST", "/c/"+cid+"/elicit/"+eid+"?action=decline", nil).WithContext(userCtx)
	req.SetPathValue("id", cid)
	req.SetPathValue("eid", eid)
	rec := do(h.handleElicitRespond, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status=%d want 404", rec.Code)
	}
}
