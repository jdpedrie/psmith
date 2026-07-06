package main

import (
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib" // pgx driver registers as "pgx"
	"github.com/pressly/goose/v3"

	"github.com/jdpedrie/psmith/db"
)

// installCmd applies the embedded goose migrations to the configured
// database. Replaces `make migrate-up` for end-user setup; the make
// target stays for development iteration on migration files.
//
// Flags:
//
//	-db DSN     database URL (default: $DATABASE_URL or the standard
//	            local dev DSN — same default as `useradd`)
//	-status     print migration status without applying anything
//	-target N   migrate up to a specific version (default: latest)
//
// On success prints "applied N migrations (now at version V)" or
// "already at version V, no changes". Non-zero exit means the database
// wasn't migrated; the goose error gets surfaced verbatim.
func installCmd(args []string) int {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), `Usage: psmith install [flags]

Apply embedded schema migrations to the configured psmithd database.
The database itself must already exist (create it via your Postgres
provisioning of choice — docker, psql -c "CREATE DATABASE …", etc).

Re-running install on an already-migrated database is a no-op; safe
to wire into deploy scripts.

Flags:
`)
		fs.PrintDefaults()
	}

	dsn := fs.String("db", "", "postgres URL (default: $DATABASE_URL or local dev)")
	statusOnly := fs.Bool("status", false, "show migration status without applying")
	target := fs.Int64("target", -1, "migrate up to this version (default: latest)")

	if err := fs.Parse(args); err != nil {
		return 2
	}

	dbURL := *dsn
	if dbURL == "" {
		dbURL = os.Getenv("PSMITH_DSN")
	}
	if dbURL == "" {
		dbURL = os.Getenv("DATABASE_URL")
	}
	if dbURL == "" {
		dbURL = defaultDSN
	}

	sqlDB, err := sql.Open("pgx", dbURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "psmith install: open database: %v\n", err)
		return 1
	}
	defer sqlDB.Close()
	if err := sqlDB.Ping(); err != nil {
		fmt.Fprintf(os.Stderr, "psmith install: connect: %v\n", err)
		fmt.Fprintf(os.Stderr, "  (target: %s)\n", redactDSN(dbURL))
		return 1
	}

	// Extension preflight runs BEFORE migrations because CREATE
	// EXTENSION needs CREATE-on-database privilege the migration
	// runner may not have (the pgvector extension is untrusted, so
	// non-superusers can't install it via a plain migration).
	// Idempotent — `IF NOT EXISTS` means a second install run is a
	// no-op, and a pre-installed extension surfaces a friendly
	// "already installed, continuing" path.
	if err := ensureExtensions(sqlDB); err != nil {
		fmt.Fprintf(os.Stderr, "psmith install: ensure extensions: %v\n", err)
		return 1
	}

	goose.SetBaseFS(db.Migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		fmt.Fprintf(os.Stderr, "psmith install: set dialect: %v\n", err)
		return 1
	}
	// Quiet goose's per-statement chatter; we surface a single summary
	// line at the end.
	goose.SetLogger(goose.NopLogger())

	if *statusOnly {
		// Status renders to stdout; restore the default logger so the
		// rendered table is visible.
		goose.SetLogger(stdLogger{})
		if err := goose.Status(sqlDB, "migrations"); err != nil {
			fmt.Fprintf(os.Stderr, "psmith install: status: %v\n", err)
			return 1
		}
		return 0
	}

	before, err := goose.GetDBVersion(sqlDB)
	if err != nil {
		fmt.Fprintf(os.Stderr, "psmith install: read current version: %v\n", err)
		return 1
	}

	if *target >= 0 {
		if err := goose.UpTo(sqlDB, "migrations", *target); err != nil {
			fmt.Fprintf(os.Stderr, "psmith install: %v\n", err)
			return 1
		}
	} else {
		if err := goose.Up(sqlDB, "migrations"); err != nil {
			fmt.Fprintf(os.Stderr, "psmith install: %v\n", err)
			return 1
		}
	}

	after, err := goose.GetDBVersion(sqlDB)
	if err != nil {
		fmt.Fprintf(os.Stderr, "psmith install: read post-migrate version: %v\n", err)
		return 1
	}

	if before == after {
		fmt.Printf("already at migration %d, no changes\n", after)
	} else {
		fmt.Printf("applied %d migration(s); now at version %d\n", after-before, after)
	}
	return 0
}

// redactDSN strips the password component from a postgres URL so the
// connect-failure message is safe to drop into logs / paste into chat.
// Best-effort — non-URL DSNs (key=value form) are returned untouched.
func redactDSN(dsn string) string {
	const scheme = "postgres://"
	if !strings.HasPrefix(dsn, scheme) {
		return dsn
	}
	rest := dsn[len(scheme):]
	at := strings.LastIndex(rest, "@")
	if at < 0 {
		return dsn
	}
	authority := rest[:at]
	colon := strings.Index(authority, ":")
	if colon < 0 {
		return dsn
	}
	return scheme + authority[:colon] + ":***" + rest[at:]
}

// stdLogger satisfies goose.Logger by forwarding to fmt. Used for the
// -status path where we want goose's table output verbatim.
type stdLogger struct{}

func (stdLogger) Fatalf(format string, v ...any) {
	fmt.Fprintf(os.Stderr, format, v...)
	os.Exit(1)
}
func (stdLogger) Printf(format string, v ...any) {
	fmt.Printf(format, v...)
}

// Compile-time check: the Goose error wrapping above only matters if
// goose's error type is comparable. errors.Is over *fs.PathError fits
// the bill; this assertion is just defensive scaffolding for any future
// "no migrations found" handling we want to special-case.
var _ = errors.Is

// requiredExtensions are PostgreSQL extensions psmithd depends on at
// runtime. The migration layer is allowed to assume each of these
// exists in the target database; ensureExtensions installs them
// before the first migration runs so a fresh install is still one-
// shot.
var requiredExtensions = []string{
	// pgvector — message embeddings + semantic search.
	"vector",
}

// ensureExtensions runs `CREATE EXTENSION IF NOT EXISTS` for each
// required extension. Already-installed extensions are silent no-ops.
// Returns a descriptive error if the connected user lacks privilege
// (the operator either flips the user to superuser or pre-installs
// the extensions via a separate superuser connection).
func ensureExtensions(db *sql.DB) error {
	for _, name := range requiredExtensions {
		if _, err := db.Exec(`CREATE EXTENSION IF NOT EXISTS ` + name); err != nil {
			return fmt.Errorf(
				"extension %q: %w (install it once as a superuser, "+
					"then re-run `psmith install`)", name, err)
		}
	}
	return nil
}
