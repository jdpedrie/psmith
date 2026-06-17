package google

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/jdpedrie/spalt/internal/providers"
)

// TestSend_AllAttachmentKinds_TranslateToInlineData verifies that
// every attachment kind Gemini supports — image, document, audio,
// video — emits a single `inlineData` part with the file's
// mime_type passed through verbatim. Gemini dispatches model-side
// based on the mime_type, so the driver doesn't need to vary the
// part shape per kind.
func TestSend_AllAttachmentKinds_TranslateToInlineData(t *testing.T) {
	t.Parallel()

	kinds := []struct {
		name string
		kind providers.AttachmentKind
		mime string
		data []byte
	}{
		{"image", providers.AttachmentImage, "image/png", []byte{0x89, 0x50}},
		{"document", providers.AttachmentDocument, "application/pdf", []byte("%PDF-")},
		{"audio", providers.AttachmentAudio, "audio/mp3", []byte{0xff, 0xfb}},
		{"video", providers.AttachmentVideo, "video/mp4", []byte{0x00, 0x00, 0x00, 0x18}},
	}

	for _, tc := range kinds {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var capturedBody []byte
			mux := http.NewServeMux()
			mux.HandleFunc("/v1beta/models/gemini-test:streamGenerateContent", func(w http.ResponseWriter, r *http.Request) {
				capturedBody, _ = io.ReadAll(r.Body)
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = w.Write([]byte("data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"ok\"}]},\"finishReason\":\"STOP\"}]}\n\n"))
			})
			srv := httptest.NewServer(mux)
			defer srv.Close()

			d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
			ch, err := d.Send(context.Background(), providers.SendRequest{
				ModelID: "gemini-test",
				Messages: []providers.WireMessage{
					{
						Role:    "user",
						Content: "what's this?",
						Attachments: []providers.Attachment{
							{Kind: tc.kind, MimeType: tc.mime, Data: tc.data},
						},
					},
				},
			})
			if err != nil {
				t.Fatalf("Send: %v", err)
			}
			for range ch {
			}

			var body struct {
				Contents []struct {
					Parts []struct {
						InlineData *struct {
							MimeType string `json:"mimeType"`
							Data     string `json:"data"`
						} `json:"inlineData,omitempty"`
						Text string `json:"text,omitempty"`
					} `json:"parts"`
				} `json:"contents"`
			}
			if err := json.Unmarshal(capturedBody, &body); err != nil {
				t.Fatalf("unmarshal: %v\n%s", err, capturedBody)
			}
			if len(body.Contents) != 1 || len(body.Contents[0].Parts) != 2 {
				t.Fatalf("expected 1 user content with 2 parts (inlineData + text); body=%s", capturedBody)
			}
			inline := body.Contents[0].Parts[0].InlineData
			if inline == nil {
				t.Fatalf("first part is not inlineData; body=%s", capturedBody)
			}
			if inline.MimeType != tc.mime {
				t.Errorf("mimeType=%q want %q", inline.MimeType, tc.mime)
			}
			if inline.Data != base64.StdEncoding.EncodeToString(tc.data) {
				t.Errorf("data wrong")
			}
		})
	}
}

// TestSend_ImageAttachment_TranslatesToInlineData verifies the
// Gemini driver wires an image attachment as an `inlineData` part
// with the right mimeType + base64-encoded data, alongside the text
// content.
func TestSend_ImageAttachment_TranslatesToInlineData(t *testing.T) {
	t.Parallel()

	var capturedBody []byte
	mux := http.NewServeMux()
	mux.HandleFunc("/v1beta/models/gemini-test:streamGenerateContent", func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		// Empty stream — driver tolerates upstream that sends only the SSE marker.
		_, _ = w.Write([]byte("data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"ok\"}]},\"finishReason\":\"STOP\"}]}\n\n"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	ctx := context.Background()
	imgBytes := []byte{0x89, 0x50, 0x4e, 0x47}
	ch, err := d.Send(ctx, providers.SendRequest{
		ModelID: "gemini-test",
		Messages: []providers.WireMessage{
			{
				Role:    "user",
				Content: "what's in this picture?",
				Attachments: []providers.Attachment{
					{
						Kind:     providers.AttachmentImage,
						MimeType: "image/png",
						Data:     imgBytes,
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	var body struct {
		Contents []struct {
			Role  string            `json:"role"`
			Parts []json.RawMessage `json:"parts"`
		} `json:"contents"`
	}
	if err := json.Unmarshal(capturedBody, &body); err != nil {
		t.Fatalf("unmarshal request body: %v\n%s", err, capturedBody)
	}
	if len(body.Contents) != 1 || body.Contents[0].Role != "user" {
		t.Fatalf("expected one user content, got %+v", body.Contents)
	}
	if len(body.Contents[0].Parts) != 2 {
		t.Fatalf("expected 2 parts (inlineData + text), got %d: %s",
			len(body.Contents[0].Parts), capturedBody)
	}

	var inlinePart struct {
		InlineData struct {
			MimeType string `json:"mimeType"`
			Data     string `json:"data"`
		} `json:"inlineData"`
	}
	if err := json.Unmarshal(body.Contents[0].Parts[0], &inlinePart); err != nil {
		t.Fatalf("unmarshal inline part: %v", err)
	}
	if inlinePart.InlineData.MimeType != "image/png" {
		t.Errorf("mimeType=%q want image/png", inlinePart.InlineData.MimeType)
	}
	wantB64 := base64.StdEncoding.EncodeToString(imgBytes)
	if inlinePart.InlineData.Data != wantB64 {
		t.Errorf("inlineData.data=%q want %q", inlinePart.InlineData.Data, wantB64)
	}

	var textPart struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body.Contents[0].Parts[1], &textPart); err != nil {
		t.Fatalf("unmarshal text part: %v", err)
	}
	if textPart.Text != "what's in this picture?" {
		t.Errorf("text=%q want %q", textPart.Text, "what's in this picture?")
	}
}
