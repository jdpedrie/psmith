package plugins

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jdpedrie/psmith/internal/embeddings"
)

// MemoryName is the registered name for the conversation-memory
// search-tool plugin. Stable across releases — changing it would
// orphan stored plugin configs.
const MemoryName = "memory"

// memory exposes one tool — `search_history` — that the model can
// call to find semantically-related older messages. Designed for
// "long compressed chats" where the wire prefix has been pruned and
// the model needs to recover context that's no longer in scope.
//
// The plugin is config-free: no API key, no model picker, no per-
// conversation toggle. The user already configured an embedder at
// the daemon level (PSMITH_EMBEDDER), and the same Searcher serves
// every memory-enabled conversation. Per-call settings are knobs the
// model itself drives via the tool's `count` and `max_distance`
// args.
//
// Surfaces results as JSON the model can read. No attachments. No
// upstream cost (search is local).
type memory struct {
	cfg memoryConfig
}

type memoryConfig struct {
	// DefaultCount is the number of snippets returned when the
	// model doesn't specify `count`. Default 5. The plugin caps at
	// 25 in any case — beyond that the model rarely benefits.
	DefaultCount int `json:"default_count"`

	// MaxDistance is the cosine-distance threshold above which a
	// hit is dropped before it ever reaches the model. 0 = no
	// filter; the plugin defaults to 0.6 because nomic-embed-text
	// distances much past that are usually noise.
	MaxDistance float64 `json:"max_distance"`

	// IncludeActiveContext controls whether messages from the
	// caller's CURRENT active context can appear in results.
	// Default false — those messages are already in the wire
	// prefix, surfacing them again is just budget waste. Old
	// retired contexts of the SAME conversation always come
	// through; they're the primary use case (compressed-out
	// content the model needs to recover).
	IncludeActiveContext bool `json:"include_active_context"`
}

func newMemory(configBytes json.RawMessage) (Plugin, error) {
	cfg := memoryConfig{
		DefaultCount: 5,
		MaxDistance:  0.6,
	}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("memory: parse config: %w", err)
		}
	}
	if cfg.DefaultCount <= 0 {
		cfg.DefaultCount = 5
	}
	return &memory{cfg: cfg}, nil
}

func init() {
	Register(MemoryName, newMemory)
}

func (p *memory) Name() string        { return MemoryName }
func (p *memory) DisplayName() string { return "Memory" }

func (p *memory) Description() string {
	return "Lets the model search older messages for grounding when the " +
		"wire prefix has been compressed or the relevant context is no " +
		"longer in scope. Requires a configured embedder (PSMITH_EMBEDDER)."
}

// --- Configurable ---

func (p *memory) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "default_count",
			Display:     "Default result count",
			Description: "Number of snippets returned when the model doesn't specify count. Capped at 25.",
			Type:        ConfigFieldNumber,
			Default:     5,
		},
		{
			Name:        "max_distance",
			Display:     "Max cosine distance",
			Description: "Drop hits with cosine distance above this threshold. 0 = no filter. ~0.6 is a reasonable cutoff for nomic-embed-text.",
			Type:        ConfigFieldNumber,
			Default:     0.6,
		},
		{
			Name:        "include_active_context",
			Display:     "Include active context",
			Description: "Allow results from the caller's current active context (the slice already in the wire prefix). Default off. Older retired contexts of the same conversation always come through — they're the main reason this tool exists.",
			Type:        ConfigFieldBoolean,
			Default:     false,
		},
	}
}

// --- ToolProvider ---

const memoryToolName = "search_history"

