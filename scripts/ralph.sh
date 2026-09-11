#!/usr/bin/env bash
#
# ralph.sh
#
# Orchestrator that reads a phases document, splits it into phases, and feeds
# each one to the Codex CLI or Claude Code for automatic implementation.
#
# Invariants:
#   1. Each phase AND each fix cycle runs in a NEW session, with a
#      self-contained prompt. Never reuses a session.
#   2. Zero questions. Start to finish with no human interaction.
#   3. A phase is only "complete" when it passes 4 mechanical gates, never by
#      the engine's exit code.
#   4. Usage limit -> waits for the reset and re-runs the SAME phase, without
#      consuming a fix cycle.
#   5. One commit per completed phase.
#
# Stack-agnostic: the phase and the project's CLAUDE.md/AGENTS.md define
# language, framework, commands and conventions.
#
# Usage:
#   ./ralph.sh [options] [file-path]
#
# Options:
#   --engine codex|claude    implementation engine (default: codex)
#   --from N                 start at phase N (clears progress for phases >= N)
#   --keep-going             continue after a phase fails (default: stop)
#   --max-cycles N           fix cycles per phase (default: 3)
#   --no-verify              turns off gate 3 (equivalent to RALPH_VERIFY=off)
#   --test-cmd "<cmd>"       project test command (gate 2)
#
# Input (first positional argument). With no argument, resolves in this order:
#   1. .spec/init/project-phases.md      (init chain)
#   2. .spec/project-phases.md           (pre-init repos, with a warning)
#
#   A feature's PHASES.md is also valid input:
#     ./ralph.sh .spec/features/<slug>/PHASES.md
#
# Input format contract (validated in preflight):
#   - >= 1 heading `## Phase N: <title>`
#   - no `## Phase ...` heading outside that format
#   - sub-phases as `### Phase N.M:` (do not get their own session)
#   - any other `## ` closes the capture of the previous phase
#
# Gates per phase (all green -> commit; any red -> fix cycle):
#   0. engine actually finished (claude: is_error in the JSON; codex: exit code)
#   1. did the session write code? SIGNAL, not verdict — a phase already
#      implemented correctly makes the engine write nothing. Feeds the fix
#      cycle's cause when a later gate fails.
#   2. project test suite, run BY ralph (outside the agent session)
#   3. independent, read-only verifier session, task by task — the final gate,
#      runs on every phase (RALPH_VERIFY=always, default). RALPH_VERIFY=auto
#      saves cost: only runs when gate 2's verdict is not enough — a session
#      that wrote nothing (claims "already implemented"), a fix cycle, or
#      gate 2 disabled. --no-verify / RALPH_VERIFY=off turns it off. On the
#      claude engine the verifier uses a cheap model (RALPH_VERIFY_MODEL,
#      default: haiku) — it's read + checklist.
#
# Green gates with a clean tree => the phase was already implemented on HEAD:
# marked as done, no commit (nothing to commit).
#
# Test command (gate 2), first rule that resolves:
#   1. --test-cmd "<cmd>"
#   2. RALPH_TEST_CMD
#   3. manifest-based detection:
#        Laravel Sail (artisan + vendor/bin/sail)  -> vendor/bin/sail test
#        composer.json with scripts.test            -> composer test
#        artisan                                    -> php artisan test
#        package.json with scripts.test             -> npm test
#        pytest.ini / pyproject [tool.pytest]        -> pytest
#        go.mod                                      -> go test ./...
#        Cargo.toml                                  -> cargo test
#   4. nothing resolved -> loud warning + gate 2 skipped (gate 3 carries it alone)
#
# Laravel Sail: the suite runs inside the container, so Sail takes precedence
# over `composer test`. Containers stopped -> abort in preflight (every gate 2
# would fail, burning fix cycles).
#
# Environment variables:
#   RALPH_TEST_CMD           test command (gate 2); --test-cmd takes priority
#   RALPH_VERIFY             gate 3: always (default) | auto | off
#   RALPH_VERIFY_MODEL       verifier model (default: haiku on claude)
#   RALPH_MAX_CYCLES         fix cycles per phase (default: 3)
#   RALPH_MAX_LIMIT_WAITS    consecutive limit waits, per phase (default: 20)
#   RALPH_LIMIT_WAIT_DEFAULT wait fallback in seconds (default: 1800)
#   RALPH_LIMIT_BUFFER       extra seconds after the reset (default: 60)
#
# Exported for hooks (e.g. notify-n8n.sh) during each engine session:
#   RALPH_ENGINE             codex | claude
#   RALPH_PHASE_TITLE        current phase title
#   RALPH_PHASE_NUM          current phase number
#   RALPH_PHASE_TOTAL        total phases in the run
#   RALPH_PHASE_ATTEMPT      current cycle (1 = initial implementation)
#   RALPH_PHASE_MAX_ATTEMPTS equal to RALPH_MAX_CYCLES
#
# Exit code: 0 = all phases green; 1 = something failed or aborted.
#
# Prerequisites:
#   - Codex: npm install -g @openai/codex + OPENAI_API_KEY
#   - Claude: npm install -g @anthropic-ai/claude-code + ANTHROPIC_API_KEY
#   - Root of a git repo, with a clean working tree

set -euo pipefail

