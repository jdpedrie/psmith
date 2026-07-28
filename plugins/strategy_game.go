package plugins

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/jdpedrie/psmith/plugins/strategygame"
)

// StrategyGameName is the registered plugin name. Stable forever — it is
// a database value in profile_plugins and in plugin_state.plugin_name.
const StrategyGameName = "strategy_game"

// gameStateTag wraps the authoritative block the plugin appends to each
// assistant turn. Distinctive enough not to collide with anything a
// model would write on its own.
const (
	gameOpenTag  = "<psmith_game>"
	gameCloseTag = "</psmith_game>"
)

// strategyGame runs a turn-based narrative strategy game inside an
// ordinary conversation.
//
// The division of labour is the whole design: this plugin owns every
// rule, number, die roll and end condition, and the model owns nothing
// but fiction. Models narrate well and keep books badly, so the model is
// never asked to produce a figure — not a stat, not a cost, not a
// probability. It proposes situations in tags ("hard", "major stakes")
// and the engine turns those into numbers from authored tables.
//
// State lives in plugin_state keyed to the assistant message that
// produced it, so forking a conversation forks the campaign. See
// plugins/game_store.go.
type strategyGame struct {
	cfg strategyGameConfig

	// mu guards pending, which is written by ExecuteTool during the tool
	// loop and read by TransformAssistantContent at assistant finalize.
	// Same instance serves both phases (the pipeline is rebuilt per
	// send), which is what lets the plugin inject authoritative numbers
	// into content the model never wrote.
	mu      sync.Mutex
	pending *strategygame.State
	// lastTransition is the mechanical result of the turn just resolved,
	// kept so the appended block can explain the outcome.
	lastTransition *strategygame.Transition
}

type strategyGameConfig struct {
	ShowOdds  bool `json:"show_odds"`
	ShowRolls bool `json:"show_rolls"`
}

func newStrategyGame(configBytes json.RawMessage) (Plugin, error) {
	// Defaults live here, not only in ConfigField.Default — Describe
	// builds every plugin with a nil config to introspect it, so the
	// constructor has to produce a usable instance from nothing.
	cfg := strategyGameConfig{ShowOdds: true, ShowRolls: true}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("strategy_game: parse config: %w", err)
		}
	}
	return &strategyGame{cfg: cfg}, nil
}

func init() { Register(StrategyGameName, newStrategyGame) }

func (p *strategyGame) Name() string        { return StrategyGameName }
func (p *strategyGame) DisplayName() string { return "Strategy Game" }

func (p *strategyGame) Description() string {
	return "Turns a conversation into a turn-based strategy game. You hold a position of " +
		"authority — ruler, commander, administrator — and each turn poses a situation with " +
		"structured choices that show their real odds. The plugin owns the rules, stats, dice " +
		"and win/loss conditions; the model only writes the fiction, so the numbers never drift. " +
		"Start a campaign by describing the scenario in your first message. Forking the " +
		"conversation forks the campaign, so you can replay a decision and compare outcomes."
}

// --- Configurable ---

func (p *strategyGame) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "show_odds",
			Display:     "Show success odds",
			Description: "Print each choice's real chance of a favorable outcome, and its chance of disaster, on the button. Hidden odds tend to read as arbitrary, and players assume the game is cheating.",
			Type:        ConfigFieldBoolean,
			Default:     true,
			Category:    "Presentation",
		},
		{
			Name:        "show_rolls",
			Display:     "Show the dice",
			Description: "Include the raw roll and the modifiers behind each outcome, so a result can be understood rather than just accepted.",
			Type:        ConfigFieldBoolean,
			Default:     true,
			Category:    "Presentation",
		},
	}
}

// --- SystemPrompter ---
//
// Static text only: this interface takes no arguments and cannot see the
// conversation, so it teaches the protocol rather than carrying state.
// Live state reaches the model through the tool result.

func (p *strategyGame) PrependSystemMessage() string { return "" }

