package history

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/internal/storage"
	"github.com/jdpedrie/psmith/internal/store"
)

// Regression: a single missing-from-storage attachment must NOT
// fail the whole Build call. The user reported "build history:
// read attachment <id>: storage: object not found" hard-breaking
// a conversation because one image file was lost. Build now logs
// + skips missing rows and continues with whatever else is in the
// chain.

func TestBuild_AttachmentMissingFromStorage_Skipped(t *testing.T) {
	t.Parallel()
	userID := uuid.New()
	convID := uuid.New()
	ctxID := uuid.New()
	msgID := uuid.New()

	conv := store.Conversation{ID: convID, UserID: userID}
	ctxRow := store.Context{
		ID:                    ctxID,
		ConversationID:        convID,
		ContextActivationTime: time.Now(),
	}
	userMsg := store.Message{
		ID:        msgID,
		ContextID: ctxID,
		Role:      roleUser,
		Content:   "look at this",
		CreatedAt: time.Now(),
	}

	q := &stubQueries{
		activeCtx: ctxRow,
		messages:  []store.Message{userMsg},
		attachments: []store.ListAttachmentsForMessagesRow{
			{
				MessageID: msgID,
				Ordinal:   0,
				FileID:    uuid.New(),
				Kind:      "image",
				RoleHint:  "user_supplied",
				Sha256:    "sha-vanished",
				MimeType:  "image/jpeg",
				SizeBytes: 1024,
			},
		},
	}
	// Storage that always reports the object is missing — simulates
	// the FS being wiped while the DB row still exists.
	store := &stubMissingStorage{}

	out, err := Build(context.Background(), q, Params{
		Conversation:     conv,
		LeafMessageID:    &msgID,
		DestProviderType: "anthropic",
		UserID:           userID,
		Attachments:      store,
		Logger:           slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatalf("Build returned error for missing attachment; expected silent skip: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 wire message, got %d", len(out))
	}
	if len(out[0].Attachments) != 0 {
		t.Errorf("missing attachment should have been skipped; got %d attachments",
			len(out[0].Attachments))
	}
	if out[0].Content != "look at this" {
		t.Errorf("text content should still be on the wire; got %q", out[0].Content)
	}
}

func TestBuild_AttachmentRealIOError_StillFails(t *testing.T) {
	t.Parallel()
	// Non-NotFound storage errors should still fail Build — a disk
	// permission error or a transient backend outage is the kind
	// of problem the caller needs to know about, not silently
	// strip from the wire.
	userID := uuid.New()
	convID := uuid.New()
	ctxID := uuid.New()
	msgID := uuid.New()

	conv := store.Conversation{ID: convID, UserID: userID}
	ctxRow := store.Context{
		ID:                    ctxID,
		ConversationID:        convID,
		ContextActivationTime: time.Now(),
	}
	userMsg := store.Message{
		ID:        msgID,
		ContextID: ctxID,
		Role:      roleUser,
		Content:   "look at this",
		CreatedAt: time.Now(),
	}
	q := &stubQueries{
		activeCtx: ctxRow,
		messages:  []store.Message{userMsg},
		attachments: []store.ListAttachmentsForMessagesRow{
			{
				MessageID: msgID,
				Ordinal:   0,
				FileID:    uuid.New(),
				Sha256:    "sha-disk-fail",
				Kind:      "image",
				RoleHint:  "user_supplied",
				MimeType:  "image/jpeg",
			},
		},
	}
	st := &stubErrorStorage{err: errors.New("disk on fire")}

	_, err := Build(context.Background(), q, Params{
		Conversation:     conv,
		LeafMessageID:    &msgID,
		DestProviderType: "anthropic",
		UserID:           userID,
		Attachments:      st,
	})
	if err == nil {
		t.Fatal("expected non-NotFound storage error to propagate")
	}
}

// --- stubs -----------------------------------------------------------------

type stubQueries struct {
	activeCtx   store.Context
	messages    []store.Message
	attachments []store.ListAttachmentsForMessagesRow
}

func (s *stubQueries) GetActiveContextByConversation(_ context.Context, _ uuid.UUID) (store.Context, error) {
	return s.activeCtx, nil
}
func (s *stubQueries) ListContextLeafIDs(_ context.Context, contextID uuid.UUID) ([]uuid.UUID, error) {
	hasChild := make(map[uuid.UUID]bool, len(s.messages))
	for _, m := range s.messages {
		if m.ParentID != nil {
			hasChild[*m.ParentID] = true
		}
	}
	var out []uuid.UUID
	for _, m := range s.messages {
		if m.ContextID == contextID && !hasChild[m.ID] {
			out = append(out, m.ID)
			if len(out) == 2 {
				break
			}
		}
	}
	return out, nil
}
func (s *stubQueries) ListMessageChainForHistory(_ context.Context, id uuid.UUID) ([]store.ListMessageChainForHistoryRow, error) {
	byID := make(map[uuid.UUID]store.Message, len(s.messages))
	for _, m := range s.messages {
		byID[m.ID] = m
	}
	var leafFirst []store.Message
	cur, ok := byID[id]
	for ok {
		leafFirst = append(leafFirst, cur)
		if cur.ParentID == nil {
			break
		}
		cur, ok = byID[*cur.ParentID]
	}
	out := make([]store.ListMessageChainForHistoryRow, 0, len(leafFirst))
	for i := len(leafFirst) - 1; i >= 0; i-- {
		out = append(out, store.ListMessageChainForHistoryRow{Message: leafFirst[i]})
	}
	return out, nil
}
func (s *stubQueries) ListAttachmentsForMessages(_ context.Context, _ []uuid.UUID) ([]store.ListAttachmentsForMessagesRow, error) {
	return s.attachments, nil
}

type stubMissingStorage struct{}

func (stubMissingStorage) Get(_ context.Context, _ uuid.UUID, _ string) (io.ReadCloser, error) {
	return nil, storage.ErrNotFound
}

type stubErrorStorage struct{ err error }

func (s *stubErrorStorage) Get(_ context.Context, _ uuid.UUID, _ string) (io.ReadCloser, error) {
	return nil, s.err
}

// Avoid unused imports when the rest of the suite doesn't pull them.
var _ io.Reader = (*bytes.Reader)(nil)
