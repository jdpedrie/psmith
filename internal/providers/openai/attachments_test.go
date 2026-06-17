package openai

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jdpedrie/spalt/internal/providers"
)

// TestSend_Chat_ImageAttachment_TranslatesToImageURLPart asserts the
// driver swaps a user message's content from a plain string to the
// multi-part array form when an image attachment is present, with
// the image bytes inlined as a base64 data URL.
func TestSend_Chat_ImageAttachment_TranslatesToImageURLPart(t *testing.T) {
	t.Parallel()

	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{APIKey: "k", BaseURL: srv.URL + "/v1"})

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "gpt-4o-mini",
		Messages: []providers.WireMessage{
			{
				Role:    "user",
				Content: "what's in this picture?",
				Attachments: []providers.Attachment{
					{
						Kind:     providers.AttachmentImage,
						MimeType: "image/jpeg",
						Data:     []byte{0xff, 0xd8, 0xff, 0xe0},
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
		Messages []struct {
			Role    string            `json:"role"`
			Content []json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(capturedBody, &body); err != nil {
		t.Fatalf("unmarshal: %v\n%s", err, capturedBody)
	}
	if len(body.Messages) != 1 || body.Messages[0].Role != "user" {
		t.Fatalf("expected one user message, got %+v", body.Messages)
	}
	if len(body.Messages[0].Content) != 2 {
		t.Fatalf("expected 2 content parts (image + text), got %d: %s",
			len(body.Messages[0].Content), capturedBody)
	}

	var imagePart struct {
		Type     string `json:"type"`
		ImageURL struct {
			URL string `json:"url"`
		} `json:"image_url"`
	}
	if err := json.Unmarshal(body.Messages[0].Content[0], &imagePart); err != nil {
		t.Fatalf("unmarshal image part: %v", err)
	}
	if imagePart.Type != "image_url" {
		t.Errorf("first part type=%q want image_url", imagePart.Type)
	}
	if !strings.HasPrefix(imagePart.ImageURL.URL, "data:image/jpeg;base64,") {
		t.Errorf("image_url.url should be a base64 data URL, got %q", imagePart.ImageURL.URL)
	}

	var textPart struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body.Messages[0].Content[1], &textPart); err != nil {
		t.Fatalf("unmarshal text part: %v", err)
	}
	if textPart.Type != "text" || textPart.Text != "what's in this picture?" {
		t.Errorf("text part wrong: %+v", textPart)
	}
}

// TestSend_Responses_ImageAttachment_TranslatesToInputImage asserts
// the Responses path builds an input message with an `input_image`
// content block carrying the base64 data URL.
func TestSend_Responses_ImageAttachment_TranslatesToInputImage(t *testing.T) {
	t.Parallel()

	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{
		APIKey:  "k",
		BaseURL: srv.URL + "/v1",
	})
	// resolveChatCompletions forces the chat-completions path for any
	// non-api.openai.com base URL — httptest URLs included. Flip back
	// to the Responses path explicitly so the test exercises that
	// build path.
	ForceResponsesAPIForTest(d)

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "gpt-5",
		Messages: []providers.WireMessage{
			{
				Role:    "user",
				Content: "what's in this picture?",
				Attachments: []providers.Attachment{
					{
						Kind:     providers.AttachmentImage,
						MimeType: "image/png",
						Data:     []byte{0x89, 0x50, 0x4e, 0x47},
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
		Input []struct {
			Role    string            `json:"role"`
			Content []json.RawMessage `json:"content"`
		} `json:"input"`
	}
	if err := json.Unmarshal(capturedBody, &body); err != nil {
		t.Fatalf("unmarshal: %v\n%s", err, capturedBody)
	}
	if len(body.Input) != 1 || body.Input[0].Role != "user" {
		t.Fatalf("expected one user input, got %+v\nfull body: %s", body.Input, capturedBody)
	}
	if len(body.Input[0].Content) != 2 {
		t.Fatalf("expected 2 content parts (image + text), got %d: %s",
			len(body.Input[0].Content), capturedBody)
	}

	var imagePart struct {
		Type     string `json:"type"`
		ImageURL string `json:"image_url"`
	}
	if err := json.Unmarshal(body.Input[0].Content[0], &imagePart); err != nil {
		t.Fatalf("unmarshal image part: %v", err)
	}
	if imagePart.Type != "input_image" {
		t.Errorf("first part type=%q want input_image", imagePart.Type)
	}
	if !strings.HasPrefix(imagePart.ImageURL, "data:image/png;base64,") {
		t.Errorf("image_url should be a base64 data URL, got %q", imagePart.ImageURL)
	}
}

// TestSend_Chat_NonImageAttachment_DroppedSilently confirms that
// PDF / audio / video attachments don't flip the user content
// into the multi-part array form on the Chat path — the OpenAI
// Chat-Completions API doesn't accept inlined documents or
// audio/video, and the capability gate on the client is supposed
// to keep them off this driver. A defensive silent drop here
// means a misbehaving client gets a graceful turn (model sees
// the text) instead of a 4xx that bubbles to the user as a
// confusing error.
func TestSend_Chat_NonImageAttachment_DroppedSilently(t *testing.T) {
	t.Parallel()

	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{APIKey: "k", BaseURL: srv.URL + "/v1"})

	kinds := []providers.Attachment{
		{Kind: providers.AttachmentDocument, MimeType: "application/pdf", Data: []byte("%PDF-")},
		{Kind: providers.AttachmentAudio, MimeType: "audio/mp3", Data: []byte{0xff, 0xfb}},
		{Kind: providers.AttachmentVideo, MimeType: "video/mp4", Data: []byte{0x00, 0x00, 0x00, 0x18}},
	}
	for _, att := range kinds {
		t.Run(string(att.Kind), func(t *testing.T) {
			capturedBody = nil
			ch, err := d.Send(context.Background(), providers.SendRequest{
				ModelID: "gpt-4o-mini",
				Messages: []providers.WireMessage{
					{
						Role:        "user",
						Content:     "summarise this",
						Attachments: []providers.Attachment{att},
					},
				},
			})
			if err != nil {
				t.Fatalf("Send: %v", err)
			}
			for range ch {
			}

			// Without an image attachment the driver leaves the
			// user message's content as a plain string; the
			// non-image attachment is dropped silently. Unmarshal
			// the content as a string and confirm.
			var body struct {
				Messages []struct {
					Role    string          `json:"role"`
					Content json.RawMessage `json:"content"`
				} `json:"messages"`
			}
			if err := json.Unmarshal(capturedBody, &body); err != nil {
				t.Fatalf("unmarshal: %v\n%s", err, capturedBody)
			}
			if len(body.Messages) != 1 || body.Messages[0].Role != "user" {
				t.Fatalf("expected one user message, got %+v", body.Messages)
			}
			var asString string
			if err := json.Unmarshal(body.Messages[0].Content, &asString); err != nil {
				t.Fatalf("content should be a plain string when only non-image attachments are present, got: %s", body.Messages[0].Content)
			}
			if asString != "summarise this" {
				t.Errorf("text content=%q want %q", asString, "summarise this")
			}
		})
	}
}
