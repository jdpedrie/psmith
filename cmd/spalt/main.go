// spalt is the operator-facing CLI for a running spaltd instance.
// Subcommands today: install (apply schema migrations), useradd (create
// a user account). Structured for trivial extension to passwd /
// userdel / etc as those needs arise.
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}

	switch os.Args[1] {
	case "install":
		os.Exit(installCmd(os.Args[2:]))
	case "useradd":
		os.Exit(useraddCmd(os.Args[2:]))
	case "genkey":
		os.Exit(genkeyCmd(os.Args[2:]))
	case "-h", "--help", "help":
		usage(os.Stdout)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "spalt: unknown subcommand %q\n\n", os.Args[1])
		usage(os.Stderr)
		os.Exit(2)
	}
}

func usage(w *os.File) {
	fmt.Fprint(w, `spalt — operator CLI for spaltd

Usage:
  spalt <subcommand> [flags]

Subcommands:
  install    Apply embedded schema migrations to the database.
  useradd    Create a user account.
  genkey     Mint a base64 master key for SPALT_MASTER_KEY.

Run "spalt <subcommand> -h" for subcommand-specific help.
`)
}
