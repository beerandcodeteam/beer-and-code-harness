#!/usr/bin/env bash
#
# check-shell.sh — sanity checks for the harness's shell scripts.
#
#   1. bash -n over every scripts/*.sh (always runs; only needs bash)
#   2. shellcheck when available (dev-only; absence doesn't fail the check)
#
# Usage: scripts/check-shell.sh   (from anywhere; exit 0 = clean)

set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0
FILES=(scripts/*.sh)

echo "== bash -n (${#FILES[@]} files)"
for f in "${FILES[@]}"; do
  if bash -n "$f" 2>/dev/null; then
    echo "  ok    $f"
  else
    echo "  ERROR $f"
    bash -n "$f" 2>&1 | sed 's/^/        /'
    FAIL=1
  fi
done

echo
if command -v shellcheck > /dev/null 2>&1; then
  echo "== shellcheck"
  for f in "${FILES[@]}"; do
    if shellcheck -x "$f"; then
      echo "  ok    $f"
    else
      FAIL=1
    fi
  done
else
  echo "== shellcheck MISSING — skipped (install: apt install shellcheck)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: shell is clean."
else
  echo "FAILURE: fix the issues above."
fi
exit "$FAIL"
