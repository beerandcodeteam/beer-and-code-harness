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
outfmt=""

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
      --output-format) outfmt="$2"; shift 2 ;;
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

# Reproduces claude's real stream-json for the agent's task list:
# TaskCreate (no id) -> tool_result carrying the id -> TaskUpdate per transition.
# This is what ralph derives per-task progress from, in real time.
emit_stream_tasks() {
  local total="$1" complete_up_to="$2" i
  echo '{"type":"system","subtype":"init","session_id":"mock"}'
  for i in $(seq 1 "$total"); do
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskCreate\",\"input\":{\"subject\":\"task $i\"}}]}}"
    echo "{\"type\":\"user\",\"tool_use_result\":{\"task\":{\"id\":\"$i\",\"subject\":\"task $i\"}}}"
  done
  for i in $(seq 1 "$total"); do
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskUpdate\",\"input\":{\"taskId\":\"$i\",\"status\":\"in_progress\"}}]}}"
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"run\",\"description\":\"running the tests for task $i\"}}]}}"
    if [ "$i" -le "$complete_up_to" ]; then
      echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskUpdate\",\"input\":{\"taskId\":\"$i\",\"status\":\"completed\"}}]}}"
    fi
  done
}

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

if [ "$name" = "claude" ]; then
  if [ "$outfmt" = "stream-json" ]; then
    n_tasks=$(grep -cE '^[[:space:]]*- \[[ x]\]' <<< "$prompt")
    if [ "$scenario" = "tool-error" ]; then
      # A tool failed mid-session (a grep with no match, a red test, a missing
      # file): the tool_result carries is_error=true. That is normal agent work
      # — the engine finished fine.
      emit_stream_tasks "$n_tasks" "$n_tasks"
      echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"grep: sail: No such file","is_error":true,"tool_use_id":"toolu_x"}]}}'
    elif [ "$scenario" = "stream-slow" ]; then
      # From the outside the session is a slow black box: it emits task 1 done
      # and task 2 running, HOLDS, and only then finishes. That is the window in
      # which the test observes the panel halfway through.
      emit_stream_tasks 1 1
      echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskCreate\",\"input\":{\"subject\":\"task 2\"}}]}}"
      echo "{\"type\":\"user\",\"tool_use_result\":{\"task\":{\"id\":\"2\",\"subject\":\"task 2\"}}}"
      echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskUpdate\",\"input\":{\"taskId\":\"2\",\"status\":\"in_progress\"}}]}}"
      touch "$state/slow_midpoint"
      sleep "${MOCK_SLOW_SECS:-4}"
      echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskUpdate\",\"input\":{\"taskId\":\"2\",\"status\":\"completed\"}}]}}"
    else
      emit_stream_tasks "$n_tasks" "$n_tasks"
    fi
  fi
  emit_claude_ok
else
  echo "Done."
fi
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
    # -u RALPH_TEST_CMD / RALPH_MAX_CYCLES: the dev may have these exported in
    # their shell (e.g. RALPH_TEST_CMD in .zshrc). Inheriting them here beats
    # manifest detection and breaks cases 13/16 with a failure ralph does not have.
    env -u RALPH_TEST_CMD -u RALPH_MAX_CYCLES -u RALPH_MAX_LIMIT_WAITS \
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

