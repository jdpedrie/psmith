package main

import (
	"database/sql"
	"fmt"
	"os"
	"testing"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/peterldowns/pgtestdb"
	"github.com/pressly/goose/v3"

	psmithdb "github.com/jdpedrie/psmith/db"
)

// freshDB returns a *sql.DB pointing at an empty per-test database
// — pgtestdb.NoopMigrator skips the goose migrator that
// internal/testutil normally runs, so we land on a blank schema and
// can exercise the install path's "go from 0 → latest" branch.
//
// Before returning, runs the same extension preflight `psmith install`
// runs in production — via a separate superuser (`clark`) connection
// because pgtestdb hands out a low-privileged role that can't
// CREATE EXTENSION for untrusted extensions like `vector`. Mirrors
// the production install path: extensions first, then migrations.
func freshDB(t *testing.T) *sql.DB {
	t.Helper()
	conf := pgtestdb.Config{
		DriverName: "pgx",
		Host:       envOr("PGTESTDB_HOST", "localhost"),
		Port:       envOr("PGTESTDB_PORT", "5433"),
		User:       envOr("PGTESTDB_USER", "clark"),
		Password:   envOr("PGTESTDB_PASSWORD", "clark"),
		Database:   envOr("PGTESTDB_DB", "clark"),
		Options:    "sslmode=disable",
	}
	db := pgtestdb.New(t, conf, pgtestdb.NoopMigrator{})

	// Install required extensions as the master user (clark is the
	// docker-image-default superuser). The test's primary connection
	// stays on pgtdbuser, which mirrors the typical "migrations run
	// as the app user, extensions installed once by ops" prod setup.
	var dbname string
	if err := db.QueryRow("SELECT current_database()").Scan(&dbname); err != nil {
		t.Fatalf("get test db name: %v", err)
	}
	masterURL := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
		conf.User, conf.Password, conf.Host, conf.Port, dbname)
	master, err := sql.Open("pgx", masterURL)
	if err != nil {
		t.Fatalf("open master conn: %v", err)
	}
	defer master.Close()
	if err := ensureExtensions(master); err != nil {
		t.Fatalf("ensureExtensions: %v", err)
	}
	return db
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// applyEmbeddedMigrations mirrors the install command's core path so
// the tests don't have to invoke installCmd through its flag-parsing
// shell. goose package state is reset across calls because subsequent
// SetBaseFS/SetDialect calls overwrite the previous values.
func applyEmbeddedMigrations(t *testing.T, db *sql.DB) {
	t.Helper()
	goose.SetBaseFS(psmithdb.Migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatalf("set dialect: %v", err)
	}
	goose.SetLogger(goose.NopLogger())
	if err := goose.Up(db, "migrations"); err != nil {
		t.Fatalf("goose up: %v", err)
	}
}

func TestInstall_AppliesMigrationsToFreshDB(t *testing.T) {
	db := freshDB(t)

	goose.SetBaseFS(psmithdb.Migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatalf("set dialect: %v", err)
	}
	goose.SetLogger(goose.NopLogger())

	before, err := goose.GetDBVersion(db)
	if err != nil {
		t.Fatalf("get version (pre): %v", err)
	}
	if before != 0 {
		t.Fatalf("expected blank DB at version 0, got %d", before)
	}

	if err := goose.Up(db, "migrations"); err != nil {
		t.Fatalf("goose up: %v", err)
	}

	after, err := goose.GetDBVersion(db)
	if err != nil {
		t.Fatalf("get version (post): %v", err)
	}
	if after <= before {
		t.Fatalf("expected version to advance past %d, still at %d", before, after)
	}

	// Spot-check the schema actually landed: 00001_initial.sql creates
	// the `users` table, which every later migration depends on.
	var n int
	if err := db.QueryRow("SELECT COUNT(*) FROM users").Scan(&n); err != nil {
		t.Fatalf("query users: %v — schema didn't land", err)
	}
}

func TestInstall_NoopOnAlreadyMigrated(t *testing.T) {
	db := freshDB(t)
	applyEmbeddedMigrations(t, db)

	before, err := goose.GetDBVersion(db)
	if err != nil {
		t.Fatalf("get version (pre): %v", err)
	}

	if err := goose.Up(db, "migrations"); err != nil {
		t.Fatalf("second goose up: %v", err)
	}

	after, err := goose.GetDBVersion(db)
	if err != nil {
		t.Fatalf("get version (post): %v", err)
	}
	if before != after {
		t.Fatalf("expected no-op on second up, but version moved %d → %d", before, after)
	}
}

func TestInstall_UpToTargetVersion(t *testing.T) {
	db := freshDB(t)

	goose.SetBaseFS(psmithdb.Migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatalf("set dialect: %v", err)
	}
	goose.SetLogger(goose.NopLogger())

	// Apply only through the very first migration; verify version
	// matches and a later-only table doesn't yet exist. 00001_initial
	// creates `users`; 00004_profile_plugins creates `profile_plugins`.
	if err := goose.UpTo(db, "migrations", 1); err != nil {
		t.Fatalf("goose up-to 1: %v", err)
	}
	v, err := goose.GetDBVersion(db)
	if err != nil {
		t.Fatalf("get version: %v", err)
	}
	if v != 1 {
		t.Fatalf("expected version 1, got %d", v)
	}

	var exists bool
	if err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'profile_plugins')`).Scan(&exists); err != nil {
		t.Fatalf("schema query: %v", err)
	}
	if exists {
		t.Fatal("profile_plugins table should not exist at version 1")
	}
}

func TestRedactDSN(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"with password", "postgres://user:secret@host:5432/db", "postgres://user:***@host:5432/db"},
		{"no password", "postgres://user@host:5432/db", "postgres://user@host:5432/db"},
		{"no userinfo", "postgres://host:5432/db", "postgres://host:5432/db"},
		{"key=value form passes through", "host=localhost user=clark password=secret dbname=clark", "host=localhost user=clark password=secret dbname=clark"},
		{"empty", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := redactDSN(tc.in)
			if got != tc.want {
				t.Errorf("redactDSN(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
