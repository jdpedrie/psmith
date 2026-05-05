package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
)

// defaultTitleGuide is used when the resolved profile has title fields
// configured (provider + model) but no explicit guide. Tuned to encourage
// short, plain titles suitable for sidebar display.
const defaultTitleGuide = "Generate a 2-5 word title for this conversation. " +
	"Reply with only the title — no quotes, no punctuation, no preamble."

// maxTitleLen caps the auto-generated title length so a misbehaving model
// can't blow out the UI. Editing later (UpdateConversation / UpdateContext)
// can override.
const maxTitleLen = 80

// MaybeGenerateTitle is the supervisor's onAssistantMaterialized hook. It
// runs in a detached goroutine after each assistant turn lands; failures
// are logged but never propagate. Decides whether to generate:
//   - a conversation title (when conversation.title is currently NULL)
//   - a context title (when context.title is currently NULL AND this is the
//     first assistant turn in the context — covers initial context AND
//     post-compaction contexts)
//
// Both checks are skipped silently when the resolved profile lacks the
// title_provider_id / title_model_id fields, so this feature is opt-in.
func (s *Service) MaybeGenerateTitle(ctx context.Context, params stream.StartParams, assistantMsgID uuid.UUID) {
	conv, err := s.queries.GetConversationByID(ctx, params.ConversationID)
	if err != nil {
		s.logger.Warn("title: load conversation failed", "err", err, "conversation_id", params.ConversationID)
		return
	}
	cx, err := s.queries.GetContextByID(ctx, params.ContextID)
	if err != nil {
		s.logger.Warn("title: load context failed", "err", err, "context_id", params.ContextID)
		return
	}
	needConvTitle := conv.Title == nil || *conv.Title == ""
	needCtxTitle := cx.Title == nil || *cx.Title == ""
	if !needConvTitle && !needCtxTitle {
		return
	}
	// Only generate the context title on the FIRST assistant turn of the
	// context. Otherwise we'd regenerate (and pay) on every turn until the
	// title sticks, which is the wrong cost shape.
	if needCtxTitle {
		first, err := s.isFirstAssistantInContext(ctx, params.ContextID, assistantMsgID)
		if err != nil {
			s.logger.Warn("title: first-assistant check failed", "err", err)
			return
		}
		if !first {
			needCtxTitle = false
		}
	}
	if !needConvTitle && !needCtxTitle {
		return
	}

	// Resolve profile chain to find title_* settings.
	prof, err := s.queries.GetProfileByID(ctx, conv.ProfileID)
	if err != nil {
		s.logger.Warn("title: load profile failed", "err", err)
		return
	}
	resolved, err := profiles.Resolve(ctx, s.queries, prof)
	if err != nil {
		s.logger.Warn("title: resolve profile failed", "err", err)
		return
	}
	// Sentinel: a non-server title generator owns this profile. v1 case is
	// "apple_foundation" — the Mac client runs Apple's on-device
	// FoundationModels framework and persists the title via the existing
	// UpdateConversation RPC. Server skips its cloud roundtrip entirely.
	if resolved.TitleProviderKind != nil && *resolved.TitleProviderKind != "" {
		s.logger.Debug("title: client-side generator configured; skipping server-side generation",
			"kind", *resolved.TitleProviderKind,
			"conversation_id", params.ConversationID)
		return
	}
	if resolved.TitleProviderID == nil || resolved.TitleModelID == nil || *resolved.TitleModelID == "" {
		// Opt-in feature; profile didn't configure it.
		return
	}
	guide := defaultTitleGuide
	if resolved.TitleGuide != nil && *resolved.TitleGuide != "" {
		guide = *resolved.TitleGuide
	}

	// Build a short transcript: the most-recent user message + this
	// just-materialized assistant message. Two turns is plenty of signal
	// for a 2-5 word title.
	asst, err := s.queries.GetMessageByID(ctx, assistantMsgID)
	if err != nil {
		s.logger.Warn("title: load assistant msg failed", "err", err)
		return
	}
	var userMsg store.Message
	if asst.ParentID != nil {
		userMsg, _ = s.queries.GetMessageByID(ctx, *asst.ParentID)
	}
	transcript := s.renderTitleTranscript(userMsg, asst)
	if transcript == "" {
		return
	}

	// Generate.
	title, err := s.callTitleModel(ctx, *resolved.TitleProviderID, *resolved.TitleModelID, guide, transcript)
	if err != nil {
		s.logger.Warn("title: generation failed", "err", err)
		return
	}
	title = sanitizeTitle(title)
	if title == "" {
		s.logger.Warn("title: model returned empty/unusable title")
		return
	}

	if needConvTitle {
		if err := s.queries.UpdateConversationTitle(ctx, store.UpdateConversationTitleParams{
			ID: conv.ID, Title: &title,
		}); err != nil {
			s.logger.Warn("title: persist conversation title failed", "err", err)
		}
	}
	if needCtxTitle {
		if err := s.queries.UpdateContextTitle(ctx, store.UpdateContextTitleParams{
			ID: cx.ID, Title: &title,
		}); err != nil {
			s.logger.Warn("title: persist context title failed", "err", err)
		}
	}
}

