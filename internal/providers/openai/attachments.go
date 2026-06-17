package openai

import (
	"encoding/base64"
	"fmt"

	"github.com/jdpedrie/spalt/internal/providers"
)

// hasInlineImageAttachment reports whether `atts` contains at least
// one image attachment with inline bytes — the v1 driver path
// (provider Files API caching is phase 4). Used to decide whether
// to switch the user-message content from a plain string to the
// multi-part array form OpenAI requires for image inputs.
func hasInlineImageAttachment(atts []providers.Attachment) bool {
	for _, a := range atts {
		if a.Kind == providers.AttachmentImage && len(a.Data) > 0 {
			return true
		}
	}
	return false
}

// dataURL builds an RFC-2397 base64 data URL. OpenAI's `image_url`
// content part accepts either an http(s) URL or one of these data
// URLs; we use the latter so the bytes ride directly with the
// request rather than going through a separate Files API upload.
func dataURL(mime string, data []byte) string {
	return fmt.Sprintf("data:%s;base64,%s", mime, base64.StdEncoding.EncodeToString(data))
}
