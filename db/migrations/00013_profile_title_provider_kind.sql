-- +goose Up

-- Adds a sentinel-tag column to the profiles table that names a non-server
-- title generator. NULL = "use the configured (title_provider_id, title_model_id)"
-- as before; a non-null string names a special generator handled outside the
-- server's stateless-provider title-call path.
--
-- v1 sentinel: "apple_foundation" — the Mac client uses Apple's on-device
-- FoundationModels framework (macOS 26+) to title conversations locally, free
-- of charge. The server's auto-title hook detects this kind and skips its own
-- cloud roundtrip; the client invokes the local model and persists the title
-- via the existing UpdateConversation RPC.
--
-- This is additive: existing profiles with a configured title_provider_id keep
-- working unchanged (kind stays NULL).
ALTER TABLE profiles
    ADD COLUMN title_provider_kind TEXT;

-- +goose Down

ALTER TABLE profiles
    DROP COLUMN title_provider_kind;
