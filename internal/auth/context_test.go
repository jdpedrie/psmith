package auth

import (
	"context"
	"testing"

	"github.com/google/uuid"
)

func TestContextWithUser_RoundTrip(t *testing.T) {
	id := uuid.New()
	u := User{ID: id, Username: "alice", IsAdmin: true}

	ctx := contextWithUser(context.Background(), u)
	got, ok := FromContext(ctx)
	if !ok {
		t.Fatal("FromContext returned ok=false")
	}
	if got.ID != id || got.Username != "alice" || !got.IsAdmin {
		t.Errorf("got %+v want %+v", got, u)
	}
}

func TestFromContext_Empty(t *testing.T) {
	if _, ok := FromContext(context.Background()); ok {
		t.Error("expected ok=false on bare context")
	}
}

func TestMustFromContext_Panics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic")
		}
	}()
	MustFromContext(context.Background())
}

func TestMustFromContext_Returns(t *testing.T) {
	u := User{ID: uuid.New(), Username: "bob"}
	ctx := contextWithUser(context.Background(), u)
	got := MustFromContext(ctx)
	if got.ID != u.ID || got.Username != u.Username {
		t.Errorf("got %+v want %+v", got, u)
	}
}
