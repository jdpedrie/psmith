// Package providers defines the driver abstraction for backend AI providers
// and a compile-time registry. Each provider type lives in its own subpackage
// and registers itself in init().
package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/jdpedrie/clark/internal/modelmeta"
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
}

// WireMessage is the shape providers actually see.
type WireMessage struct {
	Role     string          // "system" | "user" | "assistant"
	Content  string
	Thinking json.RawMessage // native shape; non-nil only on same-provider sends with thinking enabled
}

// CallSettings carries per-turn provider settings. The shape mirrors the
// `clark.v1.CallSettings` proto (a hybrid common-core + provider-specific
// design); see proto/clark/v1/types.proto for field-level documentation.
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
}

// ThinkingSettings mirrors clark.v1.ThinkingSettings.
type ThinkingSettings struct {
	Enabled      *bool
	BudgetTokens *int
}

// AnthropicExtras carries Anthropic-specific knobs that don't fit the
// cross-provider common surface. Mirrors clark.v1.AnthropicExtras.
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
	// previously created via the Driver's CreateCachedContent helper. The
	// driver passes it to streamGenerateContent as `cachedContent`, telling
	// Gemini to reuse the pre-tokenized prefix instead of re-billing it.
	//
	// Format: the full resource name returned by the create call, e.g.
	// "cachedContents/abc123". The conversations service populates this
	// per-turn when ExplicitCache is enabled and a cache exists for the
	// conversation; not part of the proto — it's a runtime override.
	CachedContent *string

	// ExplicitCache opts the conversation in to server-managed
	// cachedContents auto-placement. When true, the conversations
	// service creates a Gemini cache on the first turn whose prefix
	// exceeds the model's minimum, references it on subsequent turns,
	// and refreshes on expiry. Resolved via the standard 4-layer
	// CallSettings inheritance chain.
	ExplicitCache *bool
}

// SafetySettings mirrors clark.v1.SafetySettings.
type SafetySettings struct {
	Harassment       *HarmThreshold
	HateSpeech       *HarmThreshold
	SexuallyExplicit *HarmThreshold
	DangerousContent *HarmThreshold
}

// HarmThreshold mirrors clark.v1.HarmThreshold.
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
	ChunkText         ChunkType = "text_delta"
	ChunkThinking     ChunkType = "thinking_delta"
	ChunkToolUseStart ChunkType = "tool_use_start"
	ChunkToolUseDelta ChunkType = "tool_use_delta"
	ChunkToolUseEnd   ChunkType = "tool_use_end"
	ChunkUsage        ChunkType = "usage"
	ChunkError        ChunkType = "error"
	ChunkDone         ChunkType = "done"
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
