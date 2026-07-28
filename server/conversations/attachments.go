package conversations

import "strings"

// attachmentKindFromMime maps a stored file's MIME type to the
// `message_attachments.kind` enum value. The kind exists denormalised
// off MIME so drivers + UI can dispatch on the broad category
// (image / audio / document / video) without re-parsing MIME on
// every history build. Unknown MIME types fall back to "document"
// — the most generic bucket, and the one the UI renders as a
// download chip rather than something it tries to inline.
func attachmentKindFromMime(mime string) string {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return "image"
	case strings.HasPrefix(mime, "audio/"):
		return "audio"
	case strings.HasPrefix(mime, "video/"):
		return "video"
	default:
		return "document"
	}
}
