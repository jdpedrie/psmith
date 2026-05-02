-- +goose Up
-- Add tool_calls JSONB to messages so an assistant turn can record the
-- tool invocations it made along with the results returned by the
-- conversations-side tool loop. Shape:
--   [
--     {
--       "id": "toolu_…",
--       "name": "web_search",
--       "input": { … model-emitted JSON args … },
--       "output": { … plugin's ExecuteTool return value … },   // optional
--       "error": "human-readable failure",                     // optional
--       "elapsed_ms": 412,
--       "provider_opaque": "..."   // Gemini thoughtSignature, optional
--     },
--     …
--   ]
-- Either output OR error is set; never both.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS tool_calls JSONB;

-- +goose Down
ALTER TABLE messages DROP COLUMN IF EXISTS tool_calls;