func (p *strategyGame) AppendSystemMessage() string {
	return strings.Join([]string{
		"## Strategy game protocol",
		"",
		"This conversation is a turn-based strategy game. You are the narrator and scenario",
		"director. You do NOT track state, do arithmetic, roll dice, or decide outcomes — the",
		"game engine owns all of that and will reject anything that tries.",
		"",
		"Never write a number that describes game state. No stat values, no costs, no",
		"percentages, no die results. The engine appends the status panel and the choice",
		"buttons to your message automatically; if you also write them out they will contradict",
		"the real ones. Describe consequences in words instead: \"the treasury is badly strained\".",
		"",
		"On the FIRST turn there is no campaign yet. Read the user's opening message as the",
		"scenario brief, then call game_commit_turn with kind=\"initialize\", compiling it into a",
		"scenario: the role, a premise, resources (spent and accumulated, e.g. treasury), ratings",
		"(small numbers added to dice, e.g. guile), loss conditions, a turn limit or victory",
		"conditions, and an opening situation with at least two choices.",
		"",
		"On EVERY later turn, read the user's message as a decision on the current situation and",
		"call game_commit_turn with kind=\"resolve\", passing the chosen choice_id and a draft of",
		"the NEXT situation. Then narrate what the returned outcome band and effects mean in the",
		"fiction. Let the mechanics drive the story, not the reverse: if the engine says the",
		"attempt was a disaster, write a disaster.",
		"",
		"Choices are described in tags, never numbers. Each names the rating it tests, a",
		"difficulty band (" + strings.Join(strategygame.DifficultyNames(), ", ") + "), a stakes tier (" +
			strings.Join(strategygame.StakesNames(), ", ") + "), the stat it advances on success, and the stat it costs.",
		"Make choices genuinely different: a safe option, an expensive certain one, a risky",
		"high-reward one. The player should be choosing between kinds of damage, not between an",
		"obvious right answer and an obvious wrong one.",
		"",
		"Call game_commit_turn exactly ONCE per turn. Every result carries a state_version;",
		"pass it back as expected_state_version on your next commit so a replayed or stale call",
		"is rejected instead of silently double-applied.",
		"",
		"Never reveal director-only facts (hidden agendas, scheduled events) unless the fiction",
		"has legitimately exposed them.",
	}, "\n")
}

// --- ToolProvider ---

func (p *strategyGame) Tools() []ToolDef {
	return []ToolDef{
		{
			Name: "game_commit_turn",
			Description: "Commit one game turn. kind=\"initialize\" compiles the user's opening " +
				"message into a scenario and starts the campaign; kind=\"resolve\" applies the " +
				"player's chosen option and poses the next situation. The engine validates, rolls, " +
				"applies effects and checks win/loss, then returns what actually happened. Only " +
				"narrate from the returned result.",
			InputSchema: []byte(commitTurnSchema),
		},
		{
			Name: "game_inspect",
			Description: "Read the current campaign state without changing anything. Use when the " +
				"player asks about their position, or to recover after an error.",
			InputSchema: []byte(`{"type":"object","properties":{}}`),
		},
	}
}

func (p *strategyGame) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	store := GameStoreFrom(ctx)
	if store == nil {
		return ToolResult{}, fmt.Errorf("strategy_game: no GameStore in context — server not wired for stateful plugins")
	}
	switch name {
	case "game_inspect":
		st, _, err := p.loadState(ctx, store)
		if err != nil {
			return ToolResult{}, err
		}
		return jsonResult(map[string]any{
			"phase":  st.Protocol.Phase,
			"turn":   st.Meta.Turn,
			"public": st.Public,
		})
	case "game_commit_turn":
		return p.commitTurn(ctx, store, input)
	}
	return ToolResult{}, fmt.Errorf("strategy_game: unknown tool %q", name)
}

// commitTurnInput is the model-facing shape. Note what is absent: any
// integer describing the game. Difficulty and stakes are band names the
// engine prices.
type commitTurnInput struct {
	Kind string `json:"kind"`
	// ExpectedStateVersion is the version the model believes it is acting
	// on. Optional but strongly encouraged: it turns a duplicated,
	// retried or replayed tool call from a silent double-application into
	// a clean rejection the model can recover from.
	ExpectedStateVersion *int64                       `json:"expected_state_version,omitempty"`
	Scenario             *strategygame.Scenario       `json:"scenario,omitempty"`
	ChoiceID             string                       `json:"choice_id,omitempty"`
	Next                 *strategygame.SituationDraft `json:"next_situation,omitempty"`
}