# Same as run_ralph, but PRESERVES the caller's RALPH_TEST_CMD — to deliberately
# exercise the case where the environment variable beats detection.
run_ralph_env() {
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
# 21. Verifier runs with a cheap model: sonnet by default on claude,
#     RALPH_VERIFY_MODEL overrides it.
# ---------------------------------------------------------------------------
if case_enabled verify-model; then
  header "21. verifier uses a cheap model (sonnet default, env overrides)"
  d=$(new_case verify-model)
  # phase already implemented on HEAD: session doesn't write -> gate 3 runs in auto
  mkdir -p "$d/repo/src"
  echo "previous impl" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: previous work"
  rc=$(run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_eq "sonnet" "$(cat "$d/state/verify_model" 2>/dev/null)" "verify called with --model sonnet"
  assert_contains "$d/out.log" "model: sonnet" "gate 3 log reports the model"

  d2=$(new_case verify-model-override)
  mkdir -p "$d2/repo/src"
  echo "previous impl" > "$d2/repo/src/impl-1.txt"
  git -C "$d2/repo" add -A && git -C "$d2/repo" commit -q -m "feat: previous work"
  rc=$(CASE_VERIFY_MODEL=haiku run_ralph "$d2" already-done --engine claude --test-cmd "$d2/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (override)"
  assert_eq "haiku" "$(cat "$d2/state/verify_model" 2>/dev/null)" "RALPH_VERIFY_MODEL overrides the default"
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
# 22. Observable state published: phases AND tasks, with the real titles
# ---------------------------------------------------------------------------
if case_enabled state-published; then
  header "22. state published to .phases/state/run.tsv"
  d=$(new_case state-published)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  s="$d/repo/.phases/state/run.tsv"
  test -f "$s" && ok "run.tsv created" || bad "run.tsv created"
  assert_contains "$s" "$(printf 'META\tstatus\tfinished')" "final run status"
  assert_contains "$s" "$(printf 'META\tengine\tclaude')" "engine in the state"
  assert_contains "$s" "$(printf 'PHASE\t1\tdone')" "phase 1 done"
  assert_contains "$s" "$(printf 'PHASE\t2\tdone')" "phase 2 done"
  # the task title comes from the `- [ ]` item, without the markdown noise
  assert_contains "$s" "$(printf 'TASK\t1\t1\tdone\tcreate file A')" "phase 1 task 1 with a clean title"
  assert_contains "$s" "$(printf 'TASK\t1\t2\tdone\tcreate file B')" "phase 1 task 2"
  assert_contains "$s" "$(printf 'TASK\t2\t1\tdone\tcreate file C')" "phase 2 task"
  assert_not_contains "$s" '**Task:**' "markdown stripped from the title"
fi

# ---------------------------------------------------------------------------
# 23. The stream watcher translates the agent's task list (unit test).
#     This is the mechanism that gives per-task progress: without it the panel
#     only knows "phase running".
# ---------------------------------------------------------------------------
if case_enabled stream-watch; then
  header "23. watcher translates TaskCreate/TaskUpdate into per-task state"
  d="$TMP/stream-watch"
  mkdir -p "$d"

  # Stream with 3 tasks: the 1st done, the 2nd running, the 3rd untouched.
  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"alfa"}}]}}
{"type":"user","tool_use_result":{"task":{"id":"1","subject":"alfa"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"beta"}}]}}
{"type":"user","tool_use_result":{"task":{"id":"2","subject":"beta"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"gama"}}]}}
{"type":"user","tool_use_result":{"task":{"id":"3","subject":"gama"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test","description":"running the suite"}}]}}
{"type":"result","subtype":"success","is_error":false}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    stream_watch "$d/live.tsv" 7 1 < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'PHASE\t7')" "live.tsv points at the current phase"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 done"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\trunning')" "task 2 running"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t3\tpending')" "task 3 still pending"
  assert_contains "$d/live.tsv" "running the suite" "current activity comes from the tool_use"
fi

# ---------------------------------------------------------------------------
# 24. Gate 3's verdict overrides what the session thought it did: a task the
#     verifier failed stays INCOMPLETE in the state, not "done".
# ---------------------------------------------------------------------------
if case_enabled state-verify-truth; then
  header "24. gate 3 corrects the per-task status in the state"
  d=$(new_case state-verify-truth)
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 (phase failed by gate 3)"
  s="$d/repo/.phases/state/run.tsv"
  assert_contains "$s" "$(printf 'TASK\t1\t1\tincomplete')" "task failed by the verifier"
  assert_contains "$s" "$(printf 'TASK\t1\t2\tdone')" "task passed by the verifier"
  assert_contains "$s" "$(printf 'PHASE\t1\tfailed')" "phase marked as failed"
  assert_contains "$s" "$(printf 'META\tstatus\tfailed')" "run marked as failed"
fi

# ---------------------------------------------------------------------------
# 25. ralph-watch.sh --once renders the state of a real run
# ---------------------------------------------------------------------------
if case_enabled watch-render; then
  header "25. ralph-watch.sh --once renders the panel"
  d=$(new_case watch-render)
  run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" > /dev/null
  RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/panel.txt" 2>&1
  assert_eq 0 "$?" "rendered without error"
  assert_contains "$d/panel.txt" "RALPH" "header"
  assert_contains "$d/panel.txt" "Foundation" "phase 1 title"
  assert_contains "$d/panel.txt" "create file A" "task title"
  assert_contains "$d/panel.txt" "Done" "per-row status"
  assert_contains "$d/panel.txt" "G0" "gates column"

  # no state at all -> a clear error, not a stack trace
  mkdir -p "$TMP/empty-repo"
  "$ROOT/scripts/ralph-watch.sh" --once --no-color "$TMP/empty-repo" > "$d/empty.txt" 2>&1
  rc=$?
  assert_eq 1 "$rc" "exits 1 with no state"
  assert_contains "$d/empty.txt" "No state" "missing-state message"
fi

# ---------------------------------------------------------------------------
# 26. --dashboard without ralph-watch.sh next to it -> degrades with a warning,
#     does not die (ralph.sh stays copyable on its own into another repo)
# ---------------------------------------------------------------------------
if case_enabled dashboard-degrade; then
  header "26. --dashboard without ralph-watch.sh -> warns and continues"
  d=$(new_case dashboard-degrade)
  cp "$RALPH" "$d/ralph-solo.sh"
  rc=$(RALPH="$d/ralph-solo.sh" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --dashboard)
  assert_eq 0 "$rc" "exit 0 (full run even without the panel)"
  assert_contains "$d/out.log" "does not exist" "warned that the panel is unavailable"
  assert_contains "$d/out.log" "State is still published" "pointed at the alternative"
  assert_eq 3 "$(commits "$d")" "phases committed normally"
fi

# ---------------------------------------------------------------------------
# 27. The central requirement: DURING the phase, with the session still open,
#     task 1 shows as done, task 2 as running and the PHASE as running. Without
#     this, progress would only appear all at once, at the end of the phase.
# ---------------------------------------------------------------------------
if case_enabled live-progress; then
  header "27. per-task progress visible while the phase is still running"
  d=$(new_case live-progress)

  (
    cd "$d/repo" || exit 1
    env -u RALPH_TEST_CMD -u RALPH_MAX_CYCLES \
    PATH="$d/bin:$PATH" MOCK_STATE="$d/state" MOCK_SCENARIO=stream-slow \
    MOCK_TEST_CMD="$d/test.sh" MOCK_SLOW_SECS=6 RALPH_VERIFY=off \
      bash "$RALPH" --engine claude --test-cmd "$d/test.sh" > "$d/out.log" 2>&1
  ) &
  ralph_pid=$!

  # Wait for the mock to announce it is mid-phase, then snapshot the state.
  snap=""
  for _ in $(seq 1 100); do
    if [ -f "$d/state/slow_midpoint" ]; then
      sleep 0.5
      snap=$(cat "$d/repo/.phases/state/live.tsv" 2>/dev/null)
      break
    fi
    sleep 0.2
  done

  phase_snap=$(grep -E '^PHASE[[:space:]]+1[[:space:]]' "$d/repo/.phases/state/run.tsv" 2>/dev/null || true)
  panel=$(RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" 2>&1 || true)

  wait "$ralph_pid" 2>/dev/null
  ralph_rc=$?

  printf '%s\n' "$snap" > "$d/snap.tsv"
  printf '%s\n' "$panel" > "$d/panel-live.txt"

  assert_contains "$d/snap.tsv" "$(printf 'LIVE\t1\tdone')" "mid-phase: task 1 already done"
  assert_contains "$d/snap.tsv" "$(printf 'LIVE\t2\trunning')" "mid-phase: task 2 running"
  case "$phase_snap" in
    *running*) ok "mid-phase: the phase is still running" ;;
    *)         bad "mid-phase: the phase is still running (got '$phase_snap')" ;;
  esac
  # the panel rendered at the same instant shows all three states together
  assert_contains "$d/panel-live.txt" "Running" "panel shows something running"
  assert_contains "$d/panel-live.txt" "Done" "panel shows the already-done task"
  assert_eq 0 "$ralph_rc" "the run finished green after that"
