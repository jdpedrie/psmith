package anthropic

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/jdpedrie/reeve/internal/providers"
)

// TestSend_ImageAttachment_TranslatesToImageBlock asserts that an
// image attachment on a user wire message becomes an
// `{"type":"image","source":{...}}` content block in the request body
// sent to the Anthropic API. The image block should precede the
// text body — Anthropic's documented multimodal grounding pattern.
func TestSend_ImageAttachment_TranslatesToImageBlock(t *testing.T) {
	t.Parallel()

	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		// Send a tiny valid SSE response so Send returns cleanly.
		sseEvents(w,
			[2]string{"message_start", `{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-opus-4-7","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0},"service_tier":"standard"}}}`},
			[2]string{"message_delta", `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}`},
			[2]string{"message_stop", `{"type":"message_stop"}`},
		)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)
	imgBytes := []byte{0xff, 0xd8, 0xff, 0xe0} // JPEG SOI marker — content irrelevant; the test asserts shape, not validity.

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "claude-opus-4-7",
		Messages: []providers.WireMessage{
			{
				Role:    "user",
				Content: "what's in this picture?",
				Attachments: []providers.Attachment{
					{
						Kind:     providers.AttachmentImage,
						MimeType: "image/jpeg",
						Data:     imgBytes,
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	drainChunks(t, ch)

	// Walk the JSON. We expect:
	//   messages[0].role == "user"
	//   messages[0].content == [
	//     { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "<b64>" } },
	//     { type: "text",  text: "what's in this picture?" },
	//   ]
	var body struct {
		Messages []struct {
			Role    string            `json:"role"`
			Content []json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(capturedBody, &body); err != nil {
		t.Fatalf("unmarshal request body: %v\n%s", err, capturedBody)
	}
	if len(body.Messages) != 1 || body.Messages[0].Role != "user" {
		t.Fatalf("expected one user message, got %+v", body.Messages)
	}
	if len(body.Messages[0].Content) != 2 {
		t.Fatalf("expected 2 content blocks (image + text), got %d: %s",
			len(body.Messages[0].Content), capturedBody)
	}
	var imageBlock struct {
		Type   string `json:"type"`
		Source struct {
			Type      string `json:"type"`
			MediaType string `json:"media_type"`
			Data      string `json:"data"`
		} `json:"source"`
	}
	if err := json.Unmarshal(body.Messages[0].Content[0], &imageBlock); err != nil {
		t.Fatalf("unmarshal image block: %v", err)
	}
	if imageBlock.Type != "image" {
		t.Errorf("first block type=%q want image", imageBlock.Type)
	}
	if imageBlock.Source.Type != "base64" {
		t.Errorf("source type=%q want base64", imageBlock.Source.Type)
	}
	if imageBlock.Source.MediaType != "image/jpeg" {
		t.Errorf("media_type=%q want image/jpeg", imageBlock.Source.MediaType)
	}
	if imageBlock.Source.Data == "" {
		t.Errorf("source.data empty (expected base64 image bytes)")
	}

	var textBlock struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body.Messages[0].Content[1], &textBlock); err != nil {
		t.Fatalf("unmarshal text block: %v", err)
	}
	if textBlock.Type != "text" || textBlock.Text != "what's in this picture?" {
		t.Errorf("text block wrong: %+v", textBlock)
	}
}

// TestSend_PDFAttachment_TranslatesToDocumentBlock verifies that
// an `application/pdf` document attachment becomes a `document`
// block in the Anthropic request body, with the bytes inlined as
// base64.
func TestSend_PDFAttachment_TranslatesToDocumentBlock(t *testing.T) {
	t.Parallel()
	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		sseEvents(w,
			[2]string{"message_start", `{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-opus-4-7","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0},"service_tier":"standard"}}}`},
			[2]string{"message_delta", `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}`},
			[2]string{"message_stop", `{"type":"message_stop"}`},
		)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "claude-opus-4-7",
		Messages: []providers.WireMessage{
			{
				Role:    "user",
				Content: "summarise this",
				Attachments: []providers.Attachment{
					{
						Kind:     providers.AttachmentDocument,
						MimeType: "application/pdf",
						Filename: "spec.pdf",
						Data:     []byte("%PDF-1.7\nfake pdf bytes"),
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	drainChunks(t, ch)

	var body struct {
		Messages []struct {
			Content []json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(capturedBody, &body); err != nil {
		t.Fatalf("unmarshal: %v\n%s", err, capturedBody)
	}
	if len(body.Messages) != 1 || len(body.Messages[0].Content) != 2 {
		t.Fatalf("expected 1 user message with 2 blocks (document + text); body=%s", capturedBody)
	}
	var docBlock struct {
		Type   string `json:"type"`
		Source struct {
			Type      string `json:"type"`
			MediaType string `json:"media_type"`
			Data      string `json:"data"`
		} `json:"source"`
	}
	if err := json.Unmarshal(body.Messages[0].Content[0], &docBlock); err != nil {
		t.Fatalf("unmarshal document block: %v", err)
	}
	if docBlock.Type != "document" {
		t.Errorf("first block type=%q want document", docBlock.Type)
	}
	if docBlock.Source.Type != "base64" || docBlock.Source.MediaType != "application/pdf" {
		t.Errorf("source wrong: %+v", docBlock.Source)
	}
	if docBlock.Source.Data == "" {
		t.Errorf("source.data is empty")
	}
}

// TestSend_NonImageAttachment_DroppedSilently confirms that audio /
// video attachments don't break the send path — Anthropic doesn't
// support those kinds at all. The capability table on the client
// is supposed to gate them out, but a defensive drop here means a
// misbehaving client gets a graceful turn (the model just sees
// the text part) rather than a 4xx.
func TestSend_NonImageAttachment_DroppedSilently(t *testing.T) {
	t.Parallel()

	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedBody, _ = io.ReadAll(r.Body)
		sseEvents(w,
			[2]string{"message_start", `{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-opus-4-7","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0},"service_tier":"standard"}}}`},
			[2]string{"message_delta", `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}`},
			[2]string{"message_stop", `{"type":"message_stop"}`},
		)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "claude-opus-4-7",
		Messages: []providers.WireMessage{
			{
				Role:    "user",
				Content: "transcribe this audio",
				Attachments: []providers.Attachment{
					{Kind: providers.AttachmentAudio, MimeType: "audio/wav", Data: []byte{0x52, 0x49, 0x46, 0x46}},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	drainChunks(t, ch)

	var body struct {
		Messages []struct {
			Content []struct {
				Type string `json:"type"`
			} `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(capturedBody, &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, c := range body.Messages[0].Content {
		if c.Type != "text" {
			t.Errorf("expected only text blocks for audio attachment (driver drops it), got block type %q", c.Type)
		}
	}
}
