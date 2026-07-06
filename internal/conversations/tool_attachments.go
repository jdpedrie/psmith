package conversations

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
)

// persistToolResultAttachments writes each tool-produced attachment
// to the storage layer, creates a `files` row (idempotent on
// user+sha256), and binds it to the assistant message via
// `message_attachments` with role_hint=tool_result. Called from the
// per-run OnAssistantMaterialized hook after the assistant row is
// inserted.
//
// Failure mode is intentionally per-attachment: a partial set still
// lands. Callers log the wrapped error and move on — we'd rather
// surface SOME of the tool's output than rip the whole assistant
// message because one screenshot couldn't be deduped.
func (s *Service) persistToolResultAttachments(
	ctx context.Context,
	userID uuid.UUID,
	assistantMsgID uuid.UUID,
	atts []plugins.ToolAttachment,
) error {
	if len(atts) == 0 {
		return nil
	}
	var firstErr error
	for ord, att := range atts {
		if att.Kind == "" || att.MimeType == "" || len(att.Data) == 0 {
			continue
		}
		sum := hex.EncodeToString(sha256Sum(att.Data))
		// Storage first, DB row second — matches the upload-side
		// ordering. A failed Put leaves no `files` row; a failed
		// CreateFile leaves a dangling blob that the next
		// (eventual) GC sweep reclaims.
		if err := s.storage.Put(ctx, userID, sum, att.MimeType, bytes.NewReader(att.Data)); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage put: %w", err)
			}
			continue
		}
		// Try to insert the `files` row. UNIQUE(user_id, sha256)
		// makes this idempotent — if the same bytes already
		// exist for this user (e.g., a tool returned the same
		// screenshot twice), look up the existing row instead.
		fileID := uuid.New()
		var filenamePtr *string
		if att.Filename != "" {
			fn := att.Filename
			filenamePtr = &fn
		}
		// CreateFile is idempotent on (user_id, sha256) — its
		// ON CONFLICT DO UPDATE returns the existing row when the
		// blob has already been uploaded by this user (e.g. the
		// same screenshot returned twice from a tool).
		row, err := s.queries.CreateFile(ctx, store.CreateFileParams{
			ID:               fileID,
			UserID:           userID,
			Sha256:           sum,
			MimeType:         att.MimeType,
			SizeBytes:        int64(len(att.Data)),
			OriginalFilename: filenamePtr,
		})
		if err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("create file: %w", err)
			}
			continue
		}
		if _, err := s.queries.AttachFileToMessage(ctx, store.AttachFileToMessageParams{
			MessageID: assistantMsgID,
			Ordinal:   int32(ord),
			FileID:    row.ID,
			Kind:      att.Kind,
			RoleHint:  "tool_result",
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			if firstErr == nil {
				firstErr = fmt.Errorf("attach file: %w", err)
			}
		}
	}
	return firstErr
}

func sha256Sum(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}
