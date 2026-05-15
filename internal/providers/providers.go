// Package providers defines the driver abstraction for backend AI providers
// and a compile-time registry. Each provider type lives in its own subpackage
// and registers itself in init().
package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/jdpedrie/reeve/internal/modelmeta"
)

// Provider is the registered driver for a backend kind.
type Provider interface {
	Type() string
	Stateful() bool
	// DiscoverModels returns the catalog of models the provider currently
	// offers. Static-catalog drivers (Anthropic) may return a hardcoded list;
	// dynamic drivers (openai-compatible) hit the provider's models endpoint.
	// Implementations are expected to enrich entries with metadata via the
	// modelmeta.Catalog passed at construction.
	DiscoverModels(ctx context.Context) ([]Model, error)
	// RenderThinkingToText converts a stored thinking JSON blob to plain text
	// for cross-provider injection. Deterministic; called once on inbound and
	// the result cached.
	RenderThinkingToText(thinking json.RawMessage) string
}

// StatelessProvider sends a full prefix every turn. Server owns history.
type StatelessProvider interface {
	Provider
	Send(ctx context.Context, req SendRequest) (<-chan Chunk, error)
}

// StatefulProvider sends only the latest message to a long-lived harness session.
type StatefulProvider interface {
	Provider
	StartSession(ctx context.Context, modelID string, settings CallSettings) (sessionID string, err error)
	SendInSession(ctx context.Context, sessionID string, msg WireMessage, settings CallSettings) (<-chan Chunk, error)
	TerminateSession(ctx context.Context, sessionID string) error
}

// TokenCounter is implemented by drivers that can report a token count for a
// candidate prefix. Used by the UI to inform compaction decisions.
type TokenCounter interface {
	CountTokens(ctx context.Context, modelID string, messages []WireMessage) (int, error)
}

// Deps are the dependencies passed to driver constructors at instance build time.
type Deps struct {
	Catalog modelmeta.Catalog
	Logger  *slog.Logger
}

// SendRequest is the input to a stateless turn. Messages are wire-shaped:
// role rewriting (context→user) and cross-provider thinking injection have
// already been applied upstream.
type SendRequest struct {
	ModelID  string
	Messages []WireMessage
	Settings CallSettings
	// ConversationID is the ID of the conversation this turn belongs to,
	// threaded through so drivers can use it as a provider-specific cache
	// key (OpenAI's prompt_cache_key, etc). Empty for off-conversation
	// invocations such as compression turns. Stringified UUID rather than
	// a typed uuid.UUID so the providers package stays free of the
	// google/uuid dependency on the request boundary.
	ConversationID string
	// Tools is the set of plugin-provided tool declarations to expose on
	// this turn. Drivers translate these into their native tools shape;
	// providers that don't support tools silently drop them.
	Tools []ToolDef
}

// ToolDef is the driver-facing description of a single callable tool.
// Mirrors plugins.ToolDef without taking the dependency — the providers
// package must stay free of plugins to avoid an import cycle.
type ToolDef struct {
	Name        string
	Description string
	InputSchema json.RawMessage
}

// WireMessage is the shape providers actually see.
type WireMessage struct {
	Role     string          // "system" | "user" | "assistant"
	Content  string
	Thinking json.RawMessage // native shape; non-nil only on same-provider sends with thinking enabled
	// ToolUses is set on assistant messages that contain tool invocations
	// from a previous round. Drivers that support tools translate these
	// alongside Content into native content blocks; drivers that don't
	// silently drop them.
	ToolUses []ToolUseBlock
	// ToolResults is set on user messages that carry tool results coming
	// back to the model after a previous tool_use turn.
	ToolResults []ToolResultBlock
	// Attachments carry binary payloads (images, documents, audio) that
	// accompany the message. Drivers translate the subset their model
	// can render into native content blocks (Anthropic `image`,
	// Gemini `inline_data`, OpenAI `image_url` / `input_image`) and
	// silently drop the rest — gated by the per-driver capability
	// table so the UI can warn the user up-front.
	Attachments []Attachment
}