fi

# ---------------------------------------------------------------------------
# 28. REGRESSION: a tool that fails INSIDE the session must not fail gate 0.
#     With stream-json the log carries the whole conversation, and a tool_result
#     from a command that returned != 0 brings "is_error":true — scanning the
#     whole log failed the phase because of a grep with no match.
# ---------------------------------------------------------------------------
if case_enabled gate0-tool-error; then
  header "28. a tool_result with is_error does not fail gate 0"
  d=$(new_case gate0-tool-error)
  rc=$(run_ralph "$d" tool-error --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (the engine finished fine)"
  assert_not_contains "$d/out.log" "Gate 0 red" "gate 0 did not fail"
  assert_eq 3 "$(commits "$d")" "phases committed"
  # the log really did contain the tool's is_error
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" '"is_error":true' "the failing tool_result was in the log"
fi

# ---------------------------------------------------------------------------
# 29. Non-existent test command -> abort at preflight, zero tokens.
#     Real case: RALPH_TEST_CMD with sail exported in the dev's shell beats
#     detection in ANY project; without this check every gate 2 failed and burnt
#     all 3 cycles of every phase.
# ---------------------------------------------------------------------------
if case_enabled test-cmd-missing; then
  header "29. non-existent test command -> abort at preflight"
  d=$(new_case test-cmd-missing)
  rc=$(RALPH_TEST_CMD="vendor/bin/sail composer test:parallel" \
       run_ralph_env "$d" ok --engine claude)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "not executable" "aborted with the cause"
  assert_contains "$d/out.log" "RALPH_TEST_CMD" "identified where the command came from"
  assert_contains "$d/out.log" "env -u RALPH_TEST_CMD" "offered the way out"
  assert_eq 1 "$(commits "$d")" "no phase commit"
  test -f "$d/state/impl_calls" && bad "no engine session started" || ok "no engine session started"
fi

# ---------------------------------------------------------------------------
# 30. A model that does NOT use the task list: the panel still shows progress,
#     inferred from the files the agent writes. Without the fallback, a whole
#     phase sat with every task "pending".
# ---------------------------------------------------------------------------
if case_enabled task-fallback; then
  header "30. inferred progress when the agent does not use the task list"
  d="$TMP/task-fallback"
  mkdir -p "$d/.phases"

  cat > "$d/.phases/phase-07.md" <<'PH'
## Phase 7: Example

- [ ] **Task:** create `src/Money.php` with the Money class
- [ ] **Task:** create `tests/MoneyTest.php` covering Money
- [ ] **Task:** update the README
PH

  # Stream with NO TaskCreate/TaskUpdate at all — only file writes.
  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/src/Money.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/tests/MoneyTest.php","content":"..."}}]}}
{"type":"result","subtype":"success","is_error":false}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live.tsv" 7 1 phase-07.md < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 counted as done on moving to the next"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\trunning')" "task 2 running (file being written)"
  assert_not_contains "$d/live.tsv" "$(printf 'LIVE\t3\t')" "untouched task 3 stays out of the state"

  # And when the agent DOES use the list, it wins: the inference is discarded.
  cat > "$d/stream2.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/src/Money.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"create Money"}}]}}
{"type":"user","tool_use_result":{"task":{"id":"1","subject":"create Money"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}]}}
{"type":"result","subtype":"success","is_error":false}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live2.tsv" 7 1 phase-07.md < "$d/stream2.jsonl" > /dev/null
  )
  assert_contains "$d/live2.tsv" "$(printf 'LIVE\t1\trunning')" "the agent's list overrides the inference"
