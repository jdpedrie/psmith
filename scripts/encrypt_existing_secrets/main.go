// One-off migration: re-encrypt any rows in user_model_providers /
// profile_plugins / user_plugin_settings whose `config` column is
// plaintext into the `config_encrypted` column under the master key in
// REEVE_MASTER_KEY, then NULL out the plaintext column.
//
// Idempotent: rows where `config_encrypted` is already populated are
// skipped. Run as many times as you want; the second run is a no-op.
//
// Usage:
//
//	REEVE_DSN=... REEVE_MASTER_KEY=$(reeve genkey) \
//	  go run ./scripts/encrypt_existing_secrets
//
// Will print one line per table summarising rows touched.
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/jdpedrie/reeve/internal/crypto"
)

// tableSpec describes the SELECT shape for one table — its key columns
// and the WHERE clause used to scope the UPDATE that lands the
// encrypted blob. Every table here has identical config /
// config_encrypted columns; they differ only in primary-key shape.
type tableSpec struct {
	name      string
	keyCols   []string // PK column names, in order
	pkScanPtr func() ([]any, []any)
}

func main() {
	dsn := os.Getenv("REEVE_DSN")
	if dsn == "" {
		log.Fatal("REEVE_DSN is required")
	}

	keyBytes, ephemeral, err := crypto.LoadKey()
	if err != nil {
		log.Fatalf("load master key: %v", err)
	}
	if keyBytes == nil {
		log.Fatalf("REEVE_MASTER_KEY is required (set to a base64-encoded 32-byte key — `reeve genkey` mints one)")
	}
	if ephemeral {
		log.Fatal("refusing to encrypt under an ephemeral dev-auto key — set REEVE_MASTER_KEY explicitly")
	}
	cipher, err := crypto.NewAESGCM(keyBytes)
	if err != nil {
		log.Fatalf("init cipher: %v", err)
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	tables := []tableSpec{
		{name: "user_model_providers", keyCols: []string{"id"}},
		{name: "profile_plugins", keyCols: []string{"profile_id", "ordinal"}},
		{name: "user_plugin_settings", keyCols: []string{"user_id", "plugin_name"}},
	}
	for _, t := range tables {
		n, err := encryptTable(ctx, pool, cipher, t)
		if err != nil {
			log.Fatalf("encrypt %s: %v", t.name, err)
		}
		fmt.Printf("%s: encrypted %d rows\n", t.name, n)
	}
}

// encryptTable walks every row of `t.name` whose config is plaintext
// (config_encrypted IS NULL, config IS NOT NULL), encrypts it under
// `cipher`, and updates the row in-place. PK shape is parameterised so
// the same code handles single-column and composite keys.
func encryptTable(ctx context.Context, pool *pgxpool.Pool, cipher crypto.Cipher, t tableSpec) (int, error) {
	keyList := joinCols(t.keyCols, ", ")
	// Cast jsonb to text so pgx scans into a string; the *any path
	// gives us a map[string]any which we'd then have to re-marshal —
	// going through ::text preserves the canonical JSON byte shape
	// the cipher stored before the rollover.
	selectSQL := fmt.Sprintf(
		`SELECT %s, config::text FROM %s WHERE config_encrypted IS NULL AND config IS NOT NULL`,
		keyList, t.name,
	)
	whereClause, placeholders := keyWhereClause(t.keyCols, 2) // $1 = ciphertext
	updateSQL := fmt.Sprintf(
		`UPDATE %s SET config_encrypted = $1, config = NULL WHERE %s`,
		t.name, whereClause,
	)
	_ = placeholders // documents the $2..$N positions for readers

	rows, err := pool.Query(ctx, selectSQL)
	if err != nil {
		return 0, fmt.Errorf("select: %w", err)
	}

	type job struct {
		keys  []any
		plain []byte
	}
	var jobs []job
	for rows.Next() {
		// Allocate one any per key column + one for the config blob.
		// Pass pointer-to-any to Scan; pgx will fill in the dynamic
		// value (UUID, int32, string) without a per-column type switch.
		dest := make([]any, len(t.keyCols)+1)
		holders := make([]any, len(t.keyCols)+1)
		for i := range dest {
			holders[i] = &dest[i]
		}
		if err := rows.Scan(holders...); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan: %w", err)
		}
		keys := make([]any, len(t.keyCols))
		copy(keys, dest[:len(t.keyCols)])
		raw := dest[len(t.keyCols)]
		var plain []byte
		switch v := raw.(type) {
		case string:
			plain = []byte(v)
		case []byte:
			plain = v
		default:
			rows.Close()
			return 0, fmt.Errorf("scan: config column unexpected type %T", raw)
		}
		jobs = append(jobs, job{keys: keys, plain: plain})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("rows: %w", err)
	}

	var n int
	for _, j := range jobs {
		enc, err := cipher.Encrypt(j.plain)
		if err != nil {
			return n, fmt.Errorf("encrypt row %v: %w", j.keys, err)
		}
		args := append([]any{enc}, j.keys...)
		tag, err := pool.Exec(ctx, updateSQL, args...)
		if err != nil {
			return n, fmt.Errorf("update row %v: %w", j.keys, err)
		}
		if tag.RowsAffected() != 1 {
			return n, fmt.Errorf("update row %v: %d rows affected, want 1", j.keys, tag.RowsAffected())
		}
		n++
	}
	return n, nil
}

func joinCols(cols []string, sep string) string {
	out := ""
	for i, c := range cols {
		if i > 0 {
			out += sep
		}
		out += c
	}
	return out
}

// keyWhereClause builds "col1 = $start AND col2 = $start+1 ..." for
// the given key columns, returning the clause text plus the list of
// placeholder strings (handy for assertions / docs).
func keyWhereClause(cols []string, start int) (string, []string) {
	clause := ""
	holders := make([]string, len(cols))
	for i, c := range cols {
		holders[i] = fmt.Sprintf("$%d", start+i)
		if i > 0 {
			clause += " AND "
		}
		clause += fmt.Sprintf("%s = %s", c, holders[i])
	}
	return clause, holders
}
