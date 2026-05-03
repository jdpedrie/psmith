// reeve is the operator-facing CLI for a running reeved instance. Today
// it carries one subcommand (useradd); structured for trivial extension
// to passwd / userdel / etc as those needs arise.
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
	case "useradd":
		os.Exit(useraddCmd(os.Args[2:]))
	case "-h", "--help", "help":
		usage(os.Stdout)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "reeve: unknown subcommand %q\n\n", os.Args[1])
		usage(os.Stderr)
		os.Exit(2)
	}
}

func usage(w *os.File) {
	fmt.Fprint(w, `reeve — operator CLI for reeved

Usage:
  reeve <subcommand> [flags]

Subcommands:
  useradd    Create a user account.

Run "reeve <subcommand> -h" for subcommand-specific help.
`)
}