// AttachmentKind groups attachments into the four broad categories
// drivers care about. Matches the CHECK constraint on
// message_attachments.kind.
type AttachmentKind string

const (
	AttachmentImage    AttachmentKind = "image"
	AttachmentAudio    AttachmentKind = "audio"
	AttachmentDocument AttachmentKind = "document"
	AttachmentVideo    AttachmentKind = "video"
)

// Attachment is a single binary payload riding on a WireMessage.
// Exactly one of Data / URL / ProviderFileID is populated:
//   - Data: inline bytes, the v1 path (history builder reads from
//     Storage and inlines them on every send).
//   - URL: a stable URL the provider can fetch — rare in v1, used
//     when the provider supports it and we have a cacheable URL.
//   - ProviderFileID: a phase-4 cached upload (provider-side Files
//     API) resolved against the active provider; preferred over
//     Data when available to dodge re-inlining.
type Attachment struct {
	Kind           AttachmentKind
	MimeType       string // e.g. "image/png", "application/pdf"
	Filename       string // original filename, rendered for docs
	Data           []byte
	URL            string
	ProviderFileID string
	// SHA256 lets the cache-observability hash see attachment
	// content without re-hashing megabytes per turn. Set by the
	// history builder from `files.sha256`.
	SHA256 string
}

// ToolUseBlock is one tool invocation captured from an assistant turn.
// Stored on the assistant message + replayed in WireMessage on follow-up
// turns so the model has a coherent record of what it called.
type ToolUseBlock struct {
	ID    string          // provider-assigned id; e.g. Anthropic "toolu_…"
	Name  string          // tool name (matches a registered plugin tool)
	Input json.RawMessage // JSON arguments object the model emitted
	// ProviderOpaque carries provider-specific metadata that must
	// round-trip back on the next round (Gemini's `thoughtSignature`).
	// Drivers that don't emit a signature leave this empty.
	ProviderOpaque string
}

// ToolResultBlock is the corresponding result for a previous ToolUseBlock.
// Either Output or Error is set, never both.
//
// Attachments carry binary content the tool produced (most
// commonly screenshots from a browse-tool, generated images
// from an image-gen plugin, charts from a code-exec sandbox).
// Drivers that support image-in-tool-result blocks (Anthropic,
// Google) inline them on the next-round wire prefix so the
// model can see what its tool returned; drivers that don't
// (OpenAI Chat) drop them silently — the user still sees them
// in the chat surface because they're persisted on the
// assistant message with role_hint=tool_result.
type ToolResultBlock struct {
	ToolUseID   string          // matches ToolUseBlock.ID
	Output      json.RawMessage // tool's JSON output; empty if Error is set
	Error       string          // human-readable failure message; empty on success
	Attachments []Attachment    // binary outputs (images, files); may be empty
}

// CallSettings carries per-turn provider settings. The shape mirrors the
// `reeve.v1.CallSettings` proto (a hybrid common-core + provider-specific
// design); see proto/reeve/v1/types.proto for field-level documentation.
//
// Drivers translate the subset of fields they support and silently drop the
// rest. The 4-layer resolution chain
// (conversation > profile > model > provider) sparse-merges these structs
// before dispatch — see internal/profiles/callsettings.go.
type CallSettings struct {
	// --- Common (all three providers) ---
	Temperature     *float64
	TopP            *float64
	MaxOutputTokens *int
	StopSequences   []string

	// --- Two-of-three (Anthropic + Google) ---
	TopK *int

	// --- Universal "thinking" knob, translated per driver ---
	Thinking *ThinkingSettings

	// --- Provider-specific extension blocks ---
	Anthropic *AnthropicExtras
	OpenAI    *OpenAIExtras
	Google    *GoogleExtras

	// --- Cross-cutting: caching ---
	// ExplicitCache opts the conversation in to server-managed
	// explicit caching. The conversations service owns the lookup /
	// create / attach / expire orchestration; drivers that implement
	// ExplicitCacheProvider provide just the upstream call shapes.
	// Resolved through the standard 4-layer chain.
	ExplicitCache *bool
}

