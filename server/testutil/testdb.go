// Package testutil provides test helpers — primarily a per-test isolated
// Postgres database via pgtestdb.
package testutil

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib" // register "pgx" with database/sql for pgtestdb
	"github.com/peterldowns/pgtestdb"
	"github.com/peterldowns/pgtestdb/migrators/goosemigrator"
)

// goosemigrator uses fs.Sub against its FS, which rejects absolute paths.
// Wrap the migrations directory as its own DirFS root and migrate from ".".

// Pool returns a *pgxpool.Pool backed by a fresh, migrated database for this
// test. Each test gets its own database; pgtestdb handles cleanup.
//
// Connection details default to the local pgvector/pgvector:pg16 container
// and can be overridden via PGTESTDB_HOST/PORT/USER/PASSWORD/DB env vars.
func Pool(t *testing.T) *pgxpool.Pool {
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

	migrator := goosemigrator.New(".", goosemigrator.WithFS(os.DirFS(migrationsDir())))
	perTest := pgtestdb.Custom(t, conf, migrator)

	pool, err := pgxpool.New(context.Background(), perTest.URL())
	if err != nil {
		t.Fatalf("create pgxpool: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

// migrationsDir resolves the absolute path to db/migrations relative to this
// source file, independent of the test's working directory.
func migrationsDir() string {
	_, here, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(here), "..", "..", "db", "migrations")
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
