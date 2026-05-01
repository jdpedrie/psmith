-- name: GetExplicitCache :one
SELECT * FROM explicit_caches
WHERE context_id = $1 AND provider_type = $2 AND model_id = $3;

-- name: UpsertExplicitCache :exec
INSERT INTO explicit_caches (
    context_id, provider_type, model_id, cache_ref, prefix_message_count, prefix_hash, expires_at
) VALUES (
    $1, $2, $3, $4, $5, $6, $7
) ON CONFLICT (context_id, provider_type, model_id) DO UPDATE SET
    cache_ref            = EXCLUDED.cache_ref,
    prefix_message_count = EXCLUDED.prefix_message_count,
    prefix_hash          = EXCLUDED.prefix_hash,
    created_at           = now(),
    expires_at           = EXCLUDED.expires_at;

-- name: DeleteExplicitCache :exec
DELETE FROM explicit_caches WHERE context_id = $1 AND provider_type = $2 AND model_id = $3;
