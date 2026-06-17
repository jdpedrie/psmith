#!/usr/bin/env bash
# Converts every .svg in clients/SpaltSwift/Sources/SpaltUI/Resources/Logos/
# into a sibling .png at 192px so iOS — which can't decode raw SVG bytes
# from arbitrary file URLs — can render the same provider logos via
# `UIImage(named:in:with:)` against the SwiftPM resource bundle.
#
# Mac keeps using the SVGs directly (NSImage decodes SVG natively);
# iOS picks up the PNG with the same slug. ProviderLogo handles the
# per-platform branch.
#
# Idempotent: re-running only re-converts SVGs whose .png is older or
# missing. Runs as a prereq of `make ios-build`.

set -euo pipefail

LOGOS_DIR="$(cd "$(dirname "$0")/.." && pwd)/clients/SpaltSwift/Sources/SpaltUI/Resources/Logos"
SIZE=192  # covers @1x = 24px, @2x = 48px, @3x = 72px for the 24pt callsites
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

shopt -s nullglob
for svg in "$LOGOS_DIR"/*.svg; do
    base="$(basename "$svg" .svg)"
    png="$LOGOS_DIR/$base.png"

    # Skip if PNG is newer than the SVG (idempotent rebuild).
    if [ -f "$png" ] && [ "$png" -nt "$svg" ]; then
        continue
    fi

    echo "convert: $base.svg -> $base.png ($SIZE px)"

    # rsvg-convert scales the SVG content to fill the requested
    # output dimensions while preserving aspect ratio. qlmanage was
    # tried first but renders the SVG at its native viewBox in the
    # top-left of the output canvas, which leaves the actual logo
    # tiny when the SVG declares e.g. a 24x24 viewBox.
    rsvg-convert -w "$SIZE" -h "$SIZE" -a "$svg" -o "$png"
done
