package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/term"

	"github.com/jdpedrie/reeve/internal/store"
)

const defaultDSN = "postgres://clark:clark@localhost:5433/clark?sslmode=disable"

// useraddCmd creates a user row in the reeved database. Returns the
// process exit code; main() forwards it.
//
// Flags:
//
//	-u USER       username (required)
//	-p PASS       password (optional — if omitted, prompted interactively
//	              on the controlling TTY with no echo)
//	-admin        grant admin (default true; matches the seeduser
//	              behaviour this command replaces)
//	-no-admin     equivalent to -admin=false; convenience for users
//	              who find double-negation unreadable
//	-db DSN       database URL (default: $DATABASE_URL or the
//	              standard local dev DSN)
func useraddCmd(args []string) int {
	fs := flag.NewFlagSet("useradd", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), `Usage: reeve useradd [flags]

Create a user account directly in the reeved database. Bypasses the
authenticated AuthService.CreateUser RPC, so it works against fresh
deployments before any user exists.

Flags:
`)
		fs.PrintDefaults()
	}

	username := fs.String("u", "", "username (required)")
	password := fs.String("p", "", "password (omit to be prompted with no echo)")
	admin := fs.Bool("admin", true, "grant admin")
	noAdmin := fs.Bool("no-admin", false, "shorthand for -admin=false")
	dsn := fs.String("db", "", "postgres URL (default: $DATABASE_URL or local dev)")

	if err := fs.Parse(args); err != nil {
		// flag.ContinueOnError already printed usage on error.
		return 2
	}

	if strings.TrimSpace(*username) == "" {
		fmt.Fprintln(os.Stderr, "reeve useradd: -u <username> is required")
		fs.Usage()
		return 2
	}
	if *noAdmin {
		*admin = false
	}

	pw := *password
	if pw == "" {
		var err error
		pw, err = readPasswordInteractive()
		if err != nil {
			fmt.Fprintf(os.Stderr, "reeve useradd: read password: %v\n", err)
			return 1
		}
	}
	if pw == "" {
		fmt.Fprintln(os.Stderr, "reeve useradd: empty password rejected")
		return 1
	}

	dbURL := *dsn
	if dbURL == "" {
		dbURL = os.Getenv("REEVE_DSN")
	}
	if dbURL == "" {
		dbURL = os.Getenv("DATABASE_URL")
	}
	if dbURL == "" {
		dbURL = defaultDSN
	}

	if err := createUser(*username, pw, *admin, dbURL); err != nil {
		fmt.Fprintf(os.Stderr, "reeve useradd: %v\n", err)
		return 1
	}
	role := "user"
	if *admin {
		role = "admin"
	}
	fmt.Printf("created %s %q\n", role, *username)
	return 0
}

func createUser(username, password string, admin bool, dsn string) error {
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}
	defer pool.Close()

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}
	id, err := uuid.NewV7()
	if err != nil {
		return fmt.Errorf("generate id: %w", err)
	}

	q := store.New(pool)
	if _, err := q.CreateUser(ctx, store.CreateUserParams{
		ID:           id,
		Username:     username,
		PasswordHash: string(hash),
		IsAdmin:      admin,
	}); err != nil {
		// pgx surfaces unique-constraint violations as PgError 23505.
		// Surface a friendlier message when the username is already taken.
		var pgErr *pgconnError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return fmt.Errorf("user %q already exists", username)
		}
		return fmt.Errorf("create user: %w", err)
	}
	return nil
}

// readPasswordInteractive reads a password from /dev/tty (or stdin if
// /dev/tty isn't available — e.g., piped input) with terminal echo
// disabled. Trailing newline trimmed. Empty result is allowed; the
// caller decides whether to reject.
func readPasswordInteractive() (string, error) {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		// No /dev/tty (CI, redirected stdin). Fall back to a bare
		// stdin read with no echo control — safer to fail loudly
		// than to read an echo'd password.
		if _, isTerm := isTerminal(int(os.Stdin.Fd())); !isTerm {
			return readLine(os.Stdin)
		}
		// stdin IS a terminal but /dev/tty isn't openable. Use the
		// stdin file descriptor directly.
		return readPasswordFromFD(int(os.Stdin.Fd()))
	}
	defer tty.Close()
	fmt.Fprint(tty, "password: ")
	pw, err := readPasswordFromFD(int(tty.Fd()))
	fmt.Fprintln(tty)
	return pw, err
}

func readPasswordFromFD(fd int) (string, error) {
	b, err := term.ReadPassword(fd)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// isTerminal returns (fd, true) when the file descriptor refers to a
// terminal. Wraps term.IsTerminal so the import stays scoped.
func isTerminal(fd int) (int, bool) {
	return fd, term.IsTerminal(fd)
}

func readLine(r io.Reader) (string, error) {
	var b [4096]byte
	n, err := r.Read(b[:])
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimRight(string(b[:n]), "\r\n"), nil
}

// pgconnError aliases pgconn.PgError so the SQLSTATE check below
// reads cleanly without leaking the import elsewhere.
type pgconnError = pgconn.PgError
