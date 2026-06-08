-- +goose Up
--
-- Audit log of every device-tool call (server-side broker invoked +
-- client-side handler executed + result returned). One row per call;
-- written by the conversations service on each broker completion.
-- Surfaces in two places:
--
--   1. Per-conversation: the assistant message that emitted the
--      tool_use links to the row via message_id (settable when
--      the materialised assistant row exists at write time, NULL
--      otherwise — we don't block the call to wait for it).
--
--   2. Per-user: Settings → Device tool activity scrolls through
--      every call the user's connected devices have made, sorted
--      recent-first.
--
-- Retention is indefinite for v1 — the table is small (one row per
-- model-initiated tool call) and pruning policy is a future
-- concern.

CREATE TABLE device_tool_calls (
    id              UUID PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    -- Optional pointer to the assistant message that fired the
    -- tool_use. ON DELETE SET NULL because deleting a message
    -- shouldn't erase the audit trail — the user still wants to
    -- see what the model did.
    message_id      UUID REFERENCES messages(id) ON DELETE SET NULL,
    tool_name       TEXT NOT NULL,
    -- The model's input + the client's output, persisted verbatim
    -- so the activity viewer can show exactly what crossed the
    -- wire. NULL output when status != 'ok'.
    input_json      JSONB,
    output_json     JSONB,
    -- Status enumerates the broker's outcome: 'ok' means the
    -- client returned a result; 'error' is anything the client
    -- surfaced via response.error (permission denied, OS failure,
    -- malformed input — the client's choice of granularity);
    -- 'timeout' is the broker's per-tool deadline firing without
    -- a response.
    status          TEXT NOT NULL CHECK (status IN ('ok', 'error', 'timeout')),
    error_message   TEXT,
    invoked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Per-user activity scroll: settings page sorts recent first,
-- paginated.
CREATE INDEX device_tool_calls_user_invoked_at
    ON device_tool_calls (user_id, invoked_at DESC);

-- Per-conversation filter for the future "what did the model do
-- in this conversation?" affordance.
CREATE INDEX device_tool_calls_conversation_invoked_at
    ON device_tool_calls (conversation_id, invoked_at DESC);

-- +goose Down
DROP INDEX IF EXISTS device_tool_calls_conversation_invoked_at;
DROP INDEX IF EXISTS device_tool_calls_user_invoked_at;
DROP TABLE IF EXISTS device_tool_calls;
