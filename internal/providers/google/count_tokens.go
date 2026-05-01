package google

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"

	"github.com/jdpedrie/reeve/internal/providers"
)

// countTokensRequest is the body POSTed to {model}:countTokens. Gemini accepts
// the same `contents` + `system_instruction` shape as generateContent.
type countTokensRequest struct {
	Contents          []geminiContent `json:"contents,omitempty"`
	SystemInstruction *geminiContent  `json:"system_instruction,omitempty"`
}

type countTokensResponse struct {
	TotalTokens int `json:"totalTokens"`
}

// CountTokens calls Gemini's /v1beta/models/{model}:countTokens endpoint and
// returns the prompt-token total for the given prefix. Used by the UI to
// drive compaction decisions before a turn is sent.
//
// We reuse buildRequestBody to share role-mapping logic — the wire shapes
// for generateContent and countTokens overlap on the relevant fields.
func (d *Driver) CountTokens(ctx context.Context, modelID string, messages []providers.WireMessage) (int, error) {
	if modelID == "" {
		return 0, fmt.Errorf("google: model_id is required")
	}
	body, err := buildRequestBody(providers.SendRequest{
		ModelID:  modelID,
		Messages: messages,
	})
	if err != nil {
		return 0, err
	}
	req := countTokensRequest{
		Contents:          body.Contents,
		SystemInstruction: body.SystemInstruction,
	}
	bodyJSON, err := json.Marshal(req)
	if err != nil {
		return 0, fmt.Errorf("google: marshal count_tokens request: %w", err)
	}

	u, err := url.Parse(d.baseURL + "/models/" + url.PathEscape(modelID) + ":countTokens")
	if err != nil {
		return 0, fmt.Errorf("google: build count_tokens URL: %w", err)
	}
	q := u.Query()
	q.Set("key", d.cfg.APIKey)
	u.RawQuery = q.Encode()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(bodyJSON))
	if err != nil {
		return 0, fmt.Errorf("google: build count_tokens request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	resp, err := d.httpClient.Do(httpReq)
	if err != nil {
		return 0, fmt.Errorf("google: count_tokens: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, fmt.Errorf("google: count_tokens: HTTP %d: %s",
			resp.StatusCode, readBoundedError(resp))
	}
	var out countTokensResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return 0, fmt.Errorf("google: decode count_tokens: %w", err)
	}
	return out.TotalTokens, nil
}
