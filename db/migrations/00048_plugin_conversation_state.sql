-- +goose Up
-- Conversation-scoped plugin state, as distinct from the branch-scoped
-- kind in plugin_state.
--
-- The two are not the same thing and conflating them was the mistake this
-- corrects. plugin_state is keyed to a MESSAGE because it records what
-- happened on a branch: fork a conversation and each side owns its own
-- lineage. That is exactly right for history, and exactly wrong for
-- intent about a send that has not happened yet.
--
-- The concrete failure: a plugin holding "deliver this on the next turn"
-- in plugin_state cannot record anything on a conversation with no
-- messages, because there is no message to key to. That is the first
-- thing a user does — open a new chat, queue the context they know they
-- need, then type. Branch-scoping also gives the wrong answer here even
-- when it works, since queued-but-unsent intent belongs to the
-- conversation rather than to whichever branch happened to be current.
--
-- Keyed (plugin_name, conversation_id): one row per plugin per
-- conversation, overwritten in place. No parent-chain walk, because there
-- is no lineage to walk.
CREATE TABLE IF NOT EXISTS plugin_conversation_state (
    plugin_name     TEXT   NOT NULL,
    conversation_id UUID   NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    state_version   BIGINT NOT NULL,
    schema_version  INT    NOT NULL DEFAULT 1,
    state_json      JSONB  NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (plugin_name, conversation_id)
);

-- +goose Down
DROP TABLE IF EXISTS plugin_conversation_state;
