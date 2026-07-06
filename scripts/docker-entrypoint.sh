#!/bin/sh
# docker-entrypoint.sh — wraps psmithd so the container auto-applies
# schema migrations on every start. `psmith install` is idempotent
# (no-op on an up-to-date DB) so running it unconditionally before
# psmithd is safe and saves the operator a manual setup step.
#
# Skipped when the command isn't psmithd — `docker run psmith psmith
# genkey` shouldn't try to talk to a DB. Skipped when PSMITH_DSN
# isn't set so the failure surfaces from psmithd itself with the
# usual "PSMITH_DSN is required" message rather than a less obvious
# install error.

set -e

if [ "$1" = "psmithd" ] || [ "$1" = "/usr/local/bin/psmithd" ]; then
    if [ -n "$PSMITH_DSN" ]; then
        echo "entrypoint: applying schema migrations..."
        # Pass DSN explicitly — `psmith install` reads -db / DATABASE_URL,
        # not PSMITH_DSN, so without this it falls through to the dev
        # default and silently targets the wrong database.
        psmith install -db "$PSMITH_DSN"
    fi
fi

exec "$@"