// ThinkingSettings mirrors reeve.v1.ThinkingSettings.
type ThinkingSettings struct {
	Enabled      *bool
	BudgetTokens *int
}

// AnthropicExtras carries Anthropic-specific knobs that don't fit the
// cross-provider common surface. Mirrors reeve.v1.AnthropicExtras.
type AnthropicExtras struct {
	// CacheEnabled, when non-nil and false, instructs the driver to skip
	// the auto cache_control marker placement entirely. nil = inherit
	// (default behaviour: caching enabled).
	CacheEnabled *bool
	// CacheTTL selects the ephemeral cache TTL tier. Zero value
	// (CacheTTLUnspecified) = the SDK / API default (5 minutes).
	CacheTTL CacheTTL
}

// CacheTTL is the Anthropic ephemeral-cache TTL tier. Zero value =
// unspecified, which the driver interprets as the API default (5m).
type CacheTTL int

const (
	CacheTTLUnspecified CacheTTL = 0
	CacheTTL5m          CacheTTL = 1
	CacheTTL1h          CacheTTL = 2
)

// OpenAIExtras carries OpenAI-specific generation knobs.
type OpenAIExtras struct {
	Seed              *int
	FrequencyPenalty  *float64
	PresencePenalty   *float64
	TopLogprobs       *int
	ParallelToolCalls *bool
	ServiceTier       *ServiceTier
	ResponseFormat    *ResponseFormat
	LogitBias         map[int32]float64
}

// ServiceTier is the OpenAI service-tier selector. Zero value = unspecified.
type ServiceTier int

const (
	ServiceTierUnspecified ServiceTier = 0
	ServiceTierAuto        ServiceTier = 1
	ServiceTierStandard    ServiceTier = 2
	ServiceTierPriority    ServiceTier = 3
)

// ResponseFormat is the OpenAI response-format selector. Exactly one of the
// pointer fields is non-nil (oneof semantics on the wire).
type ResponseFormat struct {
	Text       *bool
	JSONObject *bool
	JSONSchema *JSONSchema
}

// JSONSchema is the OpenAI structured-output schema block.
type JSONSchema struct {
	Name        string
	Description *string
	Schema      []byte // raw JSON Schema bytes
	Strict      *bool
}

// GoogleExtras carries Gemini-specific generation knobs.
type GoogleExtras struct {
	SafetySettings   *SafetySettings
	ResponseMimeType *string
	ResponseSchema   []byte
	CandidateCount   *int

	// CachedContent, when set, points at a cached_content resource
	// previously created via the Driver's CreateCachedContent helper.
	// The driver passes it to streamGenerateContent as `cachedContent`,
	// telling Gemini to reuse the pre-tokenized prefix instead of
	// re-billing it. Set per-turn by the conversations service when
	// CallSettings.ExplicitCache is true and a cache exists for the
	// conversation; not part of the proto — it's a runtime override.
	CachedContent *string
}

// SafetySettings mirrors reeve.v1.SafetySettings.
type SafetySettings struct {
	Harassment       *HarmThreshold
	HateSpeech       *HarmThreshold
	SexuallyExplicit *HarmThreshold
	DangerousContent *HarmThreshold
}

// HarmThreshold mirrors reeve.v1.HarmThreshold.
type HarmThreshold int

const (
	HarmThresholdUnspecified       HarmThreshold = 0
	HarmThresholdBlockNone         HarmThreshold = 1
	HarmThresholdBlockLowAndAbove  HarmThreshold = 2
	HarmThresholdBlockMediumAndAbove HarmThreshold = 3
	HarmThresholdBlockOnlyHigh     HarmThreshold = 4
)

// Chunk is the normalized streaming output type.
//
// Payload must be non-nil JSON (use []byte("{}") for empty payloads such as
// ChunkDone or ChunkToolUseEnd). The supervisor persists chunks to a NOT NULL
// column; nil payloads cause persistence to fail silently and skip DB-replay
// for that chunk.
type Chunk struct {
	Type    ChunkType
	Payload json.RawMessage
}

type ChunkType string

