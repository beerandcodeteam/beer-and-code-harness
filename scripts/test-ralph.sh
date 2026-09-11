#!/usr/bin/env bash
#
# test-ralph.sh — red/green suite for scripts/ralph.sh with a mock engine.
#
# No network calls, no tokens spent: fake `claude` and `codex` binaries are
# put on PATH and their behavior is chosen via MOCK_SCENARIO.
#
# Usage: scripts/test-ralph.sh [case-name]   (exit 0 = all green)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# RALPH_BIN lets you point at a patched copy (proves the tests go red).
RALPH="${RALPH_BIN:-$ROOT/scripts/ralph.sh}"
ONLY="${1:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
CURRENT=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()   { PASS=$((PASS + 1)); echo -e "  ${GREEN}ok${NC}   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC} $1"; }

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then ok "$msg"; else bad "$msg (expected '$expected', got '$actual')"; fi
}

assert_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF "$needle" "$haystack_file"; then ok "$msg"; else bad "$msg (did not find '$needle')"; fi
}

assert_not_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF "$needle" "$haystack_file"; then bad "$msg (found '$needle')"; else ok "$msg"; fi
}

# ---------------------------------------------------------------------------
# Mock engine — used for both claude and codex (dispatch by basename)
# ---------------------------------------------------------------------------

make_mocks() {
  local bin="$1"
  mkdir -p "$bin"

  cat > "$bin/mock-engine" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

name=$(basename "$0")
state="${MOCK_STATE:?}"
scenario="${MOCK_SCENARIO:-ok}"
prompt=""
verify=0

bump() {
  local f="$state/$1" n=0
  [ -f "$f" ] && n=$(cat "$f")
  n=$((n + 1))
  echo "$n" > "$f"
  echo "$n"
}

model=""

if [ "$name" = "claude" ]; then
  # claude -p reads stdin for real when it's not a TTY: if ralph doesn't
  # redirect < /dev/null, the mock swallows the caller's stream (e.g. the
  # phase loop's manifest).
  [ -t 0 ] || cat > /dev/null
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --allowedTools) verify=1; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --output-format) shift 2 ;;
      *) shift ;;
    esac
  done
else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sandbox) [ "$2" = "read-only" ] && verify=1; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  prompt=$(cat)
fi

grep -q '^RALPH_VERIFY' <<< "$prompt" && verify=1

# Records the requested model for the verifier session (asserted by the model test).
if [ "$verify" -eq 1 ] && [ -n "$model" ]; then
  echo "$model" > "$state/verify_model"
fi

# --- independent verifier -----------------------------------------------------
# Checks the REAL code, like the real verifier does: with no implementation
# file in the repo, the phase is incomplete.
if [ "$verify" -eq 1 ]; then
  n=$(bump verify_calls)
  tasks=$(grep -cE '^[[:space:]]*- \[[ x]\]' <<< "$prompt")

  implemented=0
  compgen -G "src/impl-*.txt" > /dev/null 2>&1 && implemented=1

  if [ "$implemented" -eq 0 ]; then
    for i in $(seq 1 "$tasks"); do echo "TASK $i: INCOMPLETE — no code found"; done
    exit 0
  fi

  if [ "$scenario" = "verify-incomplete-once" ] && [ "$n" -eq 1 ]; then
    echo "TASK 1: INCOMPLETE — the file was not created"
    for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE"; done
  else
    for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE"; done
  fi
  exit 0
fi

# --- implementation session ---------------------------------------------------
n=$(bump impl_calls)

emit_claude_ok()    { echo '{"type":"result","subtype":"success","is_error":false,"result":"implemented"}'; }
emit_claude_limit() { echo "{\"type\":\"result\",\"subtype\":\"error\",\"is_error\":true,\"result\":\"Claude AI usage limit reached|$1\"}"; }

case "$scenario" in
  limit-epoch)
    if [ "$n" -eq 1 ]; then
      emit_claude_limit "$(date +%s)"
      exit 1
    fi
    ;;
  limit-generic)
    if [ "$n" -eq 1 ]; then
      echo "Rate limit reached. Try again later."
      exit 1
    fi
    ;;
esac

# stall-after-red: writes on the 1st cycle (red test), then stalls without
# writing anything. already-done: the code already exists on HEAD, the engine writes nothing.
write=1
[ "$scenario" = "empty-diff" ] && write=0
[ "$scenario" = "already-done" ] && write=0
[ "$scenario" = "stall-after-red" ] && [ "$n" -gt 1 ] && write=0

