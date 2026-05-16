-- +goose Up
-- One-shot flag tracking whether a user has had the built-in system
-- profile templates ("Personal Assistant", "Reeve Manager", …) inserted
-- into their profile list.
--
-- Seeded false on every existing row so first-login after this
-- migration backfills the templates exactly once. After seeding, the
-- profiles are regular user-owned rows: the user can rename them, edit
-- their plugin pipeline, or delete them. Deleting does NOT re-seed —
-- the flag stays true so the system never resurrects a profile the
-- user explicitly removed.
ALTER TABLE users ADD COLUMN system_profiles_seeded BOOLEAN NOT NULL DEFAULT FALSE;

-- +goose Down
ALTER TABLE users DROP COLUMN system_profiles_seeded;
