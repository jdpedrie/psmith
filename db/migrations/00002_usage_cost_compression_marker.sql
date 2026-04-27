-- +goose Up

-- Token usage (raw counts from provider) on assistant messages.
ALTER TABLE messages
    ADD COLUMN input_tokens         INTEGER,
    ADD COLUMN output_tokens        INTEGER,
    ADD COLUMN cache_read_tokens    INTEGER,
    ADD COLUMN cache_write_tokens   INTEGER,
    ADD COLUMN reasoning_tokens     INTEGER,
    ADD COLUMN provider_usage_raw   JSONB;

-- Cost (computed at supervisor materialization from user_models pricing
-- snapshotted at enable time). NUMERIC(12, 6) for micro-dollar resolution.
ALTER TABLE messages
    ADD COLUMN input_cost_usd       NUMERIC(12, 6),
    ADD COLUMN output_cost_usd      NUMERIC(12, 6),
    ADD COLUMN cache_read_cost_usd  NUMERIC(12, 6),
    ADD COLUMN cache_write_cost_usd NUMERIC(12, 6),
    ADD COLUMN total_cost_usd       NUMERIC(12, 6);

-- New message role: compression_summary. Records the assistant's compression
-- output in the OLD context (with usage/cost on the row); never included in
-- wire history by the history-builder. The corresponding role=context row
-- in the NEW context carries the actual summary that future turns see.
ALTER TABLE messages
    DROP CONSTRAINT messages_role_check;
ALTER TABLE messages
    ADD CONSTRAINT messages_role_check
    CHECK (role IN ('system', 'context', 'user', 'assistant', 'compression_summary'));

-- +goose Down

ALTER TABLE messages
    DROP CONSTRAINT messages_role_check;
ALTER TABLE messages
    ADD CONSTRAINT messages_role_check
    CHECK (role IN ('system', 'context', 'user', 'assistant'));

ALTER TABLE messages
    DROP COLUMN total_cost_usd,
    DROP COLUMN cache_write_cost_usd,
    DROP COLUMN cache_read_cost_usd,
    DROP COLUMN output_cost_usd,
    DROP COLUMN input_cost_usd,
    DROP COLUMN provider_usage_raw,
    DROP COLUMN reasoning_tokens,
    DROP COLUMN cache_write_tokens,
    DROP COLUMN cache_read_tokens,
    DROP COLUMN output_tokens,
    DROP COLUMN input_tokens;
