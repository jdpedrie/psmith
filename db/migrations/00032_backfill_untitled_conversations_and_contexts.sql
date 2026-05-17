-- +goose Up
-- Backfill the derived "ProfileName (YYYY-MM-DD)" title for every
-- conversation + context that still has a NULL or empty title. Going
-- forward, internal/conversations/titles.MaybeGenerateTitle writes
-- this same fallback whenever generation is disabled or fails — this
-- migration brings existing rows into the same shape so the sidebar
-- + headers stop showing "Untitled" everywhere.
--
-- Apple Foundation client-side titler conversations are still
-- caught here, since their server skip-path used to leave the title
-- NULL. The client overwrites whenever it generates a real title on
-- next open. Net win: untitled-forever rows go away.

UPDATE conversations c
SET title = p.name || ' (' || to_char(c.created_at, 'YYYY-MM-DD') || ')',
    updated_at = NOW()
FROM profiles p
WHERE c.profile_id = p.id
  AND (c.title IS NULL OR c.title = '');

UPDATE contexts cx
SET title = p.name || ' (' || to_char(cx.created_at, 'YYYY-MM-DD') || ')'
FROM conversations c
JOIN profiles p ON p.id = c.profile_id
WHERE cx.conversation_id = c.id
  AND (cx.title IS NULL OR cx.title = '');

-- +goose Down
-- No-op: we can't reconstruct which titles were derived vs user-set,
-- so down-migrating shouldn't clear them. Re-running the up is
-- idempotent for new untitled rows.
SELECT 1;