fi

# ---------------------------------------------------------------------------
# 31. REGRESSION: a MIDDLE task that cites no file at all. Real case — "add the
#     plus/minus/times operations to App\Money" happens inside the previous
#     task's file. It must not sit pending until the end of the phase and then
#     jump straight to done, as if it had never run.
# ---------------------------------------------------------------------------
if case_enabled task-fallback-middle; then
  header "31. a middle task with no file of its own is not left behind"
  d="$TMP/task-fallback-middle"
  mkdir -p "$d/.phases"

  cat > "$d/.phases/phase-09.md" <<'PH'
## Phase 9: Money

- [ ] **Task:** create `src/Money.php` with the `App\Money` class
- [ ] **Task:** add the `plus`, `minus` and `times` operations to `App\Money`
- [ ] **Task:** create `tests/MoneyTest.php` covering `App\Money`
PH

  # The agent wrote 2 files for 3 tasks — exactly like the real run.
  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/src/Money.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/tests/MoneyTest.php","content":"..."}}]}}
{"type":"result","subtype":"success","is_error":false}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live.tsv" 9 1 phase-09.md < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 done"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\tdone')" "task 2 (no file of its own) did NOT stay pending"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t3\trunning')" "task 3 running"
fi

# ---------------------------------------------------------------------------
# 32. The task bar measures the whole run, not just the current phase.
# ---------------------------------------------------------------------------
if case_enabled watch-task-total; then
  header "32. the task bar counts every phase"
  d=$(new_case watch-task-total)
  run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" > /dev/null
  # fixture: phase 1 with 2 tasks + phase 2 with 1 task = 3 in total
  RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/panel.txt" 2>&1
  assert_contains "$d/panel.txt" "Tasks  3/3" "total sums the tasks of every phase"
  assert_contains "$d/panel.txt" "Phases 2/2" "phase total"
