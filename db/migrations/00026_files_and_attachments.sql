-- +goose Up
-- Per-user content-addressed file storage. Bytes live on the storage
-- backend (filesystem in v1; S3 / blob-store later) at
-- $REEVE_DATA_DIR/files/{user_id}/{sha256}; this table is the public
-- handle the rest of the system references.
--
-- No cross-user dedup: identical bytes from two users produce two
-- rows and two physical files. Within a single user, the UNIQUE
-- (user_id, sha256) constraint dedups re-uploads naturally.
CREATE TABLE IF NOT EXISTS files (
    id                UUID        PRIMARY KEY,
    user_id           UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256            TEXT        NOT NULL,
    mime_type         TEXT        NOT NULL,
    size_bytes        BIGINT      NOT NULL,
    original_filename TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, sha256)
);

CREATE INDEX IF NOT EXISTS files_user_created_at
    ON files (user_id, created_at DESC);

-- Per-message attachment fan-out. message_attachments.ordinal preserves
-- the order the user (or model) attached the files; readers iterate
-- in PK order and the driver-translation layer preserves that order
-- when emitting provider content blocks.
--
-- role_hint distinguishes provenance: 'user_supplied' (uploaded by
-- the user from the composer), 'tool_result' (returned by a tool
-- call), 'model_generated' (assistant emitted via image-gen), or
-- 'compressed_reference' (compression summary kept a reference back
-- to a pre-compression file so the recall_attachment plugin can
-- re-fetch it). The hint drives both the UI's provenance badge and
-- the GC retention check — files referenced ANY way (including via
-- compressed_reference) stay alive.
CREATE TABLE IF NOT EXISTS message_attachments (
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    ordinal    INT  NOT NULL,
    file_id    UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK (kind IN ('image', 'audio', 'document', 'video')),
    role_hint  TEXT NOT NULL DEFAULT 'user_supplied'
        CHECK (role_hint IN ('user_supplied', 'tool_result', 'model_generated', 'compressed_reference')),
    PRIMARY KEY (message_id, ordinal)
);

CREATE INDEX IF NOT EXISTS message_attachments_file
    ON message_attachments (file_id);

-- +goose Down
DROP INDEX IF EXISTS message_attachments_file;
DROP TABLE IF EXISTS message_attachments;
DROP INDEX IF EXISTS files_user_created_at;
DROP TABLE IF EXISTS files;