ENGINE="codex"
INPUT_FILE=""
FROM_PHASE=0
KEEP_GOING=false
TEST_CMD_FLAG=""
MAX_CYCLES="${RALPH_MAX_CYCLES:-3}"
VERIFY_MODE="${RALPH_VERIFY:-always}"
VERIFY_MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)      ENGINE="$2"; shift 2 ;;
    --engine=*)    ENGINE="${1#*=}"; shift ;;
    --from)        FROM_PHASE="$2"; shift 2 ;;
    --from=*)      FROM_PHASE="${1#*=}"; shift ;;
    --max-cycles)  MAX_CYCLES="$2"; shift 2 ;;
    --max-cycles=*) MAX_CYCLES="${1#*=}"; shift ;;
    --test-cmd)    TEST_CMD_FLAG="$2"; shift 2 ;;
    --test-cmd=*)  TEST_CMD_FLAG="${1#*=}"; shift ;;
    --keep-going)  KEEP_GOING=true; shift ;;
    --no-verify)   VERIFY_MODE="off"; shift ;;
    -h|--help)     sed -n '2,70p' "$0"; exit 0 ;;
    *)             INPUT_FILE="$1"; shift ;;
  esac
done

PHASES_DIR=".phases"
LOG_DIR=".phases/logs"
PROMPT_DIR=".phases/prompts"
MANIFEST="$PHASES_DIR/manifest.txt"
PROGRESS_FILE="$PHASES_DIR/.progress"

MAX_LIMIT_WAITS="${RALPH_MAX_LIMIT_WAITS:-20}"
LIMIT_WAIT_DEFAULT="${RALPH_LIMIT_WAIT_DEFAULT:-1800}"
LIMIT_BUFFER="${RALPH_LIMIT_BUFFER:-60}"

TEST_CMD=""
SAIL_BIN=""
LIMIT_WAITS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] $1${NC}"; }
fail()    { echo -e "${RED}[$(date '+%H:%M:%S')] $1${NC}"; }

format_duration() {
  local total_seconds=$1
  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))

  if [ "$hours" -gt 0 ]; then
    printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
  elif [ "$minutes" -gt 0 ]; then
    printf "%dm %ds" "$minutes" "$seconds"
  else
    printf "%ds" "$seconds"
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

resolve_input_file() {
  if [ -n "$INPUT_FILE" ]; then
    return 0
  fi

  if [ -f ".spec/init/project-phases.md" ]; then
    INPUT_FILE=".spec/init/project-phases.md"
  elif [ -f ".spec/project-phases.md" ]; then
    INPUT_FILE=".spec/project-phases.md"
    warn "Using .spec/project-phases.md (pre-init layout). The current default is .spec/init/project-phases.md."
  else
    fail "No phases document found."
    fail "Expected .spec/init/project-phases.md (run /init:project-phases) or pass the path as an argument."
    exit 1
  fi
}

validate_input_format() {
  local top_level
  top_level=$(grep -cE '^## Phase [0-9]+: ' "$INPUT_FILE" || true)

  if [ "$top_level" -lt 1 ]; then
    fail "Format contract violated: no '## Phase N: <title>' heading in $INPUT_FILE"
    fail "ralph splits the document by that heading. Fix the document before running."
    exit 1
  fi

  local malformed
  malformed=$(grep -E '^## Phase' "$INPUT_FILE" | grep -vE '^## Phase [0-9]+: ' || true)
  if [ -n "$malformed" ]; then
    fail "Format contract violated: '## Phase' headings outside the '## Phase N: <title>' format:"
    echo "$malformed" | sed 's/^/    /'
    fail "A phase with a malformed heading silently disappears from the run. Fix it before burning tokens."
    exit 1
  fi

  log "Input format OK ($top_level phases declared)"
}

exclude_phases_dir() {
  local exclude_file
  exclude_file="$(git rev-parse --git-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  if ! grep -qxF '/.phases/' "$exclude_file" 2>/dev/null; then
    echo '/.phases/' >> "$exclude_file"
    log "Registered /.phases/ in .git/info/exclude (does not touch the project's own .gitignore)"
  fi
}

# Laravel Sail: the suite runs INSIDE the container. Running `composer test` /
# `php artisan test` on the host fails (no PHP, no database, no compose network).
# Echoes the sail binary path when the project uses Sail.
detect_sail() {
  [ -f artisan ] || return 1
  if [ -x vendor/bin/sail ]; then
    echo "vendor/bin/sail"
    return 0
  fi
  # Sail declared in composer.json but vendor/ not installed yet.
  if [ -f composer.json ] && grep -qF 'laravel/sail' composer.json; then
    echo "vendor/bin/sail"
    return 0
  fi
  return 1
}

# Containers up? Sail's wrapper prints "Sail is not running." and exits != 0.
sail_running() {
  local out rc=0
  out=$("$SAIL_BIN" ps 2>&1) || rc=$?
  grep -qiF 'is not running' <<< "$out" && return 1
  [ "$rc" -ne 0 ] && return 1
  grep -qiE '(^|[[:space:]])(Up|running)([[:space:]]|$)' <<< "$out"
}

# Does the test command invoke sail? Looks at the executable (1st token), not
# the whole string: a path like /tmp/sail-fixture/test.sh does not use sail.
test_cmd_uses_sail() {
  local first="${TEST_CMD%% *}"
  [ "$(basename -- "$first")" = "sail" ]
}

