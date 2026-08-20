package codexsdk

import "encoding/json"

// JSON-RPC framing. Newline-delimited JSON over the subprocess's stdio.

type request struct {
	ID     int64  `json:"id"`
	Method string `json:"method"`
	Params any    `json:"params"`
}

type response struct {
	ID     *int64          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// --- Requests we send ------------------------------------------------------

type clientInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type initializeParams struct {
	ClientInfo clientInfo `json:"clientInfo"`
}

// ThreadOptions is the setup shared by starting, resuming and forking.
//
// Only the fields a chat harness sets. Codex accepts many more (sandbox
// policy, approval policy, cwd, service tier); leaving them unset means the
// user's own config decides, which is the right default for a tool that is
// borrowing their CLI.
type ThreadOptions struct {
	// Model is the model slug. Empty leaves Codex's configured default.
	Model string
	// BaseInstructions replaces the system prompt.
	//
	// Codex accepts this on resume and fork as well as start, so unlike
	// Claude Code its system prompt is not necessarily fixed for a thread's
	// lifetime. Psmith pins it at conversation start anyway, for uniformity
	// across harnesses.
	BaseInstructions string
}

type threadStartParams struct {
	Model            string `json:"model,omitempty"`
	BaseInstructions string `json:"baseInstructions,omitempty"`
}

type threadResumeParams struct {
	ThreadID         string `json:"threadId"`
	Model            string `json:"model,omitempty"`
	BaseInstructions string `json:"baseInstructions,omitempty"`
}

type threadForkParams struct {
	ThreadID string `json:"threadId"`
	// LastTurnID forks from a specific turn rather than the tip. This is the
	// whole reason this package exists: editing message five means forking at
	// turn five, with nothing replayed.
	LastTurnID       string `json:"lastTurnId,omitempty"`
	Model            string `json:"model,omitempty"`
	BaseInstructions string `json:"baseInstructions,omitempty"`
}

type textInput struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type turnStartParams struct {
	ThreadID string      `json:"threadId"`
	Input    []textInput `json:"input"`
	Model    string      `json:"model,omitempty"`
}

type turnInterruptParams struct {
	ThreadID string `json:"threadId"`
	TurnID   string `json:"turnId"`
}

// --- Responses we read -----------------------------------------------------

// thread is the subset of Codex's Thread we care about. It carries far more
// (git info, previews, status, nicknames); ignoring the rest is what keeps
// this package from breaking on every protocol revision.
type thread struct {
	ID           string `json:"id"`
	ForkedFromID string `json:"forkedFromId"`
}

type threadResult struct {
	Thread thread `json:"thread"`
	Model  string `json:"model"`
}

type turn struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

type turnStartResult struct {
	Turn turn `json:"turn"`
}

// --- Notifications we consume ----------------------------------------------

type agentMessageDelta struct {
	Delta    string `json:"delta"`
	ThreadID string `json:"threadId"`
	TurnID   string `json:"turnId"`
}

type reasoningDelta struct {
	Delta    string `json:"delta"`
	ThreadID string `json:"threadId"`
	TurnID   string `json:"turnId"`
}

type turnCompleted struct {
	ThreadID string `json:"threadId"`
	Turn     turn   `json:"turn"`
}

type errorNotification struct {
	Error struct {
		Message string `json:"message"`
	} `json:"error"`
	ThreadID  string `json:"threadId"`
	TurnID    string `json:"turnId"`
	WillRetry bool   `json:"willRetry"`
}

type tokenUsageBreakdown struct {
	InputTokens       int64 `json:"inputTokens"`
	CachedInputTokens int64 `json:"cachedInputTokens"`
	OutputTokens      int64 `json:"outputTokens"`
	ReasoningTokens   int64 `json:"reasoningOutputTokens"`
}

type tokenUsageUpdated struct {
	ThreadID   string `json:"threadId"`
	TurnID     string `json:"turnId"`
	TokenUsage struct {
		Last  tokenUsageBreakdown `json:"last"`
		Total tokenUsageBreakdown `json:"total"`
	} `json:"tokenUsage"`
}
