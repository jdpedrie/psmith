package stream

import (
	"encoding/json"

	"github.com/jdpedrie/psmith/internal/providers"
)

// toolCallAggregator builds the JSONB shape stored on
// messages.tool_calls. Source signal:
//
//   - ChunkToolUseStart  → start a new entry; capture id/name/provider_opaque
//   - ChunkToolUseDelta  → append partial_json to that entry's input buffer
//   - ChunkToolUseEnd    → flip the entry to "input complete"
//   - ChunkToolResult    → fold the matching tool_result into the entry by id
//
// The final serialise() call returns []byte ready for the messages row,
// or nil when no tool calls were captured (so we don't write an empty
// JSONB array on every assistant turn).
type toolCallAggregator struct {
	entries []*toolCallEntry
	byID    map[string]*toolCallEntry
}

type toolCallEntry struct {
	ID             string          `json:"id"`
	Name           string          `json:"name"`
	Input          json.RawMessage `json:"input,omitempty"`
	Output         json.RawMessage `json:"output,omitempty"`
	Error          string          `json:"error,omitempty"`
	ElapsedMs      int64           `json:"elapsed_ms,omitempty"`
	ProviderOpaque string          `json:"provider_opaque,omitempty"`

	// inputBuf accumulates ToolUseDelta partial_json fragments before the
	// End chunk seals the entry. Not serialised directly — copied into
	// Input on End.
	inputBuf []byte
}

func newToolCallAggregator() *toolCallAggregator {
	return &toolCallAggregator{byID: map[string]*toolCallEntry{}}
}

func (a *toolCallAggregator) observe(ch providers.Chunk) {
	switch ch.Type {
	case providers.ChunkToolUseStart:
		var info struct {
			ID             string `json:"id"`
			Name           string `json:"name"`
			ProviderOpaque string `json:"provider_opaque"`
		}
		if err := json.Unmarshal(ch.Payload, &info); err != nil || info.ID == "" {
			return
		}
		entry := &toolCallEntry{
			ID:             info.ID,
			Name:           info.Name,
			ProviderOpaque: info.ProviderOpaque,
		}
		a.entries = append(a.entries, entry)
		a.byID[info.ID] = entry
	case providers.ChunkToolUseDelta:
		var d struct {
			PartialJSON string `json:"partial_json"`
		}
		if err := json.Unmarshal(ch.Payload, &d); err != nil {
			return
		}
		if n := len(a.entries); n > 0 {
			cur := a.entries[n-1]
			cur.inputBuf = append(cur.inputBuf, d.PartialJSON...)
		}
	case providers.ChunkToolUseEnd:
		if n := len(a.entries); n > 0 {
			cur := a.entries[n-1]
			if len(cur.inputBuf) == 0 {
				cur.Input = json.RawMessage(`{}`)
			} else {
				cur.Input = json.RawMessage(append([]byte(nil), cur.inputBuf...))
			}
			cur.inputBuf = nil
		}
	case providers.ChunkToolResult:
		var r struct {
			ToolUseID string          `json:"tool_use_id"`
			Output    json.RawMessage `json:"output"`
			Error     string          `json:"error"`
			ElapsedMs int64           `json:"elapsed_ms"`
		}
		if err := json.Unmarshal(ch.Payload, &r); err != nil {
			return
		}
		entry, ok := a.byID[r.ToolUseID]
		if !ok {
			return
		}
		entry.Output = r.Output
		entry.Error = r.Error
		entry.ElapsedMs = r.ElapsedMs
	}
}

func (a *toolCallAggregator) serialise() []byte {
	if len(a.entries) == 0 {
		return nil
	}
	out, err := json.Marshal(a.entries)
	if err != nil {
		return nil
	}
	return out
}