# Gate 2 is only useful if it actually runs. Sail with stopped containers fails
# every phase and burns fix cycles for nothing — abort before the 1st session.
check_sail_running() {
  [ -n "$SAIL_BIN" ] || return 0
  test_cmd_uses_sail || return 0

  if [ ! -x "$SAIL_BIN" ]; then
    fail "Laravel Sail detected, but $SAIL_BIN does not exist."
    fail "Run the project's dependency install (e.g. composer install) first."
    exit 1
  fi

  if ! sail_running; then
    fail "Laravel Sail detected, but the containers are not up."
    fail "The test suite (gate 2) runs inside the container and would fail every phase."
    fail "Bring the environment up before running ralph:"
    fail "    $SAIL_BIN up -d"
    exit 1
  fi

  log "Sail: containers up"
}

resolve_test_cmd() {
  SAIL_BIN="$(detect_sail || true)"

  if [ -n "$TEST_CMD_FLAG" ]; then
    TEST_CMD="$TEST_CMD_FLAG"
    log "Gate 2 — test command (--test-cmd): $TEST_CMD"
    check_sail_running
    return 0
  fi

  if [ -n "${RALPH_TEST_CMD:-}" ]; then
    TEST_CMD="$RALPH_TEST_CMD"
    log "Gate 2 — test command (RALPH_TEST_CMD): $TEST_CMD"
    check_sail_running
    return 0
  fi

  # Sail comes BEFORE composer/npm: in a dockerized Laravel project the host has
  # neither PHP nor database access, and `composer test` would lie as a gate.
  if [ -n "$SAIL_BIN" ]; then
    TEST_CMD="$SAIL_BIN test"
  elif [ -f composer.json ] && grep -qE '"test"[[:space:]]*:' composer.json; then
    TEST_CMD="composer test"
  elif [ -f artisan ]; then
    TEST_CMD="php artisan test"
  elif [ -f package.json ] && grep -qE '"test"[[:space:]]*:' package.json; then
    TEST_CMD="npm test"
  elif [ -f pytest.ini ] || { [ -f pyproject.toml ] && grep -qF '[tool.pytest' pyproject.toml; }; then
    # pytest may be stuck inside a managed virtualenv (uv/Poetry/Pipenv) and
    # off the host's PATH; plain `pytest` would lie as a gate in that case.
    if [ -f uv.lock ]; then
      TEST_CMD="uv run pytest"
    elif [ -f pyproject.toml ] && grep -qF '[tool.poetry]' pyproject.toml; then
      TEST_CMD="poetry run pytest"
    elif [ -f Pipfile ]; then
      TEST_CMD="pipenv run pytest"
    else
      TEST_CMD="pytest"
    fi
  elif [ -f go.mod ]; then
    TEST_CMD="go test ./..."
  elif [ -f Cargo.toml ]; then
    TEST_CMD="cargo test"
  fi

  if [ -n "$TEST_CMD" ]; then
    log "Gate 2 — test command (detected): $TEST_CMD"
    check_sail_running
  else
    warn "Gate 2 DISABLED: no test command resolved."
    if [ "$VERIFY_MODE" = "off" ]; then
      warn "--no-verify also turned off gate 3: NO mechanical validation active."
    else
      warn "Pass --test-cmd '<cmd>' or set RALPH_TEST_CMD. Gate 3 (verifier) runs on every phase."
    fi
  fi
}

preflight_checks() {
  if [[ "$ENGINE" != "codex" && "$ENGINE" != "claude" ]]; then
    fail "Invalid engine: $ENGINE. Use 'codex' or 'claude'."
    exit 1
  fi

  if ! [[ "$FROM_PHASE" =~ ^[0-9]+$ ]]; then
    fail "Invalid value for --from: '$FROM_PHASE'. Use an integer (e.g. --from 5)."
    exit 1
  fi

  if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]] || [ "$MAX_CYCLES" -lt 1 ]; then
    fail "Invalid value for --max-cycles: '$MAX_CYCLES'. Use an integer >= 1."
    exit 1
  fi

  case "$VERIFY_MODE" in
    auto|always|off) ;;
    *)
      fail "Invalid value for RALPH_VERIFY: '$VERIFY_MODE'. Use auto, always or off."
      exit 1
      ;;
  esac

  # Verification is read + checklist: it doesn't need the implementation model.
  # Codex has no safe cheap-model default — only applies when explicitly requested.
  if [ -n "${RALPH_VERIFY_MODEL:-}" ]; then
    VERIFY_MODEL="$RALPH_VERIFY_MODEL"
  elif [[ "$ENGINE" == "claude" ]]; then
    VERIFY_MODEL="haiku"
  fi

  if ! command -v "$ENGINE" &> /dev/null; then
    if [[ "$ENGINE" == "codex" ]]; then
      fail "codex CLI not found. Install with: npm install -g @openai/codex"
    else
      fail "Claude Code CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
    fi
    exit 1
  fi

  if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
    fail "Requires a git repository."
    exit 1
  fi

  resolve_input_file

  if [ ! -f "$INPUT_FILE" ]; then
    fail "File not found: $INPUT_FILE"
    exit 1
  fi

  validate_input_format
  exclude_phases_dir

  # Clean tree: 'git add -A' on the first phase would swallow uncommitted work.
  if [ -n "$(git status --porcelain)" ]; then
    fail "Working tree is dirty. ralph commits per phase and would swallow your changes."
    fail "Commit or stash before running:"
    git status --short | sed 's/^/    /'
    exit 1
  fi

  resolve_test_cmd

  success "Pre-checks OK (engine: $ENGINE, input: $INPUT_FILE)"
}

