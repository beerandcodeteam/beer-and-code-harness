#!/usr/bin/env bash
#
# check-init-drift.sh — guard against textual drift of the shared rules
# duplicated across the init command suite.
#
# The four commands/init/*.md files intentionally inline the same interview,
# language, re-run, staleness, and close-out rules instead of referencing a
# shared file: plugin commands must be self-contained at runtime (they execute
# inside the developer's project, where the plugin root is not reachable via
# @-includes). The cost of that duplication is silent drift — this script makes
# drift loud. Each anchor below is a sentence (or fragment) that must appear
# verbatim in every file of its group; rewording one copy breaks the anchor
# and fails the check.
#
# Usage: scripts/check-init-drift.sh   (from anywhere; exits 0 = no drift)

set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0

# check "<anchor>" <file>... — anchor must appear verbatim in every listed file
check() {
  local s=$1; shift
  local missing=()
  for f in "$@"; do
    grep -qF -- "$s" "$f" || missing+=("$f")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "DRIFT: missing in ${missing[*]}:"
    echo "  $s"
    FAIL=1
  fi
}

DESC=commands/init/project-description.md
STORIES=commands/init/user-stories.md
SCHEMA=commands/init/database-schema.md
PHASES=commands/init/project-phases.md
ROUTER=commands/init.md

ALL4=("$DESC" "$STORIES" "$SCHEMA" "$PHASES")
DOWN3=("$STORIES" "$SCHEMA" "$PHASES")

# --- Interview rules (all 4) ---
check 'Use `AskUserQuestion` for discrete decisions with clear options' "${ALL4[@]}"
check "Ask real open questions in plain text when the answer is not a menu. Batch related questions; don't drip one at a time." "${ALL4[@]}"
check 'as an open question rather than inventing' "${ALL4[@]}"

# --- Re-run contract (all 4) ---
check 'Re-running this command must **update** the existing document, never rebuild it from scratch — `.spec` belongs to the developer, and manual edits there are decisions, not noise.' "${ALL4[@]}"
check '**before** interviewing. Every decision recorded in it' "${ALL4[@]}"
check 'Interview only about **deltas**' "${ALL4[@]}"
check 'Never re-ask what the document already answers.' "${ALL4[@]}"
check 'Update via **Edit**, not a full rewrite' "${ALL4[@]}"
check 'stays deleted — restore it only if the developer explicitly confirms.' "${ALL4[@]}"

# --- Write step + self-check preamble (all 4) ---
check '(create the `.spec/init/` directories if missing)' "${ALL4[@]}"
check 'After writing, run these checks. Any failure → fix the document via Edit and re-run until all pass. Never report completion with a failing check.' "${ALL4[@]}"

# --- Close-out skeleton (all 4) ---
check '- The path written.' "${ALL4[@]}"
check '- Self-checks: all green — list any check that initially failed and how it was fixed (Red → Green).' "${ALL4[@]}"
check "- Any open questions still needing the developer's decision." "${ALL4[@]}"

# --- Language rules (head vs downstream, intentionally different) ---
check "Match the developer's language." "$DESC"
check 'Match the **language** of the project description' "${DOWN3[@]}"

# --- Staleness stamp mechanism (3 downstream commands) ---
check 'Line 3 of the existing file is its **input stamp**' "${DOWN3[@]}"
check 'never block. A file without a line-3 stamp predates this mechanism — nothing to verify.' "${DOWN3[@]}"
check 'input changed after this artifact was generated — review before proceeding' "${DOWN3[@]}"
check 'Refresh it on **every** run, including re-run Edits' "${DOWN3[@]}"

# --- design/ contract (consumer + router; always manual, never generated) ---
check '`.spec/init/design/` is always a **manual artifact**: the developer creates and populates it; no `init:*` command writes there. Its absence is never an error.' "$PHASES" "$ROUTER"

# --- Stamp parser loop (3 downstream commands + /init router share it) ---
check '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}' "${DOWN3[@]}" "$ROUTER"
check 'cut -c1-12)" = "${pair##*:}" ]' "${DOWN3[@]}" "$ROUTER"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: shared init wording is in sync across the suite."
fi
exit "$FAIL"
