package providerkit

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

type fakeQueries struct {
	row store.UserModelProvider
	err error
}

func (f fakeQueries) GetUserModelProvider(_ context.Context, _ uuid.UUID) (store.UserModelProvider, error) {
	return f.row, f.err
}

type statelessDriver struct{ typeName string }

func (d statelessDriver) Type() string                                  { return d.typeName }
func (d statelessDriver) Stateful() bool                                { return false }
func (d statelessDriver) RenderThinkingToText(_ json.RawMessage) string { return "" }
func (d statelessDriver) DiscoverModels(context.Context) ([]providers.Model, error) {
	return nil, nil
}
func (d statelessDriver) Send(context.Context, providers.SendRequest) (<-chan providers.Chunk, error) {
	ch := make(chan providers.Chunk)
	close(ch)
	return ch, nil
}

// statefulDriver satisfies Provider but not StatelessProvider.
type statefulDriver struct{ typeName string }

func (d statefulDriver) Type() string                                  { return d.typeName }
func (d statefulDriver) Stateful() bool                                { return true }
func (d statefulDriver) RenderThinkingToText(_ json.RawMessage) string { return "" }
func (d statefulDriver) DiscoverModels(context.Context) ([]providers.Model, error) {
	return nil, nil
}

func register(t *testing.T, name string, build func() providers.Provider) string {
	t.Helper()
	full := name + "-" + uuid.NewString()[:8]
	providers.Register(full, func(_ providers.Deps, _ json.RawMessage) (providers.Provider, error) {
		return build(), nil
	})
	return full
}

func row(t *testing.T, typeName string, owner uuid.UUID) store.UserModelProvider {
	t.Helper()
	id, _ := uuid.NewV7()
	return store.UserModelProvider{
		ID: id, UserID: owner, Type: typeName, Label: "test",
		Config: []byte(`{"api_key":"x"}`),
	}
}

// The reason this package exists: the ownership check is one line, easy to
// omit, and omitting it lets a caller spend another user's credentials.
func TestOpen_RefusesAProviderTheCallerDoesNotOwn(t *testing.T) {
	t.Parallel()
	owner, other := uuid.New(), uuid.New()
	typeName := register(t, "owned", func() providers.Provider { return statelessDriver{} })
	o := Opener{Queries: fakeQueries{row: row(t, typeName, owner)}}

	if _, _, err := o.Open(context.Background(), uuid.New(), other); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a provider owned by someone else, got %v", err)
	}
	if _, _, err := o.Open(context.Background(), uuid.New(), owner); err != nil {
		t.Fatalf("the owner should be allowed through: %v", err)
	}
}

// "No such provider" and "not yours" are one error on purpose: distinguishing
// them tells an attacker which ids exist.
func TestLoad_MissingAndForbiddenAreIndistinguishable(t *testing.T) {
	t.Parallel()
	missing := Opener{Queries: fakeQueries{err: pgx.ErrNoRows}}
	_, mErr := missing.Load(context.Background(), uuid.New(), uuid.New())

	typeName := register(t, "forbidden", func() providers.Provider { return statelessDriver{} })
	forbidden := Opener{Queries: fakeQueries{row: row(t, typeName, uuid.New())}}
	_, fErr := forbidden.Load(context.Background(), uuid.New(), uuid.New())

	if mErr == nil || fErr == nil {
		t.Fatal("both cases should error")
	}
	if mErr.Error() != fErr.Error() {
		t.Errorf("errors must be indistinguishable:\n missing:   %v\n forbidden: %v", mErr, fErr)
	}
}

// uuid.Nil skips the check, for callers that established ownership already.
func TestOpen_NilOwnerSkipsTheCheck(t *testing.T) {
	t.Parallel()
	typeName := register(t, "nilowner", func() providers.Provider { return statelessDriver{} })
	o := Opener{Queries: fakeQueries{row: row(t, typeName, uuid.New())}}
	if _, _, err := o.Open(context.Background(), uuid.New(), uuid.Nil); err != nil {
		t.Fatalf("uuid.Nil should bypass the ownership check: %v", err)
	}
}

func TestOpenStateless_RejectsAStatefulDriver(t *testing.T) {
	t.Parallel()
	owner := uuid.New()
	typeName := register(t, "stateful", func() providers.Provider { return statefulDriver{} })
	o := Opener{Queries: fakeQueries{row: row(t, typeName, owner)}}

	_, _, err := o.OpenStateless(context.Background(), uuid.New(), owner)
	if !errors.Is(err, ErrNotStateless) {
		t.Fatalf("expected ErrNotStateless, got %v", err)
	}
	// The type is named, because "not stateless" alone does not tell an
	// operator which provider to look at.
	if err == nil || !contains(err.Error(), typeName) {
		t.Errorf("error should name the driver type: %v", err)
	}
}

// An empty config must normalize, since drivers unmarshal it unconditionally.
func TestConfig_EmptyBecomesAnObject(t *testing.T) {
	t.Parallel()
	o := Opener{}
	got, err := o.Config(store.UserModelProvider{})
	if err != nil {
		t.Fatalf("Config: %v", err)
	}
	if string(got) != "{}" {
		t.Errorf("empty config should normalize to {}, got %q", got)
	}
}

func contains(h, n string) bool {
	for i := 0; i+len(n) <= len(h); i++ {
		if h[i:i+len(n)] == n {
			return true
		}
	}
	return false
}
