-- +goose Up
-- The "obsidian" plugin is really a general device-files plugin (an
-- Obsidian vault is the flagship use, not the identity). Rename the
-- persisted plugin_name references; the per-tool enabled keys inside
-- encrypted config blobs are normalized in code at parse time
-- (plugins/files.go newFiles).
UPDATE profile_plugins      SET plugin_name = 'files' WHERE plugin_name = 'obsidian';
UPDATE conversation_plugins SET plugin_name = 'files' WHERE plugin_name = 'obsidian';
UPDATE user_plugin_settings SET plugin_name = 'files' WHERE plugin_name = 'obsidian';

-- +goose Down
UPDATE profile_plugins      SET plugin_name = 'obsidian' WHERE plugin_name = 'files';
UPDATE conversation_plugins SET plugin_name = 'obsidian' WHERE plugin_name = 'files';
UPDATE user_plugin_settings SET plugin_name = 'obsidian' WHERE plugin_name = 'files';
