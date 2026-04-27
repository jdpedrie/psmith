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
}

// WireMessage is the shape providers actually see.
type WireMessage struct {
	Role     string          // "system" | "user" | "assistant"
	Content  string
	Thinking json.RawMessage // native shape; non-nil only on same-provider sends with thinking enabled
}

// CallSettings carries per-turn provider settings.
type CallSettings struct {
	Temperature          *float64
	MaxOutputTokens      *int
	ThinkingEnabled      *bool
	ThinkingBudgetTokens *int
	Extras               json.RawMessage // provider-specific knobs
}

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

// Types returns the names of all registered provider types.
func Types() []string {
	out := make([]string, 0, len(registry))
	for t := range registry {
		out = append(out, t)
	}
	return out
}
