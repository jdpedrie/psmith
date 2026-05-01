-- name: GetGeminiCache :one
SELECT * FROM gemini_caches
WHERE context_id = $1 AND model_id = $2;

-- name: UpsertGeminiCache :exec
INSERT INTO gemini_caches (
    context_id, model_id, cache_name, prefix_message_count, prefix_hash, expires_at
) VALUES (
    $1, $2, $3, $4, $5, $6
) ON CONFLICT (context_id, model_id) DO UPDATE SET
    cache_name           = EXCLUDED.cache_name,
    prefix_message_count = EXCLUDED.prefix_message_count,
    prefix_hash          = EXCLUDED.prefix_hash,
    created_at           = now(),
    expires_at           = EXCLUDED.expires_at;

-- name: DeleteGeminiCache :exec
DELETE FROM gemini_caches WHERE context_id = $1 AND model_id = $2;