if [ "$write" -eq 1 ]; then
  mkdir -p src
  echo "impl $n" > "src/impl-$n.txt"
fi

if [ "$scenario" = "false-429" ]; then
  # 429 in the MIDDLE of the log: it's project test output, not a usage limit.
  echo "FAIL tests/HttpClientTest: expected 429 Too Many Requests, got 200"
  for i in $(seq 1 25); do echo "noise line $i"; done
  echo "Suite fixed. Done."
  exit 0
fi

if [ "$name" = "claude" ]; then emit_claude_ok; else echo "Done."; fi
exit 0
MOCK

  chmod +x "$bin/mock-engine"
  cp "$bin/mock-engine" "$bin/claude"
  cp "$bin/mock-engine" "$bin/codex"
}

make_testcmd() {
  cat > "$1" <<'TESTCMD'
#!/usr/bin/env bash
set -uo pipefail
state="${MOCK_STATE:?}"
scenario="${MOCK_SCENARIO:-ok}"
# real sail test (docker compose exec) attaches stdin: same risk as claude -p.
[ -t 0 ] || cat > /dev/null
f="$state/test_calls"; n=0
[ -f "$f" ] && n=$(cat "$f")
n=$((n + 1)); echo "$n" > "$f"

if [ "$scenario" = "test-red-once" ] || [ "$scenario" = "stall-after-red" ]; then
  if [ "$n" -eq 1 ]; then
    echo "1 failing test: ExpectedFooTest"
    exit 1
  fi
fi
echo "all green"
exit 0
TESTCMD
  chmod +x "$1"
}

PHASES_FIXTURE='# Test Project — Project Phases

<!-- inputs: project-description.md@sha256:000000000000 -->

## Overview

Test project.

## Phase 1: Foundation

- [ ] **Task:** create file A
  - **Acceptance criteria:**
    - the file exists
- [ ] **Task:** create file B
  - **Acceptance criteria:**
    - the file exists

## Phase 2: Feature

- [ ] **Task:** create file C
  - **Acceptance criteria:**
    - the file exists

## Open Questions

- none
'

# Laravel + Sail project fixture. `sail ps` responds according to SAIL_UP.
make_sail_fixture() {
  local repo="$1" up="$2"

  touch "$repo/artisan"
  cat > "$repo/composer.json" <<'JSON'
{
  "require-dev": { "laravel/sail": "^1.0" },
  "scripts": { "test": "phpunit" }
}
JSON

  mkdir -p "$repo/vendor/bin"
  cat > "$repo/vendor/bin/sail" <<SAILMOCK
#!/usr/bin/env bash
set -uo pipefail
if [ "\${1:-}" = "ps" ]; then
  if [ "$up" = "up" ]; then
    echo "NAME                IMAGE            STATUS"
    echo "proj-laravel.test-1 sail-8.3/app     Up 2 hours"
    exit 0
  fi
  echo "Sail is not running."
  exit 1
fi
if [ "\${1:-}" = "test" ]; then
  exec "\$MOCK_TEST_CMD"
fi
exit 0
SAILMOCK
  chmod +x "$repo/vendor/bin/sail"
}

# new_case <name> -> echoes the fixture repo directory
new_case() {
  local name="$1"
  local dir="$TMP/$name"
  mkdir -p "$dir/repo" "$dir/state" "$dir/bin"
  make_mocks "$dir/bin"
  make_testcmd "$dir/test.sh"

  (
    cd "$dir/repo" || exit 1
    git init -q
    git config user.email "test@ralph"
    git config user.name "Ralph Test"
    mkdir -p .spec/init
    printf '%s' "$PHASES_FIXTURE" > .spec/init/project-phases.md
    git add -A
    git commit -q -m "chore: fixture"
  )
  echo "$dir"
}

# run_ralph <dir> <scenario> [args...] -> echoes the exit code; logs to <dir>/out.log
run_ralph() {
  local dir="$1" scenario="$2"; shift 2
  local rc=0
  (
    cd "$dir/repo" || exit 1
    PATH="$dir/bin:$PATH" \
    MOCK_STATE="$dir/state" \
    MOCK_SCENARIO="$scenario" \
    MOCK_TEST_CMD="$dir/test.sh" \
    RALPH_LIMIT_WAIT_DEFAULT=1 \
    RALPH_LIMIT_BUFFER=1 \
    RALPH_VERIFY="${CASE_VERIFY:-}" \
    RALPH_VERIFY_MODEL="${CASE_VERIFY_MODEL:-}" \
      bash "$RALPH" "$@" > "$dir/out.log" 2>&1
  ) || rc=$?
  echo "$rc"
}

