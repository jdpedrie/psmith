#!/bin/sh
# docker-entrypoint.sh — wraps spaltd so the container auto-applies
# schema migrations on every start. `spalt install` is idempotent
# (no-op on an up-to-date DB) so running it unconditionally before
# spaltd is safe and saves the operator a manual setup step.
#
# Skipped when the command isn't spaltd — `docker run spalt spalt
# genkey` shouldn't try to talk to a DB. Skipped when SPALT_DSN
# isn't set so the failure surfaces from spaltd itself with the
# usual "SPALT_DSN is required" message rather than a less obvious
# install error.

set -e

if [ "$1" = "spaltd" ] || [ "$1" = "/usr/local/bin/spaltd" ]; then
    if [ -n "$SPALT_DSN" ]; then
        echo "entrypoint: applying schema migrations..."
        # Pass DSN explicitly — `spalt install` reads -db / DATABASE_URL,
        # not SPALT_DSN, so without this it falls through to the dev
        # default and silently targets the wrong database.
        spalt install -db "$SPALT_DSN"
    fi
fi

exec "$@"
