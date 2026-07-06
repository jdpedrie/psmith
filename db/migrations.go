// Package db exposes embedded SQL assets (today: goose migrations) so
// the psmith binary can ship migrations without needing the source tree
// or an external goose install at install time.
package db

import "embed"

// Migrations is the goose-format migration set under db/migrations/.
// Consumed by `cmd/psmith install` via goose.SetBaseFS — the directory
// name "migrations" is what callers pass to goose.Up.
//
//go:embed migrations/*.sql
var Migrations embed.FS
