package anthropic

import (
	"context"
	"fmt"

	sdk "github.com/anthropics/anthropic-sdk-go"

	"github.com/jdpedrie/spalt/internal/providers"
)

// CountTokens calls Anthropic's /v1/messages/count_tokens endpoint and
// returns the input-token total for the given prefix. Used by the UI to
// drive compaction decisions before a turn is actually sent.
func (d *Driver) CountTokens(ctx context.Context, modelID string, messages []providers.WireMessage) (int, error) {
	systemBlocks, msgs, err := translateMessages(messages)
	if err != nil {
		return 0, err
	}

	params := sdk.MessageCountTokensParams{
		Model:    sdk.Model(modelID),
		Messages: msgs,
	}
	if len(systemBlocks) > 0 {
		params.System = sdk.MessageCountTokensParamsSystemUnion{
			OfTextBlockArray: systemBlocks,
		}
	}

	resp, err := d.client.Messages.CountTokens(ctx, params)
	if err != nil {
		return 0, fmt.Errorf("anthropic: count_tokens: %w", err)
	}
	return int(resp.InputTokens), nil
}