const (
	ChunkText                ChunkType = "text_delta"
	ChunkThinking            ChunkType = "thinking_delta"
	ChunkThinkingSignature   ChunkType = "thinking_signature"
	ChunkToolUseStart        ChunkType = "tool_use_start"
	ChunkToolUseDelta        ChunkType = "tool_use_delta"
	ChunkToolUseEnd          ChunkType = "tool_use_end"
	// ChunkToolResult is synthesized by the conversations-side tool-loop
	// wrapper after a plugin's ExecuteTool returns. Payload:
	//   {"tool_use_id": "...", "output": <raw json>, "error": "...", "elapsed_ms": <int>}
	ChunkToolResult ChunkType = "tool_result"
	ChunkUsage      ChunkType = "usage"
	ChunkError      ChunkType = "error"
	ChunkDone       ChunkType = "done"
)

// Usage is the normalized token-usage payload emitted via ChunkUsage.
// Drivers fill in whatever the upstream reports; null fields mean "not
// reported." ProviderRaw preserves the upstream blob for forensics.
type Usage struct {
	InputTokens      *int            `json:"input_tokens,omitempty"`
	OutputTokens     *int            `json:"output_tokens,omitempty"`
	CacheReadTokens  *int            `json:"cache_read_tokens,omitempty"`
	CacheWriteTokens *int            `json:"cache_write_tokens,omitempty"`
	ReasoningTokens  *int            `json:"reasoning_tokens,omitempty"`
	ProviderRaw      json.RawMessage `json:"provider_raw,omitempty"`
	// FinishReason is the verbatim per-provider termination cause.
	// Anthropic: stop_reason (end_turn / max_tokens / stop_sequence /
	// tool_use / refusal). OpenAI: finish_reason (stop / length /
	// content_filter / tool_calls). Google: finishReason (STOP /
	// MAX_TOKENS / SAFETY / RECITATION / OTHER). Drivers SHOULD set
	// this on the final Usage chunk; the supervisor stamps it onto the
	// materialised message so the UI can render unexpected reasons in
	// the footer.
	FinishReason *string `json:"finish_reason,omitempty"`
}

// Model describes one model exposed by a provider during discovery.
// Catalog/persisted snapshots use the wire-level UserModel/CatalogModel types;
// drivers traffic in this struct internally.
type Model struct {
	ID              string
	DisplayName     string
	ContextWindow   int
	MaxOutputTokens int
	Capabilities    ModelCapabilities
	Pricing         *Pricing
	KnowledgeCutoff string
	Modalities      []string
	DefaultSettings CallSettings
	MetadataSource  modelmeta.Source
}

type ModelCapabilities struct {
	Streaming     bool
	Thinking      bool
	ToolUse       bool
	Vision        bool
	PromptCaching bool
}

type Pricing struct {
	InputPerMillion       float64
	OutputPerMillion      float64
	CacheReadPerMillion   float64
	CacheWritePerMillion  float64
}

// Constructor builds a Provider from injected dependencies and a driver-specific
// JSON config blob (the contents of user_model_providers.config).
type Constructor func(deps Deps, config json.RawMessage) (Provider, error)

var registry = map[string]Constructor{}

// Register a provider type. Call from a package init().
func Register(typeName string, c Constructor) {
	if _, exists := registry[typeName]; exists {
		panic(fmt.Sprintf("providers: duplicate registration for %q", typeName))
	}
	registry[typeName] = c
}

// Build instantiates a provider from a registered type and its config.
func Build(typeName string, deps Deps, config json.RawMessage) (Provider, error) {
	c, ok := registry[typeName]
	if !ok {
		return nil, fmt.Errorf("providers: unknown type %q", typeName)
	}
	return c(deps, config)
}

// IsRegistered reports whether a provider type is in the registry.
// Used by the management RPCs to validate `type` at create time so we
// don't persist dead rows that only fail later on driver-touching paths.
func IsRegistered(typeName string) bool {
	_, ok := registry[typeName]
	return ok
}

// Types returns the names of all registered provider types.
func Types() []string {
	out := make([]string, 0, len(registry))
	for t := range registry {
		out = append(out, t)
	}
	return out
}
