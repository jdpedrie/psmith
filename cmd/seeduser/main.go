// seeduser is a one-off helper that inserts a user directly into the DB,
// bypassing the bootstrap "no users exist" guard. Useful for adding additional
// dev accounts without going through the admin RPC.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	"github.com/jdpedrie/clark/internal/store"
)

func main() {
	username := flag.String("u", "", "username")
	password := flag.String("p", "", "password")
	admin := flag.Bool("admin", true, "grant admin")
	dbURL := flag.String("db", os.Getenv("DATABASE_URL"), "postgres URL")
	flag.Parse()

	if *username == "" || *password == "" {
		log.Fatal("usage: seeduser -u <username> -p <password> [-admin=true]")
	}
	if *dbURL == "" {
		*dbURL = "postgres://clark:clark@localhost:5433/clark?sslmode=disable"
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, *dbURL)
	if err != nil {
		log.Fatal(err)
	}
	defer pool.Close()

	q := store.New(pool)
	hash, err := bcrypt.GenerateFromPassword([]byte(*password), bcrypt.DefaultCost)
	if err != nil {
		log.Fatal(err)
	}
	id, err := uuid.NewV7()
	if err != nil {
		log.Fatal(err)
	}
	u, err := q.CreateUser(ctx, store.CreateUserParams{
		ID:           id,
		Username:     *username,
		PasswordHash: string(hash),
		IsAdmin:      *admin,
	})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("created user id=%s username=%s admin=%v\n", u.ID, u.Username, u.IsAdmin)
}