fi

# ---------------------------------------------------------------------------
# 33. Large plan: the panel fits the terminal height, the top does NOT vanish
#     and the table window follows the current phase.
#     Synthetic state: the panel is a pure reader, so writing the TSV is enough.
# ---------------------------------------------------------------------------
if case_enabled watch-scroll; then
  header "33. the scrolling window keeps the header and follows the current phase"
  d="$TMP/watch-scroll"
  mkdir -p "$d/repo/.phases/state"
  {
    printf 'META\tproject\tbig\n'
    printf 'META\tengine\tclaude\n'
    printf 'META\tstatus\trunning\n'
    printf 'META\tstarted\t%s\n' "$(date +%s)"
    printf 'META\trun\ttest-run\n'
    printf 'META\tpid\t1\n'
    printf 'META\tphase_cur\t8\n'
    for p in $(seq 1 12); do
      st=pending; gates="pending pending pending pending"
      [ "$p" -lt 8 ] && { st=done; gates="pass pass pass pass"; }
      [ "$p" -eq 8 ] && { st=running; gates="pass pass run pending"; }
      printf 'PHASE\t%s\t%s\t1\t%s\tPhase number %s\n' "$p" "$st" "$gates" "$p"
      for t in $(seq 1 4); do
        tst=pending
        [ "$p" -lt 8 ] && tst=done
        printf 'TASK\t%s\t%s\t%s\tTask %s of phase %s\n' "$p" "$t" "$tst" "$t" "$p"
      done
    done
  } > "$d/repo/.phases/state/run.tsv"

  RALPH_WATCH_COLS=110 RALPH_WATCH_LINES=30 \
    "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/panel.txt" 2>&1

  lines=$(wc -l < "$d/panel.txt")
  if [ "$lines" -le 30 ]; then ok "panel fits in 30 lines ($lines)"
  else bad "panel overflowed the height ($lines lines for 30)"; fi

  assert_contains "$d/panel.txt" "RALPH" "header still visible"
  assert_contains "$d/panel.txt" "Phases 7/12" "progress bar still visible"
  assert_contains "$d/panel.txt" "Phase number 8" "current phase inside the window"
  assert_contains "$d/panel.txt" "above" "footer says what was left out"
  assert_not_contains "$d/panel.txt" "Phase number 1 " "a distant phase stayed out of the window"

  # with no pinned height, --once stays a full dump (the scripts' contract)
  RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/full.txt" 2>&1
  assert_contains "$d/full.txt" "Phase number 1 " "full dump keeps the first phase"
  assert_contains "$d/full.txt" "Phase number 12" "full dump keeps the last phase"

  # short plan: no cut, no scroll footer
  RALPH_WATCH_COLS=110 RALPH_WATCH_LINES=80 \
    "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/tall.txt" 2>&1
  assert_contains "$d/tall.txt" "Phase number 1 " "a tall terminal shows everything"
  assert_not_contains "$d/tall.txt" "above ·" "no scroll footer when everything fits"
fi

