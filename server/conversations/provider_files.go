package conversations

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

// Provider-side attachment uploads.
//
// History assembly inlines every attachment in a conversation on every send,
// so one image is base64'd and pushed upstream once per turn for the life of
// the chat. Drivers that implement providers.FileUploader can take the bytes
// once and be handed a reference thereafter.
//
// The whole path is best-effort by construction. Every failure — no uploader,
// unsupported mime type, upload error, database error — leaves the attachment
// with its bytes intact, and the driver inlines them exactly as before. A
// Files API outage costs bandwidth, never a turn.

// uploadDeadline bounds the extra latency this can add to a send.
//
// Uploads happen inline, before the model call, so a slow Files API would
// otherwise be felt as the send hanging. Past this we give up and inline,
// which is the same outcome as not having the feature.
const uploadDeadline = 20 * time.Second

// attachProviderFiles swaps inline bytes for provider references wherever it
// can, mutating the prefix in place.
//
// Returns nothing: there is no failure mode a caller could act on, since the
// fallback is the input unchanged.
func (s *Service) attachProviderFiles(
	ctx context.Context,
	driver providers.Provider,
	provRow store.UserModelProvider,
	userID uuid.UUID,
	msgs []providers.WireMessage,
) {
	uploader, ok := driver.(providers.FileUploader)
	if !ok {
		return
	}

	// One pass to find work, so a prefix with no attachments costs nothing
	// beyond the type assertion.
	type target struct {
		msg, att int
	}
	var todo []target
	for i := range msgs {
		for j := range msgs[i].Attachments {
			a := &msgs[i].Attachments[j]
			if a.ProviderFileID != "" || a.SHA256 == "" || len(a.Data) == 0 {
				continue
			}
			if !uploader.SupportsFileReference(a.MimeType) {
				continue
			}
			todo = append(todo, target{i, j})
		}
	}
	if len(todo) == 0 {
		return
	}

	// Deduplicate by content hash within one prefix. The same image quoted
	// across several turns is one blob and must not be uploaded per mention.
	resolved := map[string]string{}

	upCtx, cancel := context.WithTimeout(ctx, uploadDeadline)
	defer cancel()

	for _, t := range todo {
		att := &msgs[t.msg].Attachments[t.att]
		if id, ok := resolved[att.SHA256]; ok {
			att.ProviderFileID = id
			att.Data = nil
			continue
		}

		if row, err := s.queries.GetProviderFile(upCtx, store.GetProviderFileParams{
			UserModelProviderID: provRow.ID,
			Sha256:              att.SHA256,
		}); err == nil && row.ProviderFileID != "" {
			resolved[att.SHA256] = row.ProviderFileID
			att.ProviderFileID = row.ProviderFileID
			// Dropping the bytes is the point: they are what we are trying
			// not to send.
			att.Data = nil
			continue
		}

		fileID, expiresAt, err := uploader.UploadFile(upCtx, att.MimeType, att.Filename, att.Data)
		if err != nil {
			// Inline this one and keep going. One unusable attachment should
			// not cost the others their reference.
			s.logger.Warn("provider file upload failed; sending inline",
				"err", err, "provider", provRow.Type, "sha256", att.SHA256)
			continue
		}

		var expPtr *time.Time
		if !expiresAt.IsZero() {
			expPtr = &expiresAt
		}
		if _, err := s.queries.UpsertProviderFile(upCtx, store.UpsertProviderFileParams{
			UserModelProviderID: provRow.ID,
			Sha256:              att.SHA256,
			UserID:              userID,
			ProviderFileID:      fileID,
			MimeType:            att.MimeType,
			SizeBytes:           int64(len(att.Data)),
			ExpiresAt:           expPtr,
		}); err != nil {
			// The upload succeeded, so use it for this turn. Failing to
			// record it only costs a re-upload next time.
			s.logger.Warn("record provider file failed",
				"err", err, "provider", provRow.Type, "sha256", att.SHA256)
		}

		resolved[att.SHA256] = fileID
		att.ProviderFileID = fileID
		att.Data = nil
	}
}
