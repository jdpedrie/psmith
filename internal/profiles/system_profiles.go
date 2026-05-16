package profiles

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/plugins"
)

// System profile prose lives in seeds/*.md so reviewers can read it
// without scrolling through string literals. Each file is a YAML-
// frontmatter header (optional) plus a Markdown body — see SeedDoc
// for the parsed shape. Embedded at build time so there's no
// filesystem dependency at runtime; parse failures panic on import
// so a malformed seed can't ship as a built binary.

//go:embed seeds/personal_assistant.md
var personalAssistantSeedRaw string

//go:embed seeds/reeve_manager.md
var reeveManagerSeedRaw string

var (
	personalAssistantSeed = mustParseSeed(personalAssistantSeedRaw)
	reeveManagerSeed      = mustParseSeed(reeveManagerSeedRaw)
)

// SystemProfileTemplate is one entry in the static catalog of profiles
// that get materialised as user-owned rows on first login. After
// seeding the user can edit, rename, or delete them like any other
// profile — the system never resurrects a deleted system profile (the
// users.system_profiles_seeded flag is a one-shot, not a per-template
// presence check).
type SystemProfileTemplate struct {
	Name          string
	Description   string
	SystemMessage string
	// Optional opening assistant message. When non-empty, the seeder
	// will (separately, after profile insert) need to know about it for
	// snapshotting into conversations — for now this is just held on
	// the row for proto bridging. The actual welcome-on-conversation-
	// create happens in internal/conversations on every new convo.
	WelcomeMessage string
	// Plugins listed in execution order; index 0 runs first.
	Plugins []SystemProfilePlugin
}

// SystemProfilePlugin is one entry in a system profile's pipeline.
// Config carries the JSON shape the plugin's constructor accepts;
// pass `nil` for plugins that take no config.
type SystemProfilePlugin struct {
	Name   string
	Config json.RawMessage
}

// SystemProfileTemplates is the canonical catalog. Adding a new entry
// here automatically affects every user who hasn't yet been seeded;
// it does NOT backfill existing seeded users (we'd need a separate
// migration-style mechanism for that — out of scope for v1).
var SystemProfileTemplates = []SystemProfileTemplate{
	{
		Name:           "Personal Assistant",
		Description:    "General-purpose assistant for everyday tasks. Defaults to clear, concise answers and stays grounded in current date/time/locale.",
		SystemMessage:  personalAssistantSeed.SystemMessage,
		WelcomeMessage: personalAssistantSeed.WelcomeMessage,
		Plugins: []SystemProfilePlugin{
			// basic_grounding teaches the model "today is X" and similar
			// per-turn facts. Defaults are sensible — date/time + locale
			// + platform on, location off (location triggers OS prompt).
			{Name: plugins.BasicGroundingName, Config: json.RawMessage(`{}`)},
		},
	},
	{
		Name:           "Reeve Manager",
		Description:    "Walks you through configuring Reeve — providers, models, profiles, plugins — using the local management API.",
		SystemMessage:  reeveManagerSeed.SystemMessage,
		WelcomeMessage: reeveManagerSeed.WelcomeMessage,
		Plugins: []SystemProfilePlugin{
			// In-process MCP transport — talks to this Reeve instance's
			// own /mcp surface without a token, port, or HTTP round-trip.
			// The dispatcher is registered at server startup; without it,
			// the plugin construction succeeds but tool calls fail with
			// a clear "not registered" error.
			{Name: plugins.MCPName, Config: json.RawMessage(`{"transport":"inproc"}`)},
			// lettered_choices makes the assistant emit A/B/C choice
			// blocks at decision points — perfect for a step-by-step
			// configuration walkthrough.
			{Name: plugins.LetteredChoicesName, Config: json.RawMessage(`{}`)},
		},
	},
}

// BackfillSystemProfiles runs SeedSystemProfiles for every user whose
// `system_profiles_seeded` flag is still false. Intended for cmd/reeved
// startup so existing accounts pick up newly-added templates on next
// restart, without waiting for each user to log in. Failures on
// individual users are logged via the slog default and don't abort
// the loop — one bad row shouldn't block server start.
func BackfillSystemProfiles(
	ctx context.Context,
	pool *pgxpool.Pool,
	queries *store.Queries,
	cipher crypto.Cipher,
) error {
	ids, err := queries.ListUnseededUserIDs(ctx)
	if err != nil {
		return fmt.Errorf("backfill system profiles: list: %w", err)
	}
	for _, id := range ids {
		if err := SeedSystemProfiles(ctx, pool, queries, cipher, id); err != nil {
			// Log and continue — a failed seed for one user shouldn't
			// block server startup or block other users from getting
			// their templates.
			slog.Default().Warn("backfill system profiles: per-user seed failed",
				"err", err, "user_id", id)
		}
	}
	return nil
}