# ---------------------------------------------------------------------------
# 34. The running row is highlighted end to end.
#     \033[0m clears the background too: without reinjecting the highlight after
#     every reset, it painted only the first separator and vanished in practice.
# ---------------------------------------------------------------------------
if case_enabled watch-hilite; then
  header "34. the running row highlight covers the whole row"
  d="$TMP/watch-hilite"
  mkdir -p "$d/repo/.phases/state"
  {
    printf 'META\tproject\thl\n'
    printf 'META\tstatus\trunning\n'
    printf 'META\tstarted\t%s\n' "$(date +%s)"
    printf 'META\tphase_cur\t2\n'
    printf 'PHASE\t1\tdone\t1\tpass pass pass pass\tFinished phase\n'
    printf 'TASK\t1\t1\tdone\tFinished task\n'
    printf 'PHASE\t2\trunning\t1\tpass pass run pending\tLive phase\n'
    printf 'TASK\t2\t1\tdone\tFinished task of the live phase\n'
    printf 'TASK\t2\t2\trunning\tTask running right now\n'
    printf 'PHASE\t3\tpending\t0\tpending pending pending pending\tFuture phase\n'
  } > "$d/repo/.phases/state/run.tsv"

  RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --color "$d/repo" > "$d/color.txt" 2>&1

  # Every reset inside the row is followed by a fresh highlight; the only reset
  # with no highlight after it is the one ending the row. So: #highlights ==
  # #resets. tail -1: "Live phase" also appears in the CURRENT WORK panel, above
  # the table — the row that matters is the last one.
  hl_balanced() { # <row fragment> -> "resets highlights"
    grep -a "$1" "$d/color.txt" | tail -1 \
      | awk 'BEGIN{esc=sprintf("%c",27)}
             { r=gsub(esc"\\[0m",""); h=gsub(esc"\\[48;5;53m",""); print r" "h }'
  }

  assert_eq "$(echo "$(hl_balanced 'Live phase')" | cut -d' ' -f1)" \
            "$(echo "$(hl_balanced 'Live phase')" | cut -d' ' -f2)" \
            "running phase: highlight reapplied after every reset"
  assert_eq "$(echo "$(hl_balanced 'Task running right now')" | cut -d' ' -f1)" \
            "$(echo "$(hl_balanced 'Task running right now')" | cut -d' ' -f2)" \
            "running task: highlight reapplied after every reset"

  # the highlight does not leak onto idle rows
  assert_eq "0" "$(echo "$(hl_balanced 'Future phase')" | cut -d' ' -f2)" \
            "pending row has no highlight"
  assert_eq "0" "$(echo "$(hl_balanced 'Finished task of the live phase')" | cut -d' ' -f2)" \
            "finished task has no highlight"

  # more than one highlighted run: the old bug painted only the first separator
  wide=$(grep -a "Task running right now" "$d/color.txt" | tail -1 \
    | awk 'BEGIN{esc=sprintf("%c",27)} { print gsub(esc"\\[48;5;53m","") }')
  if [ "${wide:-0}" -ge 4 ]; then ok "highlight spans the row's columns ($wide runs)"
  else bad "highlight covered too few runs of the row (${wide:-0})"; fi
fi

# ---------------------------------------------------------------------------
# 35. REGRESSION (real run): a headless session with NO task-list tool at all —
#     the agent tries to load TaskCreate/TodoWrite via ToolSearch and they do
#     not exist. Progress has to come from the files the task itself declares
#     under "Files:", otherwise the whole phase sits at "Pending" and only
#     changes at gate 3.
# ---------------------------------------------------------------------------
if case_enabled live-declared-files; then
  header "35. progress from declared files, with no task list"
  d="$TMP/live-declared-files"
  mkdir -p "$d/.phases"

  cat > "$d/.phases/phase-02.md" <<'PH'
## Phase 2: Schema, model and writes

Mirror `app/Models/ProductFiscalSetting.php` and `app/Services/Catalog/SaveProductFiscalSettingsService.php`.

- [ ] T03 — Migration `service_fiscal_settings` (additive)
      Files: `database/migrations/tenant/2026_08_15_120000_create_service_fiscal_settings_table.php`
      Change: `iss_rate` `decimal(5,2)` as in `services.iss_rate`
- [ ] T04 — Model `ServiceFiscalSetting`, factory and relation
      Files: `app/Models/ServiceFiscalSetting.php`, `database/factories/ServiceFiscalSettingFactory.php`
      Change: mirrors `app/Models/ProductFiscalSetting.php`
- [ ] T05 — `SaveServiceFiscalSettingsService`
      Files: `app/Services/Catalog/SaveServiceFiscalSettingsService.php`
- [ ] T06 — Tests
      Files: `tests/Feature/Catalog/ServiceFiscalSettingsTest.php`