func (p *strategyGame) commitTurn(ctx context.Context, store GameStore, raw json.RawMessage) (ToolResult, error) {
	var in commitTurnInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return ToolResult{}, fmt.Errorf("strategy_game: parse input: %w", err)
	}
	current, exists, err := p.loadStateOptional(ctx, store)
	if err != nil {
		return ToolResult{}, err
	}

	// One committed turn per send. A model that calls the tool twice —
	// retry logic, a confused tool loop, or fishing for a better roll —
	// would otherwise advance the campaign several turns behind a single
	// narration, and only the last one would ever be bound to a message.
	p.mu.Lock()
	alreadyCommitted := p.pending != nil
	p.mu.Unlock()
	if alreadyCommitted {
		return ToolResult{}, fmt.Errorf(
			"strategy_game: this turn is already committed — narrate the result you were given rather than committing again")
	}

	// Optimistic concurrency. Compares against the version actually on
	// the branch, so a stale call (a replay, or a second client acting on
	// state the model last saw) is refused rather than silently applied
	// on top of newer state.
	if in.ExpectedStateVersion != nil && exists {
		if got := current.Meta.StateVersion; got != *in.ExpectedStateVersion {
			return ToolResult{}, fmt.Errorf(
				"strategy_game: state conflict — you acted on version %d but the campaign is at version %d; call game_inspect and reconsider",
				*in.ExpectedStateVersion, got)
		}
	}

	switch in.Kind {
	case "initialize":
		// Phase gate: the model cannot restart a running campaign, and
		// it does not get to decide whether one exists.
		if exists && current.Protocol.Phase != strategygame.PhaseUninitialized {
			return ToolResult{}, fmt.Errorf(
				"strategy_game: this campaign is already underway (turn %d) — use kind=\"resolve\"", current.Meta.Turn)
		}
		if in.Scenario == nil {
			return ToolResult{}, fmt.Errorf("strategy_game: initialize requires a scenario")
		}
		next, err := strategygame.Initialize(*in.Scenario, seedFor(ctx))
		if err != nil {
			return ToolResult{}, fmt.Errorf("strategy_game: %w", err)
		}
		p.setPending(&next, nil)
		return jsonResult(map[string]any{
			"committed":     true,
			"state_version": next.Meta.StateVersion,
			"turn":          next.Meta.Turn,
			"public":        next.Public,
			"director":      next.Director,
			"narrate":       "Introduce the campaign and pose the opening situation. Do not restate any numbers.",
		})

	case "resolve":
		if !exists || current.Protocol.Phase == strategygame.PhaseUninitialized {
			return ToolResult{}, fmt.Errorf("strategy_game: no campaign yet — call kind=\"initialize\" first")
		}
		if current.Protocol.Phase == strategygame.PhaseFinished {
			return ToolResult{}, fmt.Errorf("strategy_game: this campaign ended on turn %d", current.Meta.Turn)
		}
		tr, next, err := strategygame.Resolve(current, in.ChoiceID)
		if err != nil {
			return ToolResult{}, fmt.Errorf("strategy_game: %w", err)
		}
		// A finished campaign needs no next situation; otherwise one is
		// required or the player would have nothing to do.
		if next.Protocol.Phase != strategygame.PhaseFinished {
			if in.Next == nil {
				return ToolResult{}, fmt.Errorf("strategy_game: resolve requires next_situation unless the campaign ended")
			}
			sit, err := strategygame.PriceSituation(next, *in.Next)
			if err != nil {
				return ToolResult{}, fmt.Errorf("strategy_game: next_situation: %w", err)
			}
			next.Public.Situation = &sit
			next.Protocol.LegalChoiceIDs = nil
			for _, c := range sit.Choices {
				next.Protocol.LegalChoiceIDs = append(next.Protocol.LegalChoiceIDs, c.ID)
			}
		}
		p.setPending(&next, &tr)
		out := map[string]any{
			"committed":     true,
			"state_version": next.Meta.StateVersion,
			"outcome":       tr.Band,
			"explain":       tr.Explain,
			"deltas":        tr.Deltas,
			"turn":          next.Meta.Turn,
			"public":        next.Public,
			"director":      next.Director,
			"narrate": "Narrate this outcome in the fiction. The band is authoritative — if it " +
				"says disaster, write a disaster. Do not restate any numbers.",
		}
		if tr.Outcome != nil {
			out["campaign_over"] = true
			out["victory"] = tr.Outcome.Victory
			out["ending"] = tr.Outcome.Label
		}
		return jsonResult(out)
	}
	return ToolResult{}, fmt.Errorf("strategy_game: kind must be \"initialize\" or \"resolve\", got %q", in.Kind)
}

