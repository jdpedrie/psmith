-- +goose Up
-- Per-message record of whether Reeve attached an explicit Gemini
-- cachedContents reference to the request that produced this row.
--
-- NULL  → not applicable (non-google driver, toggle off, or pre-19
--         message)
-- TRUE  → toggle was on AND we successfully looked-up-or-created a
--         cache and attached its name to the request
-- FALSE → toggle was on but no cache was attached this turn (most
--         common: prefix below the per-model minimum, so the create
--         silently failed and we sent normally)
--
-- Combined with cache_read_tokens, this gives a 4-quadrant view:
--   attached=TRUE,  read>0   → cache hit on our explicit cache
--   attached=TRUE,  read=0   → cache attached but Gemini didn't use it
--   attached=NULL,  read>0   → implicit cache hit (Gemini's automatic)
--   attached=NULL,  read=0/NULL → no caching at all

ALTER TABLE messages ADD COLUMN explicit_cache_attached BOOLEAN;

-- +goose Down
ALTER TABLE messages DROP COLUMN IF EXISTS explicit_cache_attached;
