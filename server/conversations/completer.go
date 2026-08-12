package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/pluginapi/host"
	"github.com/jdpedrie/psmith/server/providerkit"
	"github.com/jdpedrie/psmith/server/providers"
)

// pluginCompleter implements host.Completer for plugins that need to ask a
// model a question outside a turn.
//
// The service owns the pieces this needs — the queries, the cipher that
// unseals api keys, the driver catalog — so it implements the interface rather
// than handing a plugin the parts and letting it assemble three upstream API
// shapes on its own.
//
// Scoped to one user at construction. A plugin cannot widen that by passing
// different ids, the same guarantee the state store makes.
type pluginCompleter struct {
	svc    *Service
	userID uuid.UUID
}

// Complete drains the driver's chunk channel into a string. Drivers are
// streaming-only, so a "synchronous" call means reading the stream to
// completion here rather than involving the supervisor: nothing is persisted,
// nothing appears in a transcript, and no run row is created.
func (c *pluginCompleter) Complete(
	ctx context.Context,
	providerID, modelID, system, user string,
	maxTokens int,
) (string, error) {
	if providerID == "" || modelID == "" {
		return "", host.ErrNoCompleter
	}
	pid, err := uuid.Parse(providerID)
	if err != nil {
		return "", host.ErrNoCompleter
	}
	// Scoped to the conversation's owner, so a plugin cannot name any provider
	// id and spend someone else's credentials. The opener enforces it.
	stateless, _, err := c.svc.opener().OpenStateless(ctx, pid, c.userID)
	if err != nil {
		if errors.Is(err, providerkit.ErrNotFound) || errors.Is(err, providerkit.ErrNotStateless) {
			return "", host.ErrNoCompleter
		}
		return "", err
	}

	req := providers.SendRequest{
		ModelID: modelID,
		Messages: []providers.WireMessage{
			{Role: "system", Content: system},
			{Role: "user", Content: user},
		},
	}
	if maxTokens > 0 {
		req.Settings.MaxOutputTokens = &maxTokens
	}

	src, err := stateless.Send(ctx, req)
	if err != nil {
		return "", fmt.Errorf("driver send: %w", err)
	}
	var out strings.Builder
	var sawError bool
	for ch := range src {
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
		return "", errors.New("model returned an error chunk")
	}
	return out.String(), nil
}

func (s *Service) newPluginCompleter(userID uuid.UUID) host.Completer {
	return &pluginCompleter{svc: s, userID: userID}
}
