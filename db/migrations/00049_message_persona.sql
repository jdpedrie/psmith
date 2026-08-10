-- +goose Up
-- Optional speaker attribution for a message.
--
-- NULL means the ordinary case: one assistant, rendered as "Assistant" by
-- clients. A value names the persona that produced the row, which is what
-- makes a council conversation legible on both sides of the wire.
--
-- The column does two jobs deliberately. history.Build renders it into the
-- outgoing wire content as a speaker tag, so the model can tell its
-- co-panelists apart; clients render it as the message's name, so the user
-- can. Keeping one source for both means the name a persona answers to and
-- the name the user reads can never drift.
--
-- persona_index is the palette slot, not a color. The server never picks
-- colors: themes own their own persona palettes and the client resolves the
-- index against the active one, so a council authored under one theme
-- renders correctly under another. NULL index means default styling.
--
-- Stored rather than derived from plugin state because attribution has to
-- outlive the plugin: detach the council plugin from a profile and the
-- transcript still says who said what.
ALTER TABLE messages
    ADD COLUMN persona       TEXT,
    ADD COLUMN persona_index INTEGER;

-- +goose Down
ALTER TABLE messages
    DROP COLUMN persona,
    DROP COLUMN persona_index;