PH

  # Stream from the real run: ToolSearch finds no task list; only Read/Edit/Write.
  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ToolSearch","input":{"query":"select:TaskCreate,TaskUpdate"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ToolSearch","input":{"query":"select:TodoWrite"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/app/Models/ProductFiscalSetting.php"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/database/migrations/tenant/2026_08_15_120000_create_service_fiscal_settings_table.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/app/Models/ServiceFiscalSetting.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/app/Services/Catalog/SaveServiceFiscalSettingsService.php","content":"..."}}]}}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live.tsv" 2 1 phase-02.md < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 (migration) done"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\tdone')" "task 2 (model) done"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t3\trunning')" "task 3 (service) running"
  assert_not_contains "$d/live.tsv" "$(printf 'LIVE\t4\tdone')" "task 4 (tests) not done yet"

  # reading the mirror file cited in the preamble must not push progress along
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    head -3 "$d/stream.jsonl" | stream_watch "$d/early.tsv" 2 1 phase-02.md > /dev/null
  )
  assert_contains "$d/early.tsv" "$(printf 'LIVE\t1\trunning')" "before the 1st write: task 1 running"
  assert_not_contains "$d/early.tsv" "$(printf 'LIVE\t2\t')" "reading a mirror file does not promote a task"

  # Back-compat: plans written by upstream's planner declare files under the
  # Portuguese "Arquivos:". Both literals must resolve to the same strong signal.
  mkdir -p "$d/pt/.phases"
  cat > "$d/pt/.phases/phase-02.md" <<'PH'
## Phase 2: Legacy plan

- [ ] T01 — Model
      Arquivos: `app/Models/ServiceFiscalSetting.php`
- [ ] T02 — Service
      Arquivos: `app/Services/Catalog/SaveServiceFiscalSettingsService.php`
PH
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/pt/.phases"
    head -5 "$d/stream.jsonl" | stream_watch "$d/pt.tsv" 2 1 phase-02.md > /dev/null
  )
  assert_contains "$d/pt.tsv" "$(printf 'LIVE\t1\trunning')" "legacy 'Arquivos:' still matches a declared file"
fi

# ---------------------------------------------------------------------------
# 36. Text protocol: the agent announces the task in RALPH-TASK lines. It
#     depends on no tool at all, so it works in a headless session — and it
#     takes precedence over the file-based guess.
# ---------------------------------------------------------------------------
if case_enabled live-markers; then
  header "36. RALPH-TASK markers drive the progress"
  d="$TMP/live-markers"
  mkdir -p "$d/.phases"

  cat > "$d/.phases/phase-03.md" <<'PH'
## Phase 3: API

- [ ] T01 — Read endpoint
      Files: `app/Http/Controllers/ReadController.php`
- [ ] T02 — Write endpoint
      Files: `app/Http/Controllers/WriteController.php`
- [ ] T03 — Contract tests
      Files: `tests/Feature/ApiContractTest.php`
PH

  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"Getting started.\n\nRALPH-TASK 1 START"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/app/Http/Controllers/ReadController.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"RALPH-TASK 1 DONE"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"RALPH-TASK 2 START"}]}}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live.tsv" 3 1 phase-03.md < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 closed by the DONE marker"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\trunning')" "task 2 opened by the START marker"
  assert_not_contains "$d/live.tsv" "$(printf 'LIVE\t3\t')" "task 3 untouched"

  # a START marker that skips tasks: the earlier ones count as done
  cat > "$d/jump.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"RALPH-TASK 3 START"}]}}
STREAM
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/jump.tsv" 3 1 phase-03.md < "$d/jump.jsonl" > /dev/null
  )
  assert_contains "$d/jump.tsv" "$(printf 'LIVE\t2\tdone')" "START of task 3 closes the earlier ones"
  assert_contains "$d/jump.tsv" "$(printf 'LIVE\t3\trunning')" "task 3 running"

  # the PROMPT text uses a literal <n>: it must never become a marker
  cat > "$d/prompt.jsonl" <<'STREAM'
{"type":"user","message":{"content":"    RALPH-TASK <n> START     before starting item n"}}
STREAM
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/prompt.tsv" 3 1 phase-03.md < "$d/prompt.jsonl" > /dev/null
  )
  assert_contains "$d/prompt.tsv" "$(printf 'LIVE\t1\trunning')" "echoing the prompt does not move progress"
  assert_not_contains "$d/prompt.tsv" "$(printf 'LIVE\t2\t')" "echoing the prompt does not create tasks"
fi

