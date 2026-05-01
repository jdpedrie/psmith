package google

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/jdpedrie/reeve/internal/providers"
)

// Cached content (explicit caching) is API-only in Reeve v1: there's no
// proto field, no UI surface, and no automatic placement. Callers that
// want to reuse a long stable prefix (e.g. a tool catalog or a system
// prompt that exceeds Gemini's implicit-cache threshold) explicitly
// CreateCachedContent, then thread the returned name through
// CallSettings.Google.CachedContent on subsequent Send calls. When done,
// DeleteCachedContent reclaims the resource ahead of TTL expiry.
//
// Two reasons to use explicit caching over Gemini's implicit cache:
//
//  1. Coverage. Implicit caching only kicks in when the *same* prefix is
//     seen again within the cache window. Explicit caching guarantees a
//     hit on every referencing call.
//  2. Cost predictability. Implicit hits are best-effort; explicit hits
//     are billable at the discounted cache-read rate from the moment the
//     cache is created.

// CachedContent is the materialized representation of a cachedContents
// resource. Field names mirror the Gemini wire shape (camelCase JSON).
type CachedContent struct {
	// Name is the full resource name, e.g. "cachedContents/abc123". Pass
	// it back to Send via CallSettings.Google.CachedContent.
	Name string `json:"name"`
	// Model is the model the cache was created against. Cached content is
	// model-scoped: a cache made for gemini-2.5-flash cannot be reused
	// against gemini-2.5-pro.
	Model       string `json:"model,omitempty"`
	DisplayName string `json:"displayName,omitempty"`
	CreateTime  string `json:"createTime,omitempty"`
	UpdateTime  string `json:"updateTime,omitempty"`
	ExpireTime  string `json:"expireTime,omitempty"`
	// UsageMetadata reports the total prompt tokens cached. Useful for
	// confirming the prefix was large enough to satisfy the model's
	// minimum (which varies by model — 4096 tokens on gemini-2.5-flash,
	// higher on older models).
	UsageMetadata *CachedContentUsage `json:"usageMetadata,omitempty"`
}

// CachedContentUsage is the subset of the cachedContents.usageMetadata we
// care about. Gemini reports more (audio/video tokens, etc.) but those
// don't apply to text-only Reeve.
type CachedContentUsage struct {
	TotalTokenCount int `json:"totalTokenCount,omitempty"`
}

// CreateCachedContentRequest is the input to Driver.CreateCachedContent.
//
// Either SystemInstruction or Messages (or both) must be non-empty —
// Gemini rejects empty caches.
type CreateCachedContentRequest struct {
	// ModelID is the bare model identifier, e.g. "gemini-2.5-flash". The
	// driver prepends "models/" to satisfy the wire format.
	ModelID string
	// DisplayName is an optional human-readable label.
	DisplayName string
	// SystemInstruction, if set, becomes the cache's system_instruction.
	SystemInstruction string
	// Messages are wire-shaped (role: "user"|"assistant"|"system"). Same
	// translation rules as Send: "system" routes to system_instruction,
	// "assistant" to "model".
	Messages []providers.WireMessage
	// TTL is the cache lifetime, encoded as "<seconds>s" on the wire (e.g.
	// "300s"). If empty, Gemini applies its default (1 hour at time of
	// writing). Pass an explicit value when you need predictable expiry.
	TTL string
}

// createCachedContentBody is the wire shape POSTed to /cachedContents.
type createCachedContentBody struct {
	Model             string          `json:"model"`
	DisplayName       string          `json:"displayName,omitempty"`
	Contents          []geminiContent `json:"contents,omitempty"`
	SystemInstruction *geminiContent  `json:"systemInstruction,omitempty"`
	TTL               string          `json:"ttl,omitempty"`
}

