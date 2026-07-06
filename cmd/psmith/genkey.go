package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/jdpedrie/psmith/internal/crypto"
)

// genkeyCmd prints a fresh base64-encoded 32-byte master key suitable
// for PSMITH_MASTER_KEY. Output is JUST the key string with a trailing
// newline so it composes cleanly with shell substitution:
//
//	export PSMITH_MASTER_KEY=$(psmith genkey)
//
// No flags. The point is for this to be the smallest, least-fancy
// piece of crypto plumbing in the codebase — every operator has to
// run it exactly once during install, so any complexity (key
// rotation, KMS escrow, …) lives elsewhere.
func genkeyCmd(args []string) int {
	fs := flag.NewFlagSet("genkey", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() {
		fmt.Fprintln(fs.Output(), `Usage: psmith genkey

Mint a fresh 32-byte AES-256-GCM master key, base64-encoded. Pipe
into PSMITH_MASTER_KEY at deploy time:

    export PSMITH_MASTER_KEY=$(psmith genkey)

Run exactly once per environment and store the result in your secrets
manager — losing the key means losing the ability to decrypt any
provider/plugin config rows written under it.`)
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	key, err := crypto.GenerateKeyB64()
	if err != nil {
		fmt.Fprintf(os.Stderr, "psmith genkey: %v\n", err)
		return 1
	}
	fmt.Println(key)
	return 0
}