# ---------------------------------------------------------------------------
# 37. Drawing REGRESSION: the frame must never scroll the screen nor leave a
#     piece of the previous frame showing under the new one.
#
#     The two defects were one chained mechanism. First the frame overflowed the
#     height (the floor of 3 table rows kept 20 lines of panel even on a 12-line
#     screen) and the terminal SCROLLED. From then on \033[H wrote into a shifted
#     screen, and since \033[J only clears from the end of the frame downwards,
#     the header's three blank lines and the short "RALPH" did not erase what was
#     underneath: the top ended up reading "RALPHks 19/32", half new frame and
#     half old, until someone resized the window.
# ---------------------------------------------------------------------------
if case_enabled watch-frame; then
  header "37. the frame respects the screen height and clears every line"
  WATCH="$ROOT/scripts/ralph-watch.sh"

  # -- unit: clamp_lines never returns more lines than the ceiling -------------
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY RALPH_WATCH_COLS=110
    # shellcheck disable=SC1090
    source "$WATCH" 2>/dev/null
    out=""
    clamp_lines out "$(printf 'a\nb\nc\nd\ne')" 3
    printf '%s' "$out" > "$TMP/clamp3.txt"
    clamp_lines out "$(printf 'a\nb')" 9
    printf '%s' "$out" > "$TMP/clamp9.txt"
  )
  n=$(wc -l < "$TMP/clamp3.txt")
  # 3 lines with no trailing \n = 2 breaks: that is what occupies exactly 3 screen lines
  if [ "$n" -eq 2 ]; then ok "clamp_lines cuts at the line ceiling"
  else bad "clamp_lines returned $n breaks, expected 2"; fi
  assert_contains "$TMP/clamp3.txt" "c" "clamp_lines keeps the top lines"
  assert_not_contains "$TMP/clamp3.txt" "d" "clamp_lines discards the overflow"
  assert_contains "$TMP/clamp9.txt" "b" "clamp_lines leaves what already fits alone"

  # -- integration: the real panel on a short terminal -------------------------
  # tmux is the only way to see the screen as the terminal assembles it
  # (scrolling included). Its absence does not fail the check, the same policy
  # shellcheck gets in check-shell.sh.
  if command -v tmux > /dev/null 2>&1; then
    d="$TMP/watch-frame"
    mkdir -p "$d/repo/.phases/state"
    {
      printf 'META\tproject\tframe\n'
      printf 'META\tengine\tclaude\n'
      printf 'META\tstatus\trunning\n'
      printf 'META\tstarted\t%s\n' "$(date +%s)"
      printf 'META\trun\tframe-run\n'
      printf 'META\tpid\t1\n'
      printf 'META\tphase_cur\t1\n'
      for p in $(seq 1 10); do
        printf 'PHASE\t%s\trunning\t1\tpass pass run pending\tPhase number %s\n' "$p" "$p"
        for t in $(seq 1 3); do
          printf 'TASK\t%s\t%s\tpending\tTask %s of phase %s\n' "$p" "$t" "$t" "$p"
        done
      done
    } > "$d/repo/.phases/state/run.tsv"

    # --embedded draws on the normal screen, with no alternate screen: it is
    # --dashboard's mode and the only one where the pane keeps what was really
    # drawn.
    tmux kill-session -t ralph-frame-test 2>/dev/null || true
    tmux new-session -d -s ralph-frame-test -x 120 -y 16 \
      "bash '$WATCH' --embedded --interval 1 '$d/repo'" 2>/dev/null || true
    sleep 4
    tmux capture-pane -p -t ralph-frame-test > "$d/pane.txt" 2>/dev/null || true
    tmux kill-session -t ralph-frame-test 2>/dev/null || true

    # The top of the panel has to be at the top of the SCREEN. Scrolling pushes
    # "RALPH" off and the first line becomes a slice from the middle of the frame.
    if [ -s "$d/pane.txt" ]; then
      head_txt=$(head -3 "$d/pane.txt")
      if printf '%s' "$head_txt" | grep -q 'RALPH'; then
        ok "short screen: the top of the panel did not scroll off"
      else
        bad "short screen: the top scrolled (first lines: $(head -1 "$d/pane.txt" | cut -c1-40))"
      fi
      lines=$(grep -c '' "$d/pane.txt")
      if [ "$lines" -le 16 ]; then ok "short screen: panel within 16 lines ($lines)"
      else bad "short screen: panel took $lines lines out of 16"; fi
    else
      ok "tmux returned no pane (environment with no tty) — integration skipped"
    fi
  else
    ok "tmux absent — frame integration skipped"
  fi
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