func (p *memory) Tools() []ToolDef {
	return []ToolDef{
		{
			Name:        memoryToolName,
			Description: "Search older messages in this user's conversation history for content semantically related to a query. Use when the current wire prefix doesn't contain what you need to remember. Returns up to `count` ranked snippets with conversation context.",
			InputSchema: []byte(`{
				"type": "object",
				"properties": {
					"query": {
						"type": "string",
						"description": "Natural-language query describing what you're trying to recall. The more specific, the better the recall."
					},
					"count": {
						"type": "integer",
						"description": "Max number of results to return (default 5, max 25).",
						"minimum": 1,
						"maximum": 25
					}
				},
				"required": ["query"]
			}`),
		},
	}
}

type memoryToolInput struct {
	Query string `json:"query"`
	Count *int   `json:"count,omitempty"`
}

type memoryToolOutput struct {
	Query   string             `json:"query"`
	Hits    []memoryToolHit    `json:"hits"`
	Skipped *memoryToolSkipped `json:"skipped,omitempty"`
}

type memoryToolHit struct {
	ConversationID    string `json:"conversation_id"`
	ConversationTitle string `json:"conversation_title,omitempty"`
	MessageID         string `json:"message_id"`
	Role              string `json:"role"`
	Content           string `json:"content"`
	When              string `json:"when"`
	// Distance is reported so the model can self-grade hit
	// quality and ignore noisier ones if it wants.
	Distance float64 `json:"distance"`
}

type memoryToolSkipped struct {
	// Count of hits filtered out because they live in the caller's
	// active context (already in the wire prefix). Surfaces "we
	// found things but suppressed them" so the model isn't
	// confused by an empty result on a query it expects to match.
	ActiveContext int `json:"active_context,omitempty"`
}

func (p *memory) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	if name != memoryToolName {
		return ToolResult{}, fmt.Errorf("memory: unknown tool %q", name)
	}
	var in memoryToolInput
	if len(input) > 0 {
		if err := json.Unmarshal(input, &in); err != nil {
			return ToolResult{}, fmt.Errorf("memory: parse input: %w", err)
		}
	}
	if strings.TrimSpace(in.Query) == "" {
		return ToolResult{}, fmt.Errorf("memory: query is required")
	}

	searcher := SearcherFrom(ctx)
	if searcher == nil {
		return ToolResult{}, fmt.Errorf("memory: no Searcher in context — server not wired (set PSMITH_EMBEDDER)")
	}

	// CallerInfo tells us who's running this tool. The dispatch site
	// attaches both ProviderResolver and CallerInfo; the latter
	// carries the user_id we need to scope the search.
	caller := CallerInfoFrom(ctx)
	if caller.UserID == uuid.Nil {
		return ToolResult{}, fmt.Errorf("memory: no CallerInfo in context — server not wired")
	}

	count := p.cfg.DefaultCount
	if in.Count != nil && *in.Count > 0 {
		count = *in.Count
	}
	if count > 25 {
		count = 25
	}

	hits, err := searcher.Search(ctx, in.Query, embeddings.SearchOptions{
		UserID:      caller.UserID,
		Limit:       count,
		MaxDistance: p.cfg.MaxDistance,
	})
	if err != nil {
		return ToolResult{}, fmt.Errorf("memory: search: %w", err)
	}

	out := memoryToolOutput{Query: in.Query}
	var skippedActive int
	for _, h := range hits {
		if !p.cfg.IncludeActiveContext && h.ContextID == caller.ActiveContextID {
			skippedActive++
			continue
		}
		out.Hits = append(out.Hits, memoryToolHit{
			ConversationID:    h.ConversationID.String(),
			ConversationTitle: h.ConversationTitle,
			MessageID:         h.MessageID.String(),
			Role:              h.Role,
			Content:           h.Content,
			When:              h.CreatedAt.UTC().Format(time.RFC3339),
			Distance:          h.Distance,
		})
	}
	if skippedActive > 0 {
		out.Skipped = &memoryToolSkipped{ActiveContext: skippedActive}
	}

	body, err := json.Marshal(out)
	if err != nil {
		return ToolResult{}, fmt.Errorf("memory: marshal output: %w", err)
	}
	return ToolResult{Output: body}, nil
}