# ---------------------------------------------------------------------------
# Split + progress
# ---------------------------------------------------------------------------

manifest_entries() { grep -v '^#' "$MANIFEST" || true; }

split_phases() {
  log "Splitting $INPUT_FILE into phases..."

  local new_stamp old_stamp="" progress_backup=""
  new_stamp="$(basename "$INPUT_FILE")@sha256:$(sha256sum "$INPUT_FILE" | cut -c1-12)"

  if [ -f "$MANIFEST" ]; then
    old_stamp=$(sed -n '1s/^# stamp: //p' "$MANIFEST")
  fi
  if [ -f "$PROGRESS_FILE" ]; then
    progress_backup=$(cat "$PROGRESS_FILE")
  fi

  rm -rf "$PHASES_DIR"
  mkdir -p "$PHASES_DIR" "$LOG_DIR" "$PROMPT_DIR"

  # Progress survives across runs, but only for the SAME input.
  if [ -n "$progress_backup" ]; then
    if [ -n "$old_stamp" ] && [ "$old_stamp" = "$new_stamp" ]; then
      printf '%s\n' "$progress_backup" > "$PROGRESS_FILE"
      log "Previous progress preserved (input unchanged)"
    else
      warn "The phases document changed since the last run — progress reset."
      warn "Phases marked as done belonged to a different plan."
    fi
  fi

  echo "# stamp: $new_stamp" > "$MANIFEST"

  local current_file=""
  local phase_count=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^##[[:space:]]+Phase[[:space:]]+([0-9]+):[[:space:]]*(.*)$ ]]; then
      phase_count=$((phase_count + 1))

      local phase_num="${BASH_REMATCH[1]}"
      local phase_title="${BASH_REMATCH[2]}"
      phase_title="$(echo "$phase_title" | sed 's/[[:space:]]*$//')"

      local slug
      slug=$(printf 'phase-%02d' "$phase_num")

      current_file="$PHASES_DIR/${slug}.md"
      echo "$line" > "$current_file"
      echo "${slug}.md|${phase_num}|${phase_title}" >> "$MANIFEST"
      continue
    fi

    # Level-2 heading that isn't "## Phase N:" (e.g. "## Open Questions"):
    # closes the capture so the section doesn't leak into the last phase.
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      current_file=""
      continue
    fi

    if [ -n "$current_file" ]; then
      echo "$line" >> "$current_file"
    fi
  done < "$INPUT_FILE"

  success "$phase_count phases extracted"
}

is_phase_done() {
  local phase_file="$1"
  [ -f "$PROGRESS_FILE" ] && grep -qxF "$phase_file" "$PROGRESS_FILE"
}

mark_phase_done() {
  echo "$1" >> "$PROGRESS_FILE"
}

# --from N also clears progress for phases >= N (intentional re-run).
apply_from_override() {
  [ "$FROM_PHASE" -gt 1 ] || return 0
  [ -f "$PROGRESS_FILE" ] || return 0

  local kept="" file num _rest
  while IFS='|' read -r file num _rest; do
    if [ "$num" -lt "$FROM_PHASE" ] && grep -qxF "$file" "$PROGRESS_FILE"; then
      kept+="$file"$'\n'
    fi
  done < <(manifest_entries)

  printf '%s' "$kept" > "$PROGRESS_FILE"
  log "--from $FROM_PHASE: progress for phases >= $FROM_PHASE cleared"
}

# ---------------------------------------------------------------------------
# Prompts (self-contained — every session is new)
# ---------------------------------------------------------------------------