// SeedSystemProfiles inserts the SystemProfileTemplates as user-owned
// rows for `userID`, then marks the user as seeded so subsequent calls
// are a no-op. Idempotent: a user who's been seeded before short-
// circuits on the flag check.
//
// Safe to call from a hot path (e.g. login). Returns nil with no DB
// activity when the flag is already set.
//
// All inserts run in a single transaction so a partial failure leaves
// the user un-seeded (flag stays false), and the next call retries
// the whole thing.
func SeedSystemProfiles(
	ctx context.Context,
	pool *pgxpool.Pool,
	queries *store.Queries,
	cipher crypto.Cipher,
	userID uuid.UUID,
) error {
	user, err := queries.GetUserByID(ctx, userID)
	if err != nil {
		return fmt.Errorf("seed system profiles: lookup user: %w", err)
	}
	if user.SystemProfilesSeeded {
		return nil
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("seed system profiles: begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	qtx := queries.WithTx(tx)

	// Build the set of profile names the user already has so we don't
	// duplicate a template the user already created by hand (the
	// motivating case: existing users whose "Personal Assistant" predates
	// this seeding mechanism). Name match is the lightest reasonable
	// signal — system messages and plugin pipelines diverge over time as
	// the user customizes, so a content match would be brittle.
	existing, err := qtx.ListProfilesByUser(ctx, userID)
	if err != nil {
		return fmt.Errorf("seed system profiles: list existing: %w", err)
	}
	have := make(map[string]store.Profile, len(existing))
	for _, p := range existing {
		have[p.Name] = p
	}

	for _, tpl := range SystemProfileTemplates {
		if existing, ok := have[tpl.Name]; ok {
			// Profile already present — don't touch the customizable
			// fields (system message, plugin pipeline, description),
			// but backfill an empty welcome_message from the template
			// so existing seeded profiles pick up new welcomes without
			// the user having to edit them by hand. If the user has
			// customized welcome_message themselves (non-null), leave
			// it alone.
			if existing.WelcomeMessage == nil && tpl.WelcomeMessage != "" {
				w := tpl.WelcomeMessage
				if err := qtx.UpdateProfileWelcomeMessage(ctx, store.UpdateProfileWelcomeMessageParams{
					ID:             existing.ID,
					WelcomeMessage: &w,
				}); err != nil {
					return fmt.Errorf("seed system profiles: %s: backfill welcome: %w", tpl.Name, err)
				}
			}
			continue
		}
		if err := insertSystemProfile(ctx, qtx, cipher, userID, tpl); err != nil {
			return fmt.Errorf("seed system profiles: %s: %w", tpl.Name, err)
		}
	}

	if err := qtx.MarkSystemProfilesSeeded(ctx, userID); err != nil {
		return fmt.Errorf("seed system profiles: mark seeded: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("seed system profiles: commit: %w", err)
	}
	return nil
}

func insertSystemProfile(
	ctx context.Context,
	qtx *store.Queries,
	cipher crypto.Cipher,
	userID uuid.UUID,
	tpl SystemProfileTemplate,
) error {
	id, err := uuid.NewV7()
	if err != nil {
		return err
	}
	sysMsg := tpl.SystemMessage
	var welcomePtr *string
	if tpl.WelcomeMessage != "" {
		welcome := tpl.WelcomeMessage
		welcomePtr = &welcome
	}
	if _, err := qtx.CreateProfile(ctx, store.CreateProfileParams{
		ID:             id,
		UserID:         userID,
		Name:           tpl.Name,
		Description:    tpl.Description,
		SystemMessage:  &sysMsg,
		WelcomeMessage: welcomePtr,
	}); err != nil {
		return fmt.Errorf("create profile: %w", err)
	}

	for i, sp := range tpl.Plugins {
		// Validate the config parses against the plugin's constructor
		// before persisting. A typo in a template would otherwise only
		// surface when the user first tries to send a message —
		// catching it here turns it into a build/test failure.
		if _, err := plugins.Build(sp.Name, sp.Config); err != nil {
			return fmt.Errorf("plugin[%d] %s: %w", i, sp.Name, err)
		}
		var encrypted []byte
		if len(sp.Config) > 0 {
			encrypted, err = cipher.Encrypt(sp.Config)
			if err != nil {
				return fmt.Errorf("plugin[%d] %s encrypt: %w", i, sp.Name, err)
			}
		}
		if _, err := qtx.InsertProfilePlugin(ctx, store.InsertProfilePluginParams{
			ProfileID:       id,
			Ordinal:         int32(i),
			PluginName:      sp.Name,
			ConfigEncrypted: encrypted,
		}); err != nil {
			return fmt.Errorf("plugin[%d] %s insert: %w", i, sp.Name, err)
		}
	}
	return nil
}
