// Package internal is the escape hatch for code that genuinely must not be
// importable from outside this module.
//
// It is deliberately empty. `internal/` used to hold the whole server, which
// made it the default home for everything rather than a considered choice —
// and the compiler barrier bought little, since Psmith is an application
// nobody imports as a library. That code now lives in `server/`, paired with
// `clients/`.
//
// Put something here only when an out-of-tree consumer depending on it would
// actually be a problem. With plugins moving out-of-process, the strongest
// boundary is the process boundary, not this one.
package internal
