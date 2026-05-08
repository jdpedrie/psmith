#!/bin/sh
# docker-entrypoint.sh — wraps reeved so the container auto-applies
# schema migrations on every start. `reeve install` is idempotent
# (no-op on an up-to-date DB) so running it unconditionally before
# reeved is safe and saves the operator a manual setup step.
#
# Skipped when the command isn't reeved — `docker run reeve reeve
# genkey` shouldn't try to talk to a DB. Skipped when REEVE_DSN
# isn't set so the failure surfaces from reeved itself with the
# usual "REEVE_DSN is required" message rather than a less obvious
# install error.

set -e

if [ "$1" = "reeved" ] || [ "$1" = "/usr/local/bin/reeved" ]; then
    if [ -n "$REEVE_DSN" ]; then
        echo "entrypoint: applying schema migrations..."
        # Pass DSN explicitly — `reeve install` reads -db / DATABASE_URL,
        # not REEVE_DSN, so without this it falls through to the dev
        # default and silently targets the wrong database.
        reeve install -db "$REEVE_DSN"
    fi
fi

exec "$@"
