package google

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/jdpedrie/psmith/server/providers"
)

// Gemini's Files API: upload bytes once, reference them by URI thereafter.
//
// Worth wiring here more than anywhere else because Gemini has no implicit
// prompt cache to blunt the cost of resending, so an image in a long
// conversation is re-uploaded and re-charged on every single turn.

// uploadedFile is the subset of the Files API response we keep.
type uploadedFile struct {
	File struct {
		Name           string `json:"name"`
		URI            string `json:"uri"`
		MimeType       string `json:"mimeType"`
		ExpirationTime string `json:"expirationTime"`
		State          string `json:"state"`
	} `json:"file"`
}

// SupportsFileReference reports which mime types can travel as a file_data
// reference.
//
// Gemini accepts fileData for images, audio, video and PDFs, which is
// everything Psmith attaches. Stated explicitly rather than returning true
// unconditionally so a new attachment kind has to be considered rather than
// silently assumed to work.
func (d *Driver) SupportsFileReference(mimeType string) bool {
	m := strings.ToLower(mimeType)
	switch {
	case strings.HasPrefix(m, "image/"),
		strings.HasPrefix(m, "audio/"),
		strings.HasPrefix(m, "video/"):
		return true
	case m == "application/pdf":
		return true
	default:
		return false
	}
}

// UploadFile pushes bytes to the Files API and returns the resource URI.
//
// The returned id is the file's `uri`, not its `name`: the uri is what
// fileData references in a generateContent request, and storing the other one
// would mean a translation step at every use.
//
// Uploads are billed as storage, not tokens, and expire on Google's schedule
// (48 hours at time of writing). The expiry comes back from the API rather
// than being assumed here, so a change on their side does not silently leave
// us referencing dead files.
func (d *Driver) UploadFile(ctx context.Context, mimeType, filename string, data []byte) (string, time.Time, error) {
	if len(data) == 0 {
		return "", time.Time{}, fmt.Errorf("google: refusing to upload an empty file")
	}
	if filename == "" {
		filename = "attachment"
	}

	// The simple (non-resumable) upload: metadata and bytes in one multipart
	// request. Resumable would matter for very large files; Psmith's
	// attachments are bounded well below the threshold where it pays.
	url := fmt.Sprintf("%s/upload/v1beta/files?key=%s&uploadType=multipart",
		strings.TrimSuffix(d.baseURL, "/v1beta"), d.cfg.APIKey)

	var body bytes.Buffer
	const boundary = "psmith-file-upload-boundary"
	meta, _ := json.Marshal(map[string]any{
		"file": map[string]any{"display_name": filename},
	})
	fmt.Fprintf(&body, "--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n%s\r\n", boundary, meta)
	fmt.Fprintf(&body, "--%s\r\nContent-Type: %s\r\n\r\n", boundary, mimeType)
	body.Write(data)
	fmt.Fprintf(&body, "\r\n--%s--\r\n", boundary)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, &body)
	if err != nil {
		return "", time.Time{}, err
	}
	req.Header.Set("Content-Type", "multipart/related; boundary="+boundary)

	resp, err := d.httpClient.Do(req)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("google: upload file: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", time.Time{}, fmt.Errorf("google: upload file: %s: %s", resp.Status, truncate(string(raw), 200))
	}

	var out uploadedFile
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", time.Time{}, fmt.Errorf("google: decode upload response: %w", err)
	}
	if out.File.URI == "" {
		return "", time.Time{}, fmt.Errorf("google: upload returned no uri")
	}
	// A file still PROCESSING cannot be referenced yet. Reporting it as a
	// failure sends this turn inline and leaves the next one to find it ready,
	// which is better than blocking a user's send on a poll loop.
	if st := strings.ToUpper(out.File.State); st != "" && st != "ACTIVE" {
		return "", time.Time{}, fmt.Errorf("google: uploaded file is %s, not yet referenceable", st)
	}

	var expires time.Time
	if out.File.ExpirationTime != "" {
		if t, perr := time.Parse(time.RFC3339, out.File.ExpirationTime); perr == nil {
			expires = t
		}
	}
	return out.File.URI, expires, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

var _ providers.FileUploader = (*Driver)(nil)