commits() { git -C "$1/repo" rev-list --count HEAD; }

case_enabled() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

header() { CURRENT="$1"; echo -e "\n${YELLOW}== $1${NC}"; }

# ---------------------------------------------------------------------------
# 1. Phase ok on the first try -> 1 commit per phase, progress recorded
# ---------------------------------------------------------------------------
if case_enabled ok-first; then
  header "1. phase ok on the first try"
  d=$(new_case ok-first)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "2 phase commits (1 fixture + 2)"
  assert_contains "$d/repo/.phases/.progress" "phase-01.md" "progress records phase-01"
  assert_contains "$d/repo/.phases/.progress" "phase-02.md" "progress records phase-02"
  assert_eq "feat(phase-2): Feature" "$(git -C "$d/repo" log -1 --pretty=%s)" "commit message of the last phase"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "1 implementation session per phase (2 phases)"
  assert_eq 2 "$(cat "$d/state/verify_calls")" "gate 3 (default always) ran on every phase"
fi

# ---------------------------------------------------------------------------
# 2. Gate 2 red once -> fix cycle -> green -> only 1 commit
# ---------------------------------------------------------------------------
if case_enabled test-red-once; then
  header "2. gate 2 red once -> fix cycle"
  d=$(new_case test-red-once)
  rc=$(run_ralph "$d" test-red-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit per phase (intermediate cycle doesn't commit)"
  assert_contains "$d/out.log" "Gate 2 red" "gate 2 reported red"
  assert_contains "$d/out.log" "Fix cycle 2/2" "entered a fix cycle"
  # the fix prompt carries the REAL cause, not a generic "tests failed"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "ExpectedFooTest" "fix prompt carries the test output"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "## Phase to complete" "fix prompt is self-contained (whole phase)"
  # per-cycle logs, never overwritten
  test -f "$d/repo/.phases/logs/phase-01.cycle-1.log" && test -f "$d/repo/.phases/logs/phase-01.cycle-2.log" \
    && ok "per-cycle logs preserved" || bad "per-cycle logs preserved"
fi

# ---------------------------------------------------------------------------
# 3. Engine writes nothing and the phase is incomplete -> fails without commit
#    (gate 1 signals; the verifier is the one that fails it, against the real code)
# ---------------------------------------------------------------------------
if case_enabled empty-diff; then
  header "3. engine writes nothing + incomplete phase -> fails without commit"
  d=$(new_case empty-diff)
  rc=$(run_ralph "$d" empty-diff --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 1 "$rc" "exit 1"
  assert_eq 1 "$(commits "$d")" "no commit created (no --allow-empty)"
  assert_contains "$d/out.log" "the session wrote nothing" "gate 1 signaled the empty session"
  assert_contains "$d/out.log" "Gate 3 red" "verifier failed it against the real code"
  assert_contains "$d/out.log" "Stopping at the first phase that failed" "default policy = stop"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "without changing any file" "cycle cause cites the empty session"
fi

# ---------------------------------------------------------------------------
# 4. Verifier INCOMPLETE once -> cycle -> DONE -> commit
# ---------------------------------------------------------------------------
if case_enabled verify-incomplete; then
  header "4. verifier INCOMPLETE once -> cycle -> DONE"
  d=$(new_case verify-incomplete)
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit per phase"
  assert_contains "$d/out.log" "Gate 3 red" "gate 3 reported red"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "TASK 1: INCOMPLETE" "fix prompt carries the incomplete tasks verbatim"
  test -f "$d/repo/.phases/logs/phase-01.verify-1.log" && ok "per-cycle verifier log" || bad "per-cycle verifier log"
fi

# ---------------------------------------------------------------------------
# 5. Limit with epoch -> wait -> re-runs the SAME phase without consuming a cycle
# ---------------------------------------------------------------------------
if case_enabled limit-epoch; then
  header "5. limit with epoch -> wait -> same phase"
  d=$(new_case limit-epoch)
  # --max-cycles 1: if the wait consumed a cycle, the phase would fail
  rc=$(run_ralph "$d" limit-epoch --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (limit doesn't consume a cycle)"
  assert_eq 3 "$(commits "$d")" "phases committed after the wait"
  assert_contains "$d/out.log" "Usage limit reached" "limit detected"
  assert_contains "$d/out.log" "Reset expected at" "reset epoch extracted from the log"
fi

# ---------------------------------------------------------------------------
# 6. Generic limit with no epoch -> fallback wait
# ---------------------------------------------------------------------------
if case_enabled limit-generic; then
  header "6. generic limit with no epoch -> fallback"
  d=$(new_case limit-generic)
  rc=$(run_ralph "$d" limit-generic --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "No reset time in the output" "used the wait fallback"
  assert_eq 3 "$(commits "$d")" "phases committed after the wait"
fi

# ---------------------------------------------------------------------------
# 7. "429 Too Many Requests" in the MIDDLE of the log -> does NOT trigger a wait (regression)
# ---------------------------------------------------------------------------
if case_enabled false-429; then
  header "7. 429 in the middle of the log doesn't trigger a wait"
  d=$(new_case false-429)
  start=$(date +%s)
  rc=$(run_ralph "$d" false-429 --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  elapsed=$(($(date +%s) - start))
  assert_eq 0 "$rc" "exit 0"
  assert_not_contains "$d/out.log" "Usage limit reached" "did not interpret a test 429 as a usage limit"
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" "429 Too Many Requests" "the 429 really was in the log"
  [ "$elapsed" -lt 5 ] && ok "no wait (${elapsed}s)" || bad "no wait (${elapsed}s)"
fi

# ---------------------------------------------------------------------------
# 8. Second run with the same input -> completed phases skipped (resume works)
# ---------------------------------------------------------------------------
if case_enabled resume; then
  header "8. resume: second run skips completed phases"
  d=$(new_case resume)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "first run green"
  before=$(commits "$d")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "second run green"
  assert_eq "$before" "$(commits "$d")" "no new commit"
  assert_contains "$d/out.log" "Previous progress preserved" "progress preserved (input unchanged)"
  assert_contains "$d/out.log" "(already completed)" "phases skipped"
fi

# ---------------------------------------------------------------------------
# 9. Input changed between runs -> progress invalidated with a warning
# ---------------------------------------------------------------------------
if case_enabled resume-invalidated; then
  header "9. changed input -> progress invalidated"
  d=$(new_case resume-invalidated)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "first run green"
  before=$(commits "$d")
  (
    cd "$d/repo" || exit 1
    printf '\n## Phase 3: Extra\n\n- [ ] **Task:** create file D\n  - **Acceptance criteria:**\n    - the file exists\n' >> .spec/init/project-phases.md
    git add -A && git commit -q -m "chore: new phase"
  )
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "second run green"
  assert_contains "$d/out.log" "progress reset" "progress invalidated with a warning"
  assert_eq $((before + 4)) "$(commits "$d")" "3 phases re-run + the mutation commit"
fi

# ---------------------------------------------------------------------------
# 10. Dirty tree at preflight -> abort before any session
# ---------------------------------------------------------------------------
if case_enabled dirty-tree; then
  header "10. dirty tree -> abort at preflight"
  d=$(new_case dirty-tree)
  echo "uncommitted work" > "$d/repo/rascunho.txt"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Working tree is dirty" "aborted with instructions"
  test -f "$d/state/impl_calls" && bad "no engine session started" || ok "no engine session started"
fi

# ---------------------------------------------------------------------------
# 11. Input format contract -> abort before spending a token
# ---------------------------------------------------------------------------
if case_enabled bad-format; then
  header "11. malformed phase heading -> abort at preflight"
  d=$(new_case bad-format)
  (
    cd "$d/repo" || exit 1
    sed -i 's/^## Phase 2: Feature$/## Phase Two — Feature/' .spec/init/project-phases.md
    git add -A && git commit -q -m "chore: malformed heading"
  )
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  # "## Phase Two" doesn't match '^## Phase [0-9]+: ' -> malformed heading
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Format contract violated" "aborted for invalid format"
  test -f "$d/state/impl_calls" && bad "no engine session started" || ok "no engine session started"
fi

# ---------------------------------------------------------------------------
# 12. Fix cycle that writes nothing, but the previous cycle's code is complete
#     and green -> the phase passes (the verifier decides, not the diff)
# ---------------------------------------------------------------------------
if case_enabled stall-after-red; then
  header "12. cycle with no writes + complete code -> gate 3 decides, phase passes"
  d=$(new_case stall-after-red)
  rc=$(run_ralph "$d" stall-after-red --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  # the mock only writes on the 1st session: phase 1 commits after cycle 2; phase 2 hits
  # the "already implemented" path (the verifier sees the code and approves)
  assert_eq 2 "$(commits "$d")" "1 commit (phase 1); phase 2 had nothing to commit"
  assert_contains "$d/out.log" "Gate 2 red" "the cycle started with a gate 2 red"
  assert_contains "$d/out.log" "the session wrote nothing" "gate 1 signaled the empty session of cycle 2"
  assert_contains "$d/out.log" "feat(phase-1)" "phase 1 committed after the fix cycle"
fi

# ---------------------------------------------------------------------------
# 17. Phase ALREADY implemented on HEAD (previous run committed) -> recognized
#     without commit, without failing. Regression of a real bug: the engine writes
#     nothing because there is nothing to write, and gate 1 used to fail it.
# ---------------------------------------------------------------------------
if case_enabled already-done; then
  header "17. phase already implemented on HEAD -> recognized without commit"
  d=$(new_case already-done)
  # simulates the previous run: code implemented and committed by hand, empty progress
  mkdir -p "$d/repo/src"
  echo "previous impl" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: work from the previous run"
  before=$(commits "$d")

  rc=$(run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (doesn't fail an already implemented phase)"
  assert_contains "$d/out.log" "ALREADY IMPLEMENTED" "recognized the phase as done"
  assert_eq "$before" "$(commits "$d")" "no commit created (nothing to commit)"
  assert_contains "$d/repo/.phases/.progress" "phase-01.md" "progress records the phase"
  assert_contains "$d/repo/.phases/.progress" "phase-02.md" "progress records the next phase"
fi

# ---------------------------------------------------------------------------
# 18. Phase failed -> warns that partial work is left in the tree
# ---------------------------------------------------------------------------
if case_enabled dirty-after-fail; then
  header "18. phase failed with work in the tree -> instructs the dev"
  d=$(new_case dirty-after-fail)
  # verify-incomplete-once with 1 cycle: writes, tests green, verifier fails it
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1"
  assert_eq 1 "$(commits "$d")" "no commit"
  assert_contains "$d/out.log" "partial work is left in the tree" "warned about the dirty tree"
  assert_contains "$d/out.log" "git clean -fd" "gave the discard instructions"
fi

# ---------------------------------------------------------------------------
# 19. --no-verify turns off gate 3 even on the suspicious path (session with no
#     writes). Explicit dev choice: ralph trusts gate 2 alone.
# ---------------------------------------------------------------------------
if case_enabled no-verify; then
  header "19. --no-verify turns off gate 3 even on the suspicious path"
  d=$(new_case no-verify)
  rc=$(run_ralph "$d" empty-diff --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-verify)
  assert_eq 0 "$rc" "exit 0 (gate 2 green decides alone)"
  assert_contains "$d/out.log" "Gate 3 skipped (--no-verify)" "explicit skip logged"
  assert_contains "$d/out.log" "Gate 2 green against the code on HEAD" "message doesn't mention gate 3 (didn't run)"
  test -f "$d/state/verify_calls" && bad "no verifier session spent" || ok "no verifier session spent"
fi

# ---------------------------------------------------------------------------
# 20. RALPH_VERIFY=auto (opt-in): happy path (session wrote + suite green)
#     skips gate 3; the phase still commits.
# ---------------------------------------------------------------------------
if case_enabled verify-auto; then
  header "20. RALPH_VERIFY=auto skips gate 3 on the happy path"
  d=$(new_case verify-auto)
  rc=$(CASE_VERIFY=auto run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "phases committed"
  assert_contains "$d/out.log" "Gate 3 skipped: the session wrote code" "skip logged with the cause"
  test -f "$d/state/verify_calls" && bad "no verifier session spent" || ok "no verifier session spent"
fi

# ---------------------------------------------------------------------------
# 21. Verifier runs with a cheap model: haiku by default on claude,
#     RALPH_VERIFY_MODEL overrides it.
# ---------------------------------------------------------------------------
if case_enabled verify-model; then
  header "21. verifier uses a cheap model (haiku default, env overrides)"
  d=$(new_case verify-model)
  # phase already implemented on HEAD: session doesn't write -> gate 3 runs in auto
  mkdir -p "$d/repo/src"
  echo "previous impl" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: previous work"
  rc=$(run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_eq "haiku" "$(cat "$d/state/verify_model" 2>/dev/null)" "verify called with --model haiku"
  assert_contains "$d/out.log" "model: haiku" "gate 3 log reports the model"

  d2=$(new_case verify-model-override)
  mkdir -p "$d2/repo/src"
  echo "previous impl" > "$d2/repo/src/impl-1.txt"
  git -C "$d2/repo" add -A && git -C "$d2/repo" commit -q -m "feat: previous work"
  rc=$(CASE_VERIFY_MODEL=sonnet run_ralph "$d2" already-done --engine claude --test-cmd "$d2/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (override)"
  assert_eq "sonnet" "$(cat "$d2/state/verify_model" 2>/dev/null)" "RALPH_VERIFY_MODEL overrides the default"
fi

# ---------------------------------------------------------------------------
# 13. Laravel Sail with containers up -> gate 2 uses `vendor/bin/sail test`
#     (and NOT `composer test`, which would run on the host with no PHP or DB)
# ---------------------------------------------------------------------------
if case_enabled sail-up; then
  header "13. Laravel Sail up -> gate 2 runs sail test"
  d=$(new_case sail-up)
  make_sail_fixture "$d/repo" up
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude)   # no --test-cmd: exercises detection
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "test command (detected): vendor/bin/sail test" "detected sail test"
  assert_not_contains "$d/out.log" "composer test" "composer test was not chosen"
  assert_contains "$d/out.log" "Sail: containers up" "checked containers at preflight"
  # base = 2 commits (fixture + chore: sail) + 2 phases
  assert_eq 4 "$(commits "$d")" "phases committed (gate 2 really ran)"
  assert_eq 2 "$(cat "$d/state/test_calls")" "the suite ran once per phase, via sail"
  # the agent needs to know which runner to use, otherwise it runs php artisan test on the host
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "vendor/bin/sail test" "prompt informs the test command"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Never run these tools on the host" "prompt warns about the container"
fi

# ---------------------------------------------------------------------------
# 14. Sail with stopped containers -> abort at preflight, zero tokens
# ---------------------------------------------------------------------------
if case_enabled sail-down; then
  header "14. Laravel Sail down -> abort at preflight"
  d=$(new_case sail-down)
  make_sail_fixture "$d/repo" down
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "containers are not up" "aborted with the cause"
  assert_contains "$d/out.log" "vendor/bin/sail up -d" "instructed how to bring up the environment"
  assert_eq 2 "$(commits "$d")" "no phase commit"
  test -f "$d/state/impl_calls" && bad "no engine session started" || ok "no engine session started"
fi

# ---------------------------------------------------------------------------
# 15. --test-cmd overrides Sail detection
# ---------------------------------------------------------------------------
if case_enabled sail-override; then
  header "15. --test-cmd overrides Sail detection"
  d=$(new_case sail-override)
  make_sail_fixture "$d/repo" down   # containers stopped, but the cmd doesn't use sail
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (doesn't check containers for a cmd without sail)"
  assert_contains "$d/out.log" "test command (--test-cmd)" "override respected"
  assert_eq 4 "$(commits "$d")" "phases committed"
fi

# ---------------------------------------------------------------------------
# 16. Laravel without Sail -> composer test (regression: shouldn't become sail test)
# ---------------------------------------------------------------------------
if case_enabled laravel-no-sail; then
  header "16. Laravel without Sail -> composer test"
  d=$(new_case laravel-no-sail)
  touch "$d/repo/artisan"
  printf '{ "scripts": { "test": "phpunit" } }\n' > "$d/repo/composer.json"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: laravel"
  # doesn't run to completion: we only need preflight to resolve the command
  run_ralph "$d" empty-diff --engine claude --max-cycles 1 > /dev/null
  assert_contains "$d/out.log" "test command (detected): composer test" "no sail -> composer test"
  assert_not_contains "$d/out.log" "Sail" "did not mention Sail"
fi

# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}ALL GREEN: $PASS asserts${NC}"
else
  echo -e "${RED}FAILURES: $FAIL${NC} / green: $PASS"
fi
exit $((FAIL > 0 ? 1 : 0))