func (p *strategyGame) loadState(ctx context.Context, store GameStore) (strategygame.State, bool, error) {
	st, exists, err := p.loadStateOptional(ctx, store)
	if err != nil {
		return strategygame.State{}, false, err
	}
	if !exists {
		return strategygame.State{}, false, fmt.Errorf("strategy_game: no campaign has been started in this conversation")
	}
	return st, true, nil
}

func (p *strategyGame) loadStateOptional(ctx context.Context, store GameStore) (strategygame.State, bool, error) {
	// A state computed earlier in this same turn wins over the stored
	// one — the model may call inspect after committing.
	p.mu.Lock()
	if p.pending != nil {
		st := *p.pending
		p.mu.Unlock()
		return st, true, nil
	}
	p.mu.Unlock()

	raw, _, _, err := store.LoadNearest(ctx)
	if err != nil {
		if err == ErrNoGameState {
			return strategygame.State{}, false, nil
		}
		return strategygame.State{}, false, fmt.Errorf("strategy_game: load state: %w", err)
	}
	var st strategygame.State
	if err := json.Unmarshal(raw, &st); err != nil {
		return strategygame.State{}, false, fmt.Errorf("strategy_game: stored state is unreadable: %w", err)
	}
	if err := st.Validate(); err != nil {
		return strategygame.State{}, false, fmt.Errorf("strategy_game: %w", err)
	}
	return st, true, nil
}

func (p *strategyGame) setPending(st *strategygame.State, tr *strategygame.Transition) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pending = st
	p.lastTransition = tr
}

// --- PendingStateProvider ---

func (p *strategyGame) PendingPluginState() (json.RawMessage, int64, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.pending == nil {
		return nil, 0, false
	}
	blob, err := json.Marshal(p.pending)
	if err != nil {
		return nil, 0, false
	}
	return blob, p.pending.Meta.StateVersion, true
}

// --- TurnContextInjector ---

// BuildTurnContext puts the live campaign state in front of the model
// every turn, scoped to the branch being continued.
//
// Without it the model only learns state from a tool result, which means
// it cannot answer "how is the treasury" without spending a round trip,
// and after a compaction it would be narrating from whatever figures
// survived into the summary. The block is ephemeral and lands after the
// cache breakpoint, so it costs a few hundred uncached tokens a turn
// rather than invalidating the whole prefix.
//
// Director facts are included: the model is the game's director and is
// told to keep them secret. They never reach the renderer, which only
// ever sees the block appended to assistant content.
func (p *strategyGame) BuildTurnContext(ctx context.Context, turn TurnInfo) (string, error) {
	store := GameStoreFrom(ctx)
	if store == nil {
		return "", nil
	}
	raw, _, _, err := store.LoadNearest(ctx)
	if err != nil {
		// No campaign yet is the normal first-turn case, not a failure.
		return "", nil
	}
	var st strategygame.State
	if err := json.Unmarshal(raw, &st); err != nil {
		return "", err
	}

	var b strings.Builder
	b.WriteString("<game_state>\n")
	fmt.Fprintf(&b, "Turn %d", st.Meta.Turn)
	if st.Meta.DateLabel != "" {
		fmt.Fprintf(&b, " — %s", st.Meta.DateLabel)
	}
	fmt.Fprintf(&b, "\nRole: %s\n", st.Public.Role)

	resources, ratings := st.Public.SortedStats()
	if len(resources) > 0 {
		b.WriteString("Resources: ")
		for i, id := range resources {
			if i > 0 {
				b.WriteString(", ")
			}
			fmt.Fprintf(&b, "%s %d", st.Public.Label(id), st.Public.Resources[id])
		}
		b.WriteString("\n")
	}
	if len(ratings) > 0 {
		b.WriteString("Ratings: ")
		for i, id := range ratings {
			if i > 0 {
				b.WriteString(", ")
			}
			fmt.Fprintf(&b, "%s %d", st.Public.Label(id), st.Public.Ratings[id])
		}
		b.WriteString("\n")
	}
	if st.Public.Situation != nil {
		fmt.Fprintf(&b, "Current situation: %s (id %s)\n", st.Public.Situation.Title, st.Public.Situation.ID)
		b.WriteString("Options on the table: ")
		for i, c := range st.Public.Situation.Choices {
			if i > 0 {
				b.WriteString("; ")
			}
			fmt.Fprintf(&b, "%s = %s", c.ID, c.Label)
		}
		b.WriteString("\n")
	}
	// Only the tail of the ledger: enough for callbacks, not enough to
	// grow without bound as the campaign runs long.
	if n := len(st.Public.History); n > 0 {
		b.WriteString("Recent decisions:\n")
		for _, e := range st.Public.History[max(0, n-5):] {
			fmt.Fprintf(&b, "  turn %d: chose %s in %s → %s\n", e.Turn, e.Choice, e.Situation, e.Band)
		}
	}
	if len(st.Director.HiddenFacts) > 0 {
		b.WriteString("Director-only (never reveal directly):\n")
		for _, f := range st.Director.HiddenFacts {
			fmt.Fprintf(&b, "  - %s\n", f)
		}
	}
	fmt.Fprintf(&b, "State version %d — pass this as expected_state_version.\n", st.Meta.StateVersion)
	b.WriteString("</game_state>")
	return b.String(), nil
}