// isFirstAssistantInContext reports whether assistantMsgID is the only
// assistant message in its context. We approximate "first by created_at"
// with "only one exists" — at the moment this hook fires, the row was just
// inserted, so if there's more than one assistant the new one is NOT the
// first.
func (s *Service) isFirstAssistantInContext(ctx context.Context, contextID uuid.UUID, assistantMsgID uuid.UUID) (bool, error) {
	all, err := s.queries.ListMessagesByContext(ctx, contextID)
	if err != nil {
		return false, err
	}
	count := 0
	for _, m := range all {
		if m.Role == roleAssistant {
			count++
			if count > 1 {
				return false, nil
			}
		}
	}
	return count == 1, nil
}

// renderTitleTranscript stitches the user → assistant pair into a tiny
// prompt body. Falls back to assistant-only when there's no parent (rare).
func (s *Service) renderTitleTranscript(user, asst store.Message) string {
	var b strings.Builder
	if user.ID != uuid.Nil && user.Content != "" {
		fmt.Fprintf(&b, "[user]: %s\n\n", user.Content)
	}
	if asst.Content != "" {
		fmt.Fprintf(&b, "[assistant]: %s", asst.Content)
	}
	return strings.TrimSpace(b.String())
}

// callTitleModel performs a synchronous, non-streaming-style call to the
// configured title provider + model. We still get a chunk channel back from
// the driver (the SDK is streaming-only), but we drain it into a string and
// return rather than involving the supervisor.
func (s *Service) callTitleModel(ctx context.Context, providerID uuid.UUID, modelID, guide, transcript string) (string, error) {
	if s.catalog == nil {
		return "", errors.New("title: catalog dep is nil")
	}
	provRow, err := s.queries.GetUserModelProvider(ctx, providerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("title provider %s not found", providerID)
		}
		return "", fmt.Errorf("load title provider: %w", err)
	}
	provCfg, err := s.resolveProviderConfig(provRow)
	if err != nil {
		return "", fmt.Errorf("decrypt title provider config: %w", err)
	}
	driver, err := providers.Build(provRow.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, provCfg)
	if err != nil {
		return "", fmt.Errorf("build title driver: %w", err)
	}
	stateless, ok := driver.(providers.StatelessProvider)
	if !ok {
		return "", fmt.Errorf("title driver %q is not a stateless provider", provRow.Type)
	}

	srcCh, err := stateless.Send(ctx, providers.SendRequest{
		ModelID: modelID,
		Messages: []providers.WireMessage{
			{Role: "system", Content: guide},
			{Role: "user", Content: transcript},
		},
	})
	if err != nil {
		return "", fmt.Errorf("title driver send: %w", err)
	}

	var out strings.Builder
	var sawError bool
	for ch := range srcCh {
		switch ch.Type {
		case providers.ChunkText:
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(ch.Payload, &p)
			out.WriteString(p.Text)
		case providers.ChunkError:
			sawError = true
		}
	}
	if sawError {
		return "", fmt.Errorf("title model returned error chunk")
	}
	return out.String(), nil
}

// sanitizeTitle trims whitespace, strips wrapping quotes a model may add,
// collapses internal whitespace, and caps length at maxTitleLen. Returns
// "" when the model produced nothing usable.
func sanitizeTitle(s string) string {
	s = strings.TrimSpace(s)
	// Strip a single layer of wrapping double or single quotes.
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
			s = strings.TrimSpace(s[1 : len(s)-1])
		}
	}
	// Collapse runs of whitespace to single spaces.
	fields := strings.Fields(s)
	s = strings.Join(fields, " ")
	if len(s) > maxTitleLen {
		s = s[:maxTitleLen]
		// Trim back to the last word boundary if a cut landed mid-word.
		if i := strings.LastIndex(s, " "); i > maxTitleLen/2 {
			s = s[:i]
		}
	}
	return s
}