context_preamble() {
  cat <<'PREAMBLE'
## Discover the stack and conventions before writing code
This project may be in any language or framework. Do NOT assume any stack.
Before starting, READ whichever of these exist, in this order:
1. AGENTS.md or CLAUDE.md — project conventions, commands and rules
2. .spec/init/project-description.md — general project description
3. .spec/init/user-stories.md — user stories
4. .spec/init/database-schema.md — data model
5. the documents cited in the phase text itself (e.g. the feature's SPEC.md/PLAN.md)
Use the build, test and run commands defined by those documents and by the
tooling already present in the repository. If the project has a configured
memory or context tool, use it to understand the history.
PREAMBLE

  # Gate 2 runs THIS command. If the agent runs a different one (e.g. `php
  # artisan test` on a Sail project's host), it sees green while the gate sees red.
  if [ -n "$TEST_CMD" ]; then
    echo
    echo "## This project's test command"
    echo "ALWAYS run the suite with:"
    echo
    echo "    $TEST_CMD"
    echo
    echo "This is the exact command used to validate the phase. Do not use another"
    echo "runner or run the tests outside of it."
    if [ -n "$SAIL_BIN" ]; then
      echo "The project uses Laravel Sail: artisan, composer, php and tests run INSIDE"
      echo "the container, via '$SAIL_BIN <cmd>'. Never run these tools on the host."
    fi
  fi
}

build_impl_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "You are a senior developer implementing a phase of this project."
    echo
    context_preamble
    cat <<'TASK'

## Your task now
FULLY implement the phase described below.

For each item:
1. Implement the complete code (leave no TODOs or placeholders)
2. Create the listed tests, following the project's test framework
3. Run the tests with the project's test command
4. If a test fails, fix the code and run it again
5. Only move to the next item once the tests pass

## Mandatory rules
- ALWAYS use the commands, test runner and tools already adopted by the
  project (do not introduce a new stack or tool on your own)
- Tests and fixtures/factories must create all necessary dependencies
- Class, file and method names must EXACTLY follow what is described
- Do not skip any item marked with [ ]
- At the end, verify that the phase's entire test suite passes

## Phase to implement
TASK
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# Fix prompt: self-contained. Loads the entire phase + the REAL cause of
# the failure (never a generic "tests failed").
build_fix_prompt() {
  local phase_file="$1" cycle="$2" gate="$3" cause="$4"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "You are a senior developer fixing a partially implemented phase."
    echo
    context_preamble
    cat <<'INTRO'

## Situation
A previous session tried to implement the phase below and did NOT pass verification.
You are in a new session: you have no memory of what was done. Read the current
code before changing anything.

## Mandatory rules
- Fix ONLY what is missing. Do not reimplement what is already correct and tested.
- Leave no TODOs, placeholders, or skipped tests.
- Run the project's test suite at the end and make sure it passes.
INTRO
    echo
    echo "## Reason for the failure ($gate)"
    echo '```'
    echo "$cause"
    echo '```'
    echo
    echo "## Phase to complete"
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

build_verify_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.verify-${cycle}.txt"

  {
    cat <<'VERIFY'
RALPH_VERIFY

You are an independent verifier. Do NOT write, edit or create any file.
Your only job is to read the real code and say what is done and what is not.

For EACH task marked `- [ ]` or `- [x]` in the phase below, in the order they
appear, check the acceptance criteria against the real code (files, classes,
tests, routes, migrations — whatever the task requires) and emit EXACTLY ONE line:

TASK <n>: DONE
TASK <n>: INCOMPLETE — <what is missing>

Rules:
- <n> is the task's index within the phase, starting at 1.
- One TASK line per task, no exceptions, no grouping.
- Do not emit any text other than the TASK lines.
- Missing code, TODO, placeholder, or missing test => INCOMPLETE.
- When in doubt, INCOMPLETE.

## Phase to verify
VERIFY
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# ---------------------------------------------------------------------------
# Usage limit (item 5) — only looks at the END of the log, with per-engine patterns
# ---------------------------------------------------------------------------

# Echoes the reset epoch when found, "0" for a limit with no timestamp.
# Returns 0 when a limit is detected, 1 when there is no limit.
detect_usage_limit() {
  local log_file="$1"
  local tail_txt pattern epoch

  # The limit message appears at the END of the run. Scanning the whole log makes
  # project test output ("429", "Too Many Requests") trigger a bogus 30min wait.
  tail_txt=$(tail -n 20 "$log_file" 2>/dev/null || true)

  if [[ "$ENGINE" == "claude" ]]; then
    pattern='usage limit reached'
  else
    pattern='rate limit reached|quota exceeded|usage limit reached'
  fi

  grep -qiE "$pattern" <<< "$tail_txt" || return 1

  epoch=$(grep -oiE 'usage limit reached[^0-9]*[0-9]{10,13}' <<< "$tail_txt" \
    | grep -oE '[0-9]{10,13}' | tail -1 || true)

  if [ -z "$epoch" ]; then
    epoch=$(grep -oiE 'reset[a-z ]*[0-9]{10,13}' <<< "$tail_txt" \
      | grep -oE '[0-9]{10,13}' | tail -1 || true)
  fi

  echo "${epoch:-0}"
  return 0
}

wait_for_reset() {
  local epoch="$1"
  local now wait_secs
  now=$(date +%s)

  LIMIT_WAITS=$((LIMIT_WAITS + 1))
  if [ "$LIMIT_WAITS" -gt "$MAX_LIMIT_WAITS" ]; then
    fail "Usage limit hit $LIMIT_WAITS times in a row on this phase (cap: $MAX_LIMIT_WAITS)."
    fail "Aborting instead of sleeping indefinitely."
    exit 1
  fi

  if [[ "$epoch" =~ ^[0-9]+$ ]] && [ "$epoch" -gt 0 ]; then
    if [ "${#epoch}" -ge 13 ]; then
      epoch=$((epoch / 1000))
    fi
    wait_secs=$((epoch - now + LIMIT_BUFFER))
    if [ "$wait_secs" -lt "$LIMIT_BUFFER" ]; then
      wait_secs=$LIMIT_BUFFER
    fi
    warn "Usage limit reached. Reset expected at $(date -d "@$epoch" '+%d/%m %H:%M:%S')."
  else
    wait_secs=$LIMIT_WAIT_DEFAULT
    warn "Usage limit reached. No reset time in the output; waiting on the fallback."
  fi

  warn "Wait $LIMIT_WAITS/$MAX_LIMIT_WAITS — waiting $(format_duration "$wait_secs") before resuming the SAME phase..."

  local remaining=$wait_secs chunk
  while [ "$remaining" -gt 0 ]; do
    chunk=60
    [ "$remaining" -lt 60 ] && chunk=$remaining
    sleep "$chunk"
    remaining=$((remaining - chunk))
    [ "$remaining" -gt 0 ] && log "Resuming in $(format_duration "$remaining")..."
  done

  success "Reset likely complete. Resuming execution."
}

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

# run_engine <prompt_file> <log_file> <mode: impl|verify>
# Resilience loop for usage limits: does not consume a fix cycle.
run_engine() {
  local prompt_file="$1" log_file="$2" mode="$3"

  export RALPH_ENGINE="$ENGINE"
  export RALPH_PHASE_MAX_ATTEMPTS="$MAX_CYCLES"

  local model_args=()
  if [[ "$mode" == "verify" ]] && [ -n "$VERIFY_MODEL" ]; then
    model_args=(--model "$VERIFY_MODEL")
  fi

  while true; do
    local rc=0

    if [[ "$ENGINE" == "codex" ]]; then
      if [[ "$mode" == "verify" ]]; then
        codex exec --sandbox read-only "${model_args[@]}" - < "$prompt_file" 2>&1 | tee "$log_file" || rc=$?
      else
        codex exec --sandbox danger-full-access - < "$prompt_file" 2>&1 | tee "$log_file" || rc=$?
      fi
    else
      # < /dev/null: claude -p reads stdin when it's not a TTY. Without the
      # redirect it consumes the caller's stream (e.g. the phase loop's manifest).
      if [[ "$mode" == "verify" ]]; then
        env -u CLAUDECODE claude --dangerously-skip-permissions \
          "${model_args[@]}" \
          -p "$(cat "$prompt_file")" \
          --allowedTools "Read,Glob,Grep" \
          --output-format text < /dev/null 2>&1 | tee "$log_file" || rc=$?
      else
        # JSON: the CLI's exit code is a weak signal; gate 0 reads is_error.
        env -u CLAUDECODE claude --dangerously-skip-permissions \
          -p "$(cat "$prompt_file")" \
          --output-format json < /dev/null 2>&1 | tee "$log_file" || rc=$?
      fi
    fi

    local reset_epoch
    if reset_epoch=$(detect_usage_limit "$log_file"); then
      wait_for_reset "$reset_epoch"
      continue
    fi

    return "$rc"
  done
}

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

# Gate 0 — did the engine actually finish?
# Fills GATE_CAUSE when red.
GATE_CAUSE=""

gate0_engine_finished() {
  local log_file="$1" rc="$2"

  if [[ "$ENGINE" == "claude" ]]; then
    if ! grep -qF '"type":"result"' "$log_file" && ! grep -qF '"type": "result"' "$log_file"; then
      GATE_CAUSE="The engine ended without emitting a result. Last lines of the output:"$'\n'"$(tail -n 40 "$log_file")"
      return 1
    fi
    if grep -qE '"is_error"[[:space:]]*:[[:space:]]*true' "$log_file"; then
      GATE_CAUSE="The engine reported is_error=true. Last lines of the output:"$'\n'"$(tail -n 40 "$log_file")"
      return 1
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="The engine exited with code $rc. Last lines of the output:"$'\n'"$(tail -n 40 "$log_file")"
    return 1
  fi

  return 0
}

# Tree signature: tracked (status + diff) and untracked (content).
# Never mutates the index.
tree_signature() {
  {
    git status --porcelain
    git diff HEAD
    git ls-files --others --exclude-standard -z | xargs -0 -r sha256sum 2> /dev/null
  } 2> /dev/null | sha256sum | cut -c1-16
}

# Gate 1 — did this session write code?
#
# SIGNAL, not verdict. A phase may already be implemented before the session
# (tasks `[x]`, a previous run committed, dev implemented it by hand). In that
# case the correct engine writes NOTHING, and failing here would be a false
# negative: only gates 2 and 3 know whether the code is actually complete.
#
# The return feeds the fix cycle's cause ("the session wrote nothing") when
# a later gate fails.
gate1_session_wrote() {
  local sig_before="$1"
  [ "$(tree_signature)" != "$sig_before" ]
}

# Gate 2 — does the project's suite pass, run BY ralph (outside the agent session)?
gate2_tests_pass() {
  local test_log="$1"

  if [ -z "$TEST_CMD" ]; then
    return 0
  fi

  log "Gate 2 — running the project's suite: $TEST_CMD"
  local rc=0
  # < /dev/null: sail test (docker compose exec) attaches stdin and would consume
  # the caller's stream, and could also hang waiting for input.
  bash -c "$TEST_CMD" < /dev/null > "$test_log" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="The project's test command ('$TEST_CMD') failed with code $rc. Output:"$'\n'"$(tail -n 200 "$test_log")"
    return 1
  fi

  success "Gate 2 — suite green"
  return 0
}

# Gate 3 — independent, read-only verifier session, task by task.
# The final gate: runs on every phase by default (always). Auto mode saves
# cost, running only when gate 2's verdict is not enough:
#   - the session wrote nothing (claims "already implemented" — only the
#     independent verification confirms this without trusting the engine's word)
#   - fix cycle (the phase already failed once)
#   - gate 2 disabled (with no suite, the verifier is the only gate)
# GATE3_RAN tells the "already implemented" path which gates actually validated HEAD.
GATE3_RAN=0

gate3_independent_verify() {
  local phase_file="$1" cycle="$2" session_wrote="$3"
  local verify_log="$LOG_DIR/${phase_file%.md}.verify-${cycle}.log"

  GATE3_RAN=0

  case "$VERIFY_MODE" in
    off)
      log "Gate 3 skipped (--no-verify)"
      return 0
      ;;
    auto)
      if [ "$cycle" -eq 1 ] && [ "$session_wrote" -eq 1 ] && [ -n "$TEST_CMD" ]; then
        log "Gate 3 skipped: the session wrote code and the suite passed (RALPH_VERIFY=always to always run it)"
        return 0
      fi
      ;;
  esac

  local expected
  expected=$(grep -cE '^[[:space:]]*- \[[ x]\]' "$PHASES_DIR/$phase_file" || true)

  if [ "$expected" -eq 0 ]; then
    warn "Gate 3 skipped: the phase declares no '- [ ]' task"
    return 0
  fi

  GATE3_RAN=1
  log "Gate 3 — independent verifier session ($expected tasks${VERIFY_MODEL:+, model: $VERIFY_MODEL})"

  local prompt_file
  prompt_file=$(build_verify_prompt "$phase_file" "$cycle")
  run_engine "$prompt_file" "$verify_log" verify || true

  local task_lines
  task_lines=$(sed 's/^[[:space:]]*//' "$verify_log" | grep -E '^TASK [0-9]+: (DONE|INCOMPLETE)' || true)

  local parsed
  parsed=$(printf '%s' "$task_lines" | grep -c . || true)

  if [ "$parsed" -eq 0 ]; then
    GATE_CAUSE="The independent verifier did not emit any 'TASK <n>: DONE|INCOMPLETE' line — could not confirm the phase is complete. Last lines of the verifier:"$'\n'"$(tail -n 40 "$verify_log")"
    return 1
  fi

  if [ "$parsed" -ne "$expected" ]; then
    GATE_CAUSE="The verifier covered $parsed of $expected tasks — incomplete coverage. Lines emitted:"$'\n'"$task_lines"
    return 1
  fi

  local incomplete
  incomplete=$(printf '%s\n' "$task_lines" | grep 'INCOMPLETE' || true)

  if [ -n "$incomplete" ]; then
    GATE_CAUSE="The independent verifier found incomplete tasks:"$'\n'"$incomplete"
    return 1
  fi

  success "Gate 3 — $parsed/$expected tasks confirmed in the code"
  return 0
}

# ---------------------------------------------------------------------------
# Phase execution
# ---------------------------------------------------------------------------

commit_phase() {
  local phase_num="$1" phase_title="$2"
  git add -A
  if git diff --cached --quiet; then
    fail "Nothing to commit after the gates — unexpected state."
    return 1
  fi
  git commit -q -m "feat(phase-${phase_num}): ${phase_title}"
  log "Commit created: feat(phase-${phase_num}): ${phase_title}"
}

commit_wip() {
  local phase_num="$1"
  [ -n "$(git status --porcelain)" ] || return 0
  git add -A
  git commit -q -m "wip(phase-${phase_num}): incomplete — see .phases/logs/"
  warn "Created wip commit for phase $phase_num — the next phase starts from a clean tree"
}

# run_phase <phase_file> <phase_num> <phase_title> <seq> <total>
run_phase() {
  local phase_file="$1" phase_num="$2" phase_title="$3" seq="$4" total="$5"
  local phase_start
  phase_start=$(date +%s)

  export RALPH_PHASE_TITLE="$phase_title"
  export RALPH_PHASE_NUM="$phase_num"
  export RALPH_PHASE_TOTAL="$total"

  LIMIT_WAITS=0
  GATE_CAUSE=""

  echo ""
  log "[$seq/$total] Phase $phase_num: $phase_title"

  local cycle=1
  while [ "$cycle" -le "$MAX_CYCLES" ]; do
    export RALPH_PHASE_ATTEMPT="$cycle"
    [ "$cycle" -gt 1 ] && warn "Fix cycle $cycle/$MAX_CYCLES..."

    local prompt_file log_file rc=0 sig_before
    log_file="$LOG_DIR/${phase_file%.md}.cycle-${cycle}.log"

    if [ "$cycle" -eq 1 ]; then
      prompt_file=$(build_impl_prompt "$phase_file" "$cycle")
    else
      prompt_file=$(build_fix_prompt "$phase_file" "$cycle" "$LAST_GATE" "$GATE_CAUSE")
    fi

    sig_before=$(tree_signature)
    run_engine "$prompt_file" "$log_file" impl || rc=$?

    GATE_CAUSE=""

    # Gate 1 is a signal, not a verdict: a phase already implemented makes the
    # engine (correctly) write nothing. Gates 2 and 3 are the ones that decide.
    # The signal also feeds gate 3's auto mode: a session with no writes is
    # exactly the case where independent verification is mandatory.
    local no_change_note="" session_wrote=1
    if ! gate1_session_wrote "$sig_before"; then
      session_wrote=0
      no_change_note="The previous session ended without changing any file. "
      warn "Gate 1 — the session wrote nothing; validating the existing code"
    fi

    if ! gate0_engine_finished "$log_file" "$rc"; then
      LAST_GATE="gate 0 — engine did not finish"
      fail "Gate 0 red"
    elif ! gate2_tests_pass "$LOG_DIR/${phase_file%.md}.test-${cycle}.log"; then
      LAST_GATE="gate 2 — project test suite"
      GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
      fail "Gate 2 red — project tests failed"
    elif ! gate3_independent_verify "$phase_file" "$cycle" "$session_wrote"; then
      LAST_GATE="gate 3 — independent verification"
      GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
      fail "Gate 3 red — incomplete implementation"
    else
      local phase_duration=$(($(date +%s) - phase_start))

      # Green gates and nothing to commit => the phase was already implemented on
      # HEAD (previous run committed, [x] tasks, code written by hand).
      if [ -z "$(git status --porcelain)" ]; then
        success "Phase $phase_num: $phase_title — ALREADY IMPLEMENTED (nothing to commit)"
        if [ "$GATE3_RAN" -eq 1 ]; then
          log "Gates 2 and 3 green against the code on HEAD; no commit created."
        else
          log "Gate 2 green against the code on HEAD; no commit created."
        fi
        mark_phase_done "$phase_file"
        return 0
      fi

      success "Phase $phase_num: $phase_title — COMPLETE ($(format_duration "$phase_duration"))"
      if ! commit_phase "$phase_num" "$phase_title"; then
        LAST_GATE="commit"
        return 1
      fi
      mark_phase_done "$phase_file"
      return 0
    fi

    cycle=$((cycle + 1))
  done

  local phase_duration=$(($(date +%s) - phase_start))
  fail "Phase $phase_num: $phase_title — FAILED after $MAX_CYCLES cycles ($(format_duration "$phase_duration"))"
  fail "Last cause ($LAST_GATE):"
  printf '%s\n' "$GATE_CAUSE" | head -n 20 | sed 's/^/    /'
  fail "Logs at: $LOG_DIR/${phase_file%.md}.*"

  # Partial work stays in the tree; the next run's preflight requires a clean
  # tree. Say what to do instead of letting the dev find out at the abort.
  if [ -n "$(git status --porcelain)" ]; then
    warn "This phase's partial work is left in the tree. Before re-running ralph:"
    warn "    commit it (ralph re-validates the phase and continues) or 'git checkout -- . && git clean -fd' (discard)"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

LAST_GATE=""

main() {
  preflight_checks
  split_phases
  apply_from_override

  local total_phases
  total_phases=$(manifest_entries | wc -l)

  if [ "$total_phases" -eq 0 ]; then
    fail "No phase extracted from $INPUT_FILE."
    exit 1
  fi

  if [ "$FROM_PHASE" -gt "$total_phases" ]; then
    fail "--from $FROM_PHASE exceeds the total number of phases ($total_phases)."
    exit 1
  fi

  echo ""
  log "$total_phases phases to implement (engine: $ENGINE, max-cycles: $MAX_CYCLES)"
  [ "$FROM_PHASE" -gt 1 ] && log "Starting from phase $FROM_PHASE"
  echo ""

  local file num title
  while IFS='|' read -r file num title; do
    if [ "$num" -lt "$FROM_PHASE" ]; then
      echo -e "  ${BLUE}[$num] $title (skipped via --from)${NC}"
    elif is_phase_done "$file"; then
      echo -e "  ${GREEN}[$num] $title (already completed)${NC}"
    else
      echo -e "  ${YELLOW}[$num] $title${NC}"
    fi
  done < <(manifest_entries)

  local start_time
  start_time=$(date +%s)
  echo ""
  log "Start: $(date '+%d/%m/%Y %H:%M:%S')"

  local seq=0
  local failed_phases=() skipped_phases=() completed_phases=()

  # fd 3, never stdin: commands in the body (claude -p, sail test / docker compose
  # exec) read stdin when it's not a TTY and would swallow the rest of the
  # manifest — the run would stop after the first phase.
  while IFS='|' read -r -u 3 file num title; do
    seq=$((seq + 1))

    if [ "$num" -lt "$FROM_PHASE" ]; then
      log "Skipping Phase $num: $title (before --from $FROM_PHASE)"
      skipped_phases+=("$title")
      continue
    fi

    if is_phase_done "$file"; then
      log "Skipping Phase $num: $title (already completed)"
      skipped_phases+=("$title")
      continue
    fi

    if run_phase "$file" "$num" "$title" "$seq" "$total_phases"; then
      completed_phases+=("$title")
    else
      failed_phases+=("$title")
      if $KEEP_GOING; then
        warn "--keep-going: continuing to the next phase"
        commit_wip "$num"
      else
        warn "Stopping at the first phase that failed (use --keep-going to continue)"
        break
      fi
    fi
  done 3< <(manifest_entries)

  local end_time total_duration
  end_time=$(date +%s)
  total_duration=$((end_time - start_time))

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "FINAL REPORT (engine: $ENGINE)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local phase
  if [ ${#completed_phases[@]} -gt 0 ]; then
    echo ""
    success "Completed (${#completed_phases[@]}):"
    for phase in "${completed_phases[@]}"; do printf '    %b%s%b\n' "$GREEN" "$phase" "$NC"; done
  fi

  if [ ${#skipped_phases[@]} -gt 0 ]; then
    echo ""
    log "Skipped (${#skipped_phases[@]}):"
    for phase in "${skipped_phases[@]}"; do printf '    %s\n' "$phase"; done
  fi

  if [ ${#failed_phases[@]} -gt 0 ]; then
    echo ""
    fail "Failed (${#failed_phases[@]}):"
    for phase in "${failed_phases[@]}"; do printf '    %b%s%b\n' "$RED" "$phase" "$NC"; done
    echo ""
    fail "Check the logs at $LOG_DIR/"
  fi

  echo ""
  log "Start: $(date -d "@$start_time" '+%d/%m/%Y %H:%M:%S')"
  log "End:   $(date -d "@$end_time" '+%d/%m/%Y %H:%M:%S')"
  log "Total duration: $(format_duration "$total_duration")"
  echo ""

  [ ${#failed_phases[@]} -eq 0 ] || exit 1
}

main