// --- AssistantContentTransformer ---

// TransformAssistantContent appends the authoritative game block to the
// model's prose before the row is persisted.
//
// This is why the model is never asked to emit the status or the
// choices: it cannot mistype a number it never wrote. The block is
// stored, so every later fetch re-renders the same figures the engine
// resolved against, and a scroll-back turn still shows its real odds.
func (p *strategyGame) TransformAssistantContent(content string) string {
	p.mu.Lock()
	st, tr := p.pending, p.lastTransition
	p.mu.Unlock()
	if st == nil {
		return content
	}
	block := gameBlock{
		Turn:      st.Meta.Turn,
		DateLabel: st.Meta.DateLabel,
		ShowOdds:  p.cfg.ShowOdds,
	}
	resources, ratings := st.Public.SortedStats()
	for _, id := range resources {
		block.Stats = append(block.Stats, statLine{Label: st.Public.Label(id), Value: st.Public.Resources[id]})
	}
	for _, id := range ratings {
		block.Stats = append(block.Stats, statLine{Label: st.Public.Label(id), Value: st.Public.Ratings[id]})
	}
	if tr != nil && p.cfg.ShowRolls {
		block.Resolution = tr.Explain
	}
	if st.Public.Outcome != nil {
		block.Ending = st.Public.Outcome.Label
		block.Victory = st.Public.Outcome.Victory
	} else if st.Public.Situation != nil {
		block.Situation = st.Public.Situation.Title
		for _, c := range st.Public.Situation.Choices {
			block.Choices = append(block.Choices, choiceLine{
				ID: c.ID, Label: c.Label,
				Favorable: c.Odds.Favorable, Disaster: c.Odds.Disaster,
			})
		}
	}
	blob, err := json.Marshal(block)
	if err != nil {
		return content
	}
	return strings.TrimRight(content, "\n") + "\n\n" + gameOpenTag + string(blob) + gameCloseTag
}

// gameBlock is the rendered payload. Deliberately a flat, display-shaped
// projection rather than the whole State: director facts must never
// reach the client, and the renderer has no business seeing them.
type gameBlock struct {
	Turn       int          `json:"turn"`
	DateLabel  string       `json:"date_label,omitempty"`
	Stats      []statLine   `json:"stats"`
	Situation  string       `json:"situation,omitempty"`
	Choices    []choiceLine `json:"choices,omitempty"`
	Resolution []string     `json:"resolution,omitempty"`
	Ending     string       `json:"ending,omitempty"`
	Victory    bool         `json:"victory,omitempty"`
	ShowOdds   bool         `json:"show_odds"`
}

type statLine struct {
	Label string `json:"label"`
	Value int    `json:"value"`
}

type choiceLine struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Favorable int    `json:"favorable"`
	Disaster  int    `json:"disaster"`
}

// --- DisplayTransformer ---

