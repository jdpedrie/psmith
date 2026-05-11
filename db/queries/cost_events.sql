-- name: InsertCostEvent :exec
-- Records one cost-incurring event. Called from the stream supervisor on
-- assistant + compression_summary materialisation when total_cost_usd is
-- non-null and > 0. Errored runs still log if the provider charged
-- tokens — the user paid even if the response was junk.
INSERT INTO cost_events (
    provider_id, model_id, amount_usd, message_id
) VALUES (
    $1, $2, $3, $4
);

-- name: ListProviderCostTotals :many
-- Per-provider running totals across the ledger, optionally bounded by
-- a [since, until) occurred_at window. Drives the iOS Settings → Cost
-- screen — one row per configured provider, single dollar amount per
-- row. Sorted alphabetically by the provider's label so the list reads
-- stably across reloads. Providers with no events in the window are
-- still surfaced (LEFT JOIN with the window predicate in the JOIN ON,
-- not the WHERE — putting it in WHERE would silently drop them).
SELECT
    p.id          AS provider_id,
    p.label       AS provider_label,
    p.type        AS provider_type,
    COALESCE(SUM(c.amount_usd), 0)::NUMERIC AS total_cost_usd,
    COUNT(c.id)::BIGINT                     AS event_count
FROM user_model_providers p
LEFT JOIN cost_events c
    ON c.provider_id = p.id
   AND c.occurred_at >= COALESCE(sqlc.narg('since')::timestamptz, '-infinity'::timestamptz)
   AND c.occurred_at <  COALESCE(sqlc.narg('until')::timestamptz, 'infinity'::timestamptz)
WHERE p.user_id = $1
GROUP BY p.id, p.label, p.type
ORDER BY p.label;
