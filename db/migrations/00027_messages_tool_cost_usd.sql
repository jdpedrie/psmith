-- +goose Up
-- Tool-side spend per assistant turn. Sum of every tool the
-- assistant called during the run that returned a `cost_usd`
-- (today: imagegen via OpenAI's images endpoint or Gemini's
-- generateContent for image output; future: any plugin that
-- can compute its API spend). Independent of input/output/cache
-- token costs, but bundled into total_cost_usd at write time so
-- the existing cost chip captures total spend without a UI
-- refactor. Nullable because pre-migration rows have no value.
ALTER TABLE messages
    ADD COLUMN tool_cost_usd numeric(12,6);

-- +goose Down
ALTER TABLE messages
    DROP COLUMN tool_cost_usd;
