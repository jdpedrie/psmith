-- +goose Up
-- Thinking settings move from {enabled, budget_tokens} to a single effort
-- level. The budget was never a good user-facing knob: Anthropic's newer
-- models and every OpenAI-style API take a level, and the level is what
-- users reason about. Stored blobs carry the old shape under
-- call_settings.thinking at all four resolution layers; rewrite them in
-- place so nobody's profile silently loses its thinking setting.
--
-- Mapping: enabled=false becomes OFF. A budget maps to the nearest level
-- of the table drivers now derive budgets from (2048 / 8192 / 16384 /
-- 24576, split at the midpoints). enabled=true with no budget becomes
-- MEDIUM, the effort the OpenAI driver used to derive for it. A budget
-- with no enabled flag is read as a request for that level. Blobs that
-- already carry an effort are left alone, so the Up is safe to re-run.

-- +goose StatementBegin
CREATE FUNCTION psmith_thinking_effort_up(t JSONB) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN t IS NULL OR jsonb_typeof(t) <> 'object' THEN t
    WHEN t ? 'effort' THEN (t - 'enabled') - 'budget_tokens'
    WHEN (t->>'enabled') = 'false' THEN '{"effort":"THINKING_EFFORT_OFF"}'::jsonb
    WHEN (t->>'budget_tokens') IS NULL THEN
      CASE WHEN (t->>'enabled') = 'true'
           THEN '{"effort":"THINKING_EFFORT_MEDIUM"}'::jsonb
           ELSE '{}'::jsonb END
    WHEN (t->>'budget_tokens')::int < 5120  THEN '{"effort":"THINKING_EFFORT_LOW"}'::jsonb
    WHEN (t->>'budget_tokens')::int < 12288 THEN '{"effort":"THINKING_EFFORT_MEDIUM"}'::jsonb
    WHEN (t->>'budget_tokens')::int < 20480 THEN '{"effort":"THINKING_EFFORT_HIGH"}'::jsonb
    ELSE '{"effort":"THINKING_EFFORT_XHIGH"}'::jsonb
  END
$$;
-- +goose StatementEnd

UPDATE profiles
   SET default_settings = jsonb_set(default_settings, '{call_settings,thinking}',
                                    psmith_thinking_effort_up(default_settings->'call_settings'->'thinking'))
 WHERE default_settings->'call_settings'->'thinking' IS NOT NULL;

UPDATE user_models
   SET default_settings = jsonb_set(default_settings, '{call_settings,thinking}',
                                    psmith_thinking_effort_up(default_settings->'call_settings'->'thinking'))
 WHERE default_settings->'call_settings'->'thinking' IS NOT NULL;

UPDATE user_model_providers
   SET default_settings = jsonb_set(default_settings, '{call_settings,thinking}',
                                    psmith_thinking_effort_up(default_settings->'call_settings'->'thinking'))
 WHERE default_settings->'call_settings'->'thinking' IS NOT NULL;

UPDATE conversations
   SET settings = jsonb_set(settings, '{call_settings,thinking}',
                            psmith_thinking_effort_up(settings->'call_settings'->'thinking'))
 WHERE settings->'call_settings'->'thinking' IS NOT NULL;

DROP FUNCTION psmith_thinking_effort_up(JSONB);

-- +goose Down
-- Best effort back to the old shape: OFF becomes enabled=false, a level
-- becomes enabled=true with the budget the drivers derive for it.

-- +goose StatementBegin
CREATE FUNCTION psmith_thinking_effort_down(t JSONB) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN t IS NULL OR jsonb_typeof(t) <> 'object' THEN t
    WHEN NOT (t ? 'effort') THEN t
    WHEN t->>'effort' = 'THINKING_EFFORT_OFF'    THEN '{"enabled":false}'::jsonb
    WHEN t->>'effort' = 'THINKING_EFFORT_LOW'    THEN '{"enabled":true,"budget_tokens":2048}'::jsonb
    WHEN t->>'effort' = 'THINKING_EFFORT_MEDIUM' THEN '{"enabled":true,"budget_tokens":8192}'::jsonb
    WHEN t->>'effort' = 'THINKING_EFFORT_HIGH'   THEN '{"enabled":true,"budget_tokens":16384}'::jsonb
    WHEN t->>'effort' = 'THINKING_EFFORT_XHIGH'  THEN '{"enabled":true,"budget_tokens":24576}'::jsonb
    ELSE '{}'::jsonb
  END
$$;
-- +goose StatementEnd

UPDATE profiles
   SET default_settings = jsonb_set(default_settings, '{call_settings,thinking}',
                                    psmith_thinking_effort_down(default_settings->'call_settings'->'thinking'))
 WHERE default_settings->'call_settings'->'thinking' IS NOT NULL;

UPDATE user_models
   SET default_settings = jsonb_set(default_settings, '{call_settings,thinking}',
                                    psmith_thinking_effort_down(default_settings->'call_settings'->'thinking'))
 WHERE default_settings->'call_settings'->'thinking' IS NOT NULL;

UPDATE user_model_providers
   SET default_settings = jsonb_set(default_settings, '{call_settings,thinking}',
                                    psmith_thinking_effort_down(default_settings->'call_settings'->'thinking'))
 WHERE default_settings->'call_settings'->'thinking' IS NOT NULL;

UPDATE conversations
   SET settings = jsonb_set(settings, '{call_settings,thinking}',
                            psmith_thinking_effort_down(settings->'call_settings'->'thinking'))
 WHERE settings->'call_settings'->'thinking' IS NOT NULL;

DROP FUNCTION psmith_thinking_effort_down(JSONB);
