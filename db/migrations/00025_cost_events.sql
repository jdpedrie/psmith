-- +goose Up
-- Append-only ledger of every cost-incurring event, keyed by the
-- configured provider that ran it. Currently sourced exclusively from
-- assistant + compression_summary message materialisation; future
-- non-message costs (embedding calls, tool-call surcharges, etc.)
-- write into the same table.
--
-- No backfill — the ledger starts from now. Historical message-level
-- costs continue to live on messages.* and aren't aggregated into the
-- ledger after-the-fact; that aligns with "everything that costs money
-- going forward is per-provider summable here."
CREATE TABLE IF NOT EXISTS cost_events (
    id            BIGSERIAL PRIMARY KEY,
    provider_id   UUID NOT NULL REFERENCES user_model_providers(id) ON DELETE CASCADE,
    model_id      TEXT NOT NULL,
    amount_usd    NUMERIC(20, 10) NOT NULL,
    -- Optional pointer back to the message that triggered the event.
    -- ON DELETE SET NULL so deleting a message doesn't erase the
    -- accounting record — the user still spent that money.
    message_id    UUID REFERENCES messages(id) ON DELETE SET NULL,
    occurred_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS cost_events_provider_occurred_at
    ON cost_events (provider_id, occurred_at DESC);

-- +goose Down
DROP INDEX IF EXISTS cost_events_provider_occurred_at;
DROP TABLE IF EXISTS cost_events;