// TransformForDisplay strips the machine block from the human-readable
// text. The ContentRenderer below turns it into real components, so
// leaving the JSON in the prose would show it twice.
func (p *strategyGame) TransformForDisplay(content string) string {
	for {
		start := strings.Index(content, gameOpenTag)
		if start < 0 {
			return strings.TrimRight(content, "\n")
		}
		end := strings.Index(content[start:], gameCloseTag)
		if end < 0 {
			return strings.TrimRight(content[:start], "\n")
		}
		content = content[:start] + content[start+end+len(gameCloseTag):]
	}
}

// --- StreamingTagProvider ---

func (p *strategyGame) StreamingTags() []StreamingTag {
	// The block is appended at finalize rather than streamed, so there
	// is no live tag to hand the client. Declared empty deliberately:
	// the plugin owns the structured output end to end.
	return nil
}

// --- ContentRenderer ---

// RenderContent turns the stored block into native components. Reuses
// the existing key_value and choice_list vocabulary rather than
// introducing bespoke ones, so no client change is needed to play.
func (p *strategyGame) RenderContent(parts []ContentPart, role string) []ContentPart {
	if role != "assistant" {
		return parts
	}
	return WalkText(parts, func(text string) []ContentPart {
		// WalkText splices the return value in place of the part, so
		// every "leave this alone" path has to hand the text back.
		// Returning nil would delete it — which for a plugin attached to
		// a whole profile means every ordinary assistant message in the
		// conversation silently disappearing.
		unchanged := []ContentPart{NewTextPart(text)}

		start := strings.Index(text, gameOpenTag)
		if start < 0 {
			return unchanged
		}
		rel := strings.Index(text[start:], gameCloseTag)
		if rel < 0 {
			return unchanged
		}
		bodyStart := start + len(gameOpenTag)
		bodyEnd := start + rel
		var block gameBlock
		if err := json.Unmarshal([]byte(text[bodyStart:bodyEnd]), &block); err != nil {
			// Never silently drop model output.
			return unchanged
		}

		var out []ContentPart
		if prose := strings.TrimRight(text[:start], "\n"); prose != "" {
			out = append(out, NewTextPart(prose))
		}
		if len(block.Stats) > 0 {
			pairs := make([]map[string]string, 0, len(block.Stats))
			for _, s := range block.Stats {
				pairs = append(pairs, map[string]string{"key": s.Label, "value": fmt.Sprintf("%d", s.Value)})
			}
			title := fmt.Sprintf("Turn %d", block.Turn)
			if block.DateLabel != "" {
				title = fmt.Sprintf("Turn %d — %s", block.Turn, block.DateLabel)
			}
			if props, err := json.Marshal(map[string]any{"pairs": pairs}); err == nil {
				out = append(out, NewTextPart("**"+title+"**"))
				out = append(out, NewFragmentPart("key_value", props, "game_status"))
			}
		}
		if len(block.Resolution) > 0 {
			out = append(out, NewTextPart("_"+strings.Join(block.Resolution, " ")+"_"))
		}
		if len(block.Choices) > 0 {
			items := make([]map[string]string, 0, len(block.Choices))
			for _, c := range block.Choices {
				label := c.Label
				if block.ShowOdds {
					// Two numbers, not one: a 30% chance with a 5%
					// disaster tail and a 30% chance with a 40% tail are
					// completely different decisions.
					label = fmt.Sprintf("%s  ·  %d%% favorable · %d%% disaster", c.Label, c.Favorable, c.Disaster)
				}
				items = append(items, map[string]string{
					"label":  label,
					"value":  c.ID,
					"action": "send:" + c.ID,
				})
			}
			if props, err := json.Marshal(map[string]any{"items": items}); err == nil {
				out = append(out, NewFragmentPart("choice_list", props, "game_choices"))
			}
		}
		if block.Ending != "" {
			verdict := "Defeat"
			if block.Victory {
				verdict = "Victory"
			}
			out = append(out, NewTextPart(fmt.Sprintf("**%s — %s**", verdict, block.Ending)))
		}
		if tail := strings.TrimLeft(text[bodyEnd+len(gameCloseTag):], "\n"); tail != "" {
			out = append(out, NewTextPart(tail))
		}
		return out
	})
}

