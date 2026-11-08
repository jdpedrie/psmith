#!/bin/bash
# Board conformance for the web client. See docs/clients/web-redesign/plan.md.
#
#   BOARDS=<canvas project dir> WORK=<scratch dir> ./check.sh build
#   ./check.sh probe                         # render the templates with board fixtures
#   ./check.sh board <Board> [mode] [theme]  # PNG of a board
#   ./check.sh cmp <Board> [mode] [theme] [probe name] [w] [h]
#
# Boards are the .dc.html files of the "Psmith web design" canvas; pull them
# with the Artifact tool. Everything writes under $WORK.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${WORK:?set WORK}; BOARDS=${BOARDS:-$WORK/project}
mkdir -p "$WORK/png" "$WORK/probe" "$WORK/cmp" "$WORK/bin"
bin() { [ -x "$WORK/bin/$1" ] || swiftc -O -o "$WORK/bin/$1" "$HERE/$1.swift" 2>/dev/null; echo "$WORK/bin/$1"; }
size() { if grep -q '"width":390' "$BOARDS/$1.dc.html"; then echo "390 844"; else echo "1440 900"; fi; }
case "$1" in
build) bin render >/dev/null; bin score >/dev/null; bin compare >/dev/null ;;
probe) (cd "$ROOT" && PSMITH_WEB_PROBE_OUT="$WORK/probe" go test ./server/web -run TestProbe -count=1 >/dev/null) ;;
board)
  B=$2; M=${3:-dark}; T=${4:-slate}; read W H < <(size $B)
  python3 "$HERE/prep.py" "$BOARDS" "$B" "$M" "$T" "$WORK/png/$B-$M-$T.html"
  "$(bin render)" "$WORK/png/$B-$M-$T.html" "$WORK/png/$B-$M-$T.png" ${5:-$W} ${6:-$H}
  echo "$WORK/png/$B-$M-$T.png" ;;
cmp)
  B=$2; M=${3:-dark}; T=${4:-slate}; P=${5:-$2}; read W H < <(size $B); W=${6:-$W}; H=${7:-$H}
  python3 "$HERE/prep.py" "$BOARDS" "$B" "$M" "$T" "$WORK/png/$B-$M-$T.html"
  "$(bin render)" "$WORK/png/$B-$M-$T.html" "$WORK/cmp/$B-$M-$T-board.png" $W $H
  "$(bin render)" "$WORK/probe/$P-$M-$T.html" "$WORK/cmp/$B-$M-$T-real.png" $W $H
  "$(bin compare)" "$WORK/cmp/$B-$M-$T-board.png" "$WORK/cmp/$B-$M-$T-real.png" "$WORK/cmp/$B-$M-$T"
  echo "$B $M $T $("$(bin score)" "$WORK/cmp/$B-$M-$T-board.png" "$WORK/cmp/$B-$M-$T-real.png")" ;;
esac