// CreateCachedContent creates a cachedContents resource and returns the
// materialized object (use .Name to reference it on subsequent Sends).
//
// The cache is model-scoped: the same prefix cached against
// gemini-2.5-flash and gemini-2.5-pro requires two separate calls.
//
// Gemini enforces a minimum cacheable size that varies by model
// (currently 4096 tokens on 2.5-flash). Below the floor, Gemini returns
// 400 INVALID_ARGUMENT and we surface that as an error.
func (d *Driver) CreateCachedContent(ctx context.Context, req CreateCachedContentRequest) (*CachedContent, error) {
	if req.ModelID == "" {
		return nil, fmt.Errorf("google: model_id is required")
	}
	if req.SystemInstruction == "" && len(req.Messages) == 0 {
		return nil, fmt.Errorf("google: cached content needs system_instruction or messages")
	}

	body := createCachedContentBody{
		Model:       "models/" + req.ModelID,
		DisplayName: req.DisplayName,
		TTL:         req.TTL,
	}
	if req.SystemInstruction != "" {
		body.SystemInstruction = &geminiContent{
			Parts: []geminiPart{{Text: req.SystemInstruction}},
		}
	}
	for _, m := range req.Messages {
		switch m.Role {
		case "system":
			if body.SystemInstruction == nil {
				body.SystemInstruction = &geminiContent{}
			}
			body.SystemInstruction.Parts = append(body.SystemInstruction.Parts, geminiPart{
				Text: m.Content,
			})
		case "user":
			body.Contents = append(body.Contents, geminiContent{
				Role:  "user",
				Parts: []geminiPart{{Text: m.Content}},
			})
		case "assistant":
			body.Contents = append(body.Contents, geminiContent{
				Role:  "model",
				Parts: []geminiPart{{Text: m.Content}},
			})
		default:
			return nil, fmt.Errorf("google: unsupported wire role %q", m.Role)
		}
	}

	bodyJSON, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("google: marshal cached_content request: %w", err)
	}

	u, err := url.Parse(d.baseURL + "/cachedContents")
	if err != nil {
		return nil, fmt.Errorf("google: build cached_content URL: %w", err)
	}
	q := u.Query()
	q.Set("key", d.cfg.APIKey)
	u.RawQuery = q.Encode()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(bodyJSON))
	if err != nil {
		return nil, fmt.Errorf("google: build cached_content request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	resp, err := d.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("google: cached_content create: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("google: cached_content create: HTTP %d: %s",
			resp.StatusCode, readBoundedError(resp))
	}
	var out CachedContent
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("google: decode cached_content response: %w", err)
	}
	return &out, nil
}

// GetCachedContent fetches an existing cached_content resource by name.
// `name` must be the full "cachedContents/<id>" path returned by Create.
func (d *Driver) GetCachedContent(ctx context.Context, name string) (*CachedContent, error) {
	if !strings.HasPrefix(name, "cachedContents/") {
		return nil, fmt.Errorf("google: cached_content name must start with 'cachedContents/'")
	}
	u, err := url.Parse(d.baseURL + "/" + name)
	if err != nil {
		return nil, fmt.Errorf("google: build cached_content URL: %w", err)
	}
	q := u.Query()
	q.Set("key", d.cfg.APIKey)
	u.RawQuery = q.Encode()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("google: build cached_content GET: %w", err)
	}
	httpReq.Header.Set("Accept", "application/json")

	resp, err := d.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("google: cached_content get: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("google: cached_content get: HTTP %d: %s",
			resp.StatusCode, readBoundedError(resp))
	}
	var out CachedContent
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("google: decode cached_content: %w", err)
	}
	return &out, nil
}

// DeleteCachedContent deletes a cached_content resource ahead of its TTL.
// Idempotent against 404s — the goal is "ensure the cache is gone" so a
// missing resource is success.
func (d *Driver) DeleteCachedContent(ctx context.Context, name string) error {
	if !strings.HasPrefix(name, "cachedContents/") {
		return fmt.Errorf("google: cached_content name must start with 'cachedContents/'")
	}
	u, err := url.Parse(d.baseURL + "/" + name)
	if err != nil {
		return fmt.Errorf("google: build cached_content URL: %w", err)
	}
	q := u.Query()
	q.Set("key", d.cfg.APIKey)
	u.RawQuery = q.Encode()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodDelete, u.String(), nil)
	if err != nil {
		return fmt.Errorf("google: build cached_content DELETE: %w", err)
	}

	resp, err := d.httpClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("google: cached_content delete: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("google: cached_content delete: HTTP %d: %s",
			resp.StatusCode, readBoundedError(resp))
	}
	return nil
}