// seedFor derives a campaign seed. Taken from the caller identity rather
// than a clock so a test can pin it, and so two campaigns started by the
// same user in the same conversation cannot collide.
func seedFor(ctx context.Context) uint64 {
	info := CallerInfoFrom(ctx)
	b := info.ConversationID
	var seed uint64
	for i := 0; i < 8; i++ {
		seed = seed<<8 | uint64(b[i])
	}
	if seed == 0 {
		seed = 0x5DEECE66D
	}
	return seed
}

func jsonResult(v any) (ToolResult, error) {
	blob, err := json.Marshal(v)
	if err != nil {
		return ToolResult{}, err
	}
	return ToolResult{Output: blob}, nil
}

const commitTurnSchema = `{
  "type": "object",
  "properties": {
    "kind": {"type": "string", "enum": ["initialize", "resolve"]},
    "expected_state_version": {"type": "integer", "description": "The state_version from the previous turn's result. Rejects stale or replayed calls."},
    "scenario": {
      "type": "object",
      "description": "Required when kind=initialize. Compiled from the user's opening message.",
      "properties": {
        "title": {"type": "string"},
        "role": {"type": "string", "description": "The position of authority the player holds."},
        "premise": {"type": "string"},
        "date_label": {"type": "string", "description": "In-fiction time label, e.g. 'Late Autumn'."},
        "resources": {
          "type": "array",
          "description": "Stats that are spent and accumulated (treasury, manpower). Larger numbers.",
          "items": {"type": "object", "properties": {
            "id": {"type": "string"}, "label": {"type": "string"},
            "start": {"type": "integer"}, "min": {"type": "integer"}, "max": {"type": "integer"}
          }, "required": ["id", "label", "start", "min", "max"]}
        },
        "ratings": {
          "type": "array",
          "description": "Small capability stats added to dice (guile, standing). Keep max around 10.",
          "items": {"type": "object", "properties": {
            "id": {"type": "string"}, "label": {"type": "string"},
            "start": {"type": "integer"}, "min": {"type": "integer"}, "max": {"type": "integer"}
          }, "required": ["id", "label", "start", "min", "max"]}
        },
        "loss_when": {
          "type": "array",
          "description": "At least one. A game you cannot lose is not a game.",
          "items": {"type": "object", "properties": {
            "stat": {"type": "string"}, "op": {"type": "string", "enum": ["<=", ">="]},
            "value": {"type": "integer"}, "label": {"type": "string"}
          }, "required": ["stat", "op", "value", "label"]}
        },
        "victory_when": {
          "type": "array",
          "items": {"type": "object", "properties": {
            "stat": {"type": "string"}, "op": {"type": "string", "enum": ["<=", ">="]},
            "value": {"type": "integer"}, "label": {"type": "string"}
          }, "required": ["stat", "op", "value", "label"]}
        },
        "turn_limit": {"type": "integer", "description": "Surviving this many turns wins."},
        "hidden_facts": {"type": "array", "items": {"type": "string"}, "description": "Director-only. Never shown to the player."},
        "opening_situation": {"$ref": "#/$defs/situation"}
      },
      "required": ["role", "premise", "resources", "ratings", "loss_when", "opening_situation"]
    },
    "choice_id": {"type": "string", "description": "Required when kind=resolve. Which option the player took."},
    "next_situation": {"$ref": "#/$defs/situation"}
  },
  "required": ["kind"],
  "$defs": {
    "situation": {
      "type": "object",
      "properties": {
        "id": {"type": "string"},
        "title": {"type": "string"},
        "body": {"type": "string", "description": "The situation in prose. No numbers."},
        "choices": {
          "type": "array",
          "minItems": 2,
          "items": {"type": "object", "properties": {
            "id": {"type": "string", "description": "Short, e.g. A, B, C."},
            "label": {"type": "string", "description": "The action, in the player's voice. No numbers."},
            "rating": {"type": "string", "description": "Which declared rating this check tests."},
            "difficulty": {"type": "string", "enum": ["trivial", "easy", "moderate", "hard", "daunting", "forlorn"]},
            "stakes": {"type": "string", "enum": ["minor", "standard", "major"]},
            "advances": {"type": "string", "description": "Stat that improves when the check goes well."},
            "costs": {"type": "string", "description": "Stat spent regardless of outcome."}
          }, "required": ["id", "label", "rating", "difficulty", "stakes", "advances", "costs"]}
        }
      },
      "required": ["id", "title", "body", "choices"]
    }
  }
}`
