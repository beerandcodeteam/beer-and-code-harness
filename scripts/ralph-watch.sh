#!/usr/bin/env bash
#
# ralph-watch.sh
#
# Live monitoring panel for ralph.sh.
#
# Reads the state ralph publishes in .phases/state/ and redraws the panel.
# Runs nothing and writes no state: it is a pure reader. It can run in a
# second terminal while ralph works, or be embedded by ralph itself via
# `ralph.sh --dashboard`.
#
# Usage:
#   ./ralph-watch.sh [options] [repo-path]
#
# Options:
#   --once              draw one frame and exit (useful in scripts/tests)
#   --interval N        seconds between frames (default: 1)
#   --embedded          mode used by ralph: does not switch the alternate
#                       screen (the caller already did) and exits with the run
#   --no-color          turns ANSI off
#   --color             forces ANSI even without a terminal (tests)
#
# Layout: the top (identification, bars, current work) is pinned; the table of
# phases and tasks scrolls inside a window that fits the terminal height.
# Without that, a plan with dozens of tasks pushed the header off the alternate
# screen — where the terminal's own scrollback cannot reach.
#
# Keys (when /dev/tty exists, including when embedded in ralph):
#   ↑/↓ or k/j     scroll one line       PgUp/PgDn or b/space   scroll a page
#   Home/g         first line            End/G                  last line
#   f              resume following the current phase (automatic mode)
#   q              leave the panel (does not interrupt ralph)
#
# Environment variables:
#   RALPH_WATCH_COLS   pins the width (tests, pipes, terminals that don't report)
#   RALPH_WATCH_LINES  pins the height; with --once it also enables the window
#
# State contract (written by ralph, TSV, one writer per file):
#
#   .phases/state/run.tsv      writer: ralph's main process
#     META<TAB>key<TAB>value
#     PHASE<TAB>num<TAB>status<TAB>attempt<TAB>"g0 g1 g2 g3"<TAB>title
#     TASK<TAB>phase<TAB>index<TAB>status<TAB>title
#
#   .phases/state/live.tsv     writer: stream watcher of the current session
#     PHASE<TAB>num
#     ACTIVITY<TAB>text
#     LIVE<TAB>index<TAB>status
#
# Two files with one writer each avoid a race between the main loop and the
# stream watcher, which runs in a subprocess. The merge happens here, on read:
# live.tsv takes precedence over run.tsv for the current phase's tasks.
#
# Status vocabulary:
#   phase pending | running | done | failed | skipped
#   task  pending | running | done | incomplete
#   gate  pending | run | pass | fail | skip

set -uo pipefail

REPO="."
ONCE=false
EMBEDDED=false
INTERVAL=1
USE_COLOR=true
FORCE_COLOR=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)       ONCE=true; shift ;;
    --embedded)   EMBEDDED=true; shift ;;
    --interval)   INTERVAL="$2"; shift 2 ;;
    --interval=*) INTERVAL="${1#*=}"; shift ;;
    --no-color)   USE_COLOR=false; shift ;;
    --color)      FORCE_COLOR=true; shift ;;
    -h|--help)    sed -n '2,56p' "$0"; exit 0 ;;
    *)            REPO="$1"; shift ;;
  esac
done

# --color keeps ANSI when the output is not a terminal (tests, files).
$FORCE_COLOR || [ -t 1 ] || USE_COLOR=false

STATE_DIR="$REPO/.phases/state"
RUN_STATE="$STATE_DIR/run.tsv"
LIVE_STATE="$STATE_DIR/live.tsv"

# ---------------------------------------------------------------------------
# Cores
# ---------------------------------------------------------------------------

if $USE_COLOR; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_CYAN=$'\033[38;5;81m'; C_GREEN=$'\033[38;5;77m'; C_YELLOW=$'\033[38;5;221m'
  C_RED=$'\033[38;5;203m'; C_GREY=$'\033[38;5;245m'; C_WHITE=$'\033[38;5;255m'
  C_HILITE=$'\033[48;5;53m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""; C_WHITE=""
  C_HILITE=""
fi

# ---------------------------------------------------------------------------
# State that was read
# ---------------------------------------------------------------------------

declare -A META PH_STATUS PH_ATTEMPT PH_GATES PH_TITLE
declare -A TK_STATUS TK_TITLE TK_COUNT
declare -a PHASE_NUMS
LIVE_PHASE=""

reset_state() {
  META=(); PH_STATUS=(); PH_ATTEMPT=(); PH_GATES=(); PH_TITLE=()
  TK_STATUS=(); TK_TITLE=(); TK_COUNT=()
  PHASE_NUMS=()
  LIVE_PHASE=""
}

read_state() {
  reset_state
  [ -f "$RUN_STATE" ] || return 1

  local kind a b c d e
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      META)  META[$a]="$b" ;;
      PHASE)
        PHASE_NUMS+=("$a")
        PH_STATUS[$a]="$b"; PH_ATTEMPT[$a]="$c"; PH_GATES[$a]="$d"; PH_TITLE[$a]="$e"
        TK_COUNT[$a]="${TK_COUNT[$a]:-0}"
        ;;
      TASK)
        TK_STATUS[$a:$b]="$c"; TK_TITLE[$a:$b]="$d"
        TK_COUNT[$a]="$b"
        ;;
    esac
  done < "$RUN_STATE"

  # live.tsv wins for the current phase: it is what the session is doing now.
  if [ -f "$LIVE_STATE" ]; then
    while IFS=$'\t' read -r kind a b c; do
      case "$kind" in
        PHASE)    LIVE_PHASE="$a" ;;
        ACTIVITY) [ -n "$a" ] && META[activity]="$a" ;;
        LIVE)
          if [ -n "$LIVE_PHASE" ] && [ -n "${TK_STATUS[$LIVE_PHASE:$a]+x}" ]; then
            # do not demote a task already confirmed by the verifier (gate 3)
            case "${TK_STATUS[$LIVE_PHASE:$a]}" in
              done|incomplete) ;;
              *) TK_STATUS[$LIVE_PHASE:$a]="$b" ;;
            esac
          fi
          ;;
      esac
    done < "$LIVE_STATE"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Drawing primitives
# ---------------------------------------------------------------------------

# The *_v functions write their result into the variable named in $1 instead of
# to stdout: `printf -v` opens no subshell, and that is what makes it possible to
# build a table row without the ~15 forks `$(pad ...)` used to cost. build_rows
# rebuilds EVERY row on each frame, so there the difference is ~500ms versus a
# few ms per frame — and the frame is redrawn on every scroll keypress too.
#
# Every internal variable here carries a __ prefix: the destination comes from
# the caller, and a `pad_v out ...` with a `local out` in here would write to
# this function's local instead of the caller's — a silent failure, with the
# output coming out empty.

# pad_v <dest> <text> <width> — the pad, writing into a variable.
pad_v() {
  local __s="$2" __w="$3" __n
  __n=${#2}
  if [ "$__n" -gt "$__w" ]; then
    if [ "$__w" -gt 1 ]; then __s="${__s:0:__w-1}…"; else __s="${__s:0:__w}"; fi
    __n=$__w
  fi
  printf -v "$1" '%s%*s' "$__s" $((__w - __n)) ''
}

# pad <text> <width> — truncates with an ellipsis or pads with spaces.
# In a UTF-8 locale ${#s} counts characters, not bytes: that is what keeps the
# columns aligned with accents and box-drawing characters.
pad() {
  local REPLY_PAD
  pad_v REPLY_PAD "$1" "$2"
  printf '%s' "$REPLY_PAD"
}

# cell_v <dest> <coloured> <plain> <width> — a coloured cell with correct
# padding: measures the text WITHOUT ANSI (plain) and fills the difference.
# Colouring after padding would inflate the visible width, because ANSI counts
# in ${#s}.
cell_v() {
  local __n=${#3}
  if [ "$__n" -gt "$4" ]; then pad_v "$1" "$3" "$4"; return; fi
  printf -v "$1" '%s%*s' "$2" $(( $4 - __n )) ''
}

repeat_v() { local __ch="$2" __n="$3" __out="" __i; for ((__i=0; __i<__n; __i++)); do __out+="$__ch"; done; printf -v "$1" '%s' "$__out"; }

bar_v() { # <dest> <done> <total> <width>
  local __done="$2" __total="$3" __width="$4"
  local __filled=0 __f __e
  [ "$__total" -gt 0 ] && __filled=$(( __done * __width / __total ))
  [ "$__filled" -gt "$__width" ] && __filled=$__width
  repeat_v __f '█' "$__filled"
  repeat_v __e '░' $(( __width - __filled ))
  printf -v "$1" '%s%s%s%s%s' "$C_GREEN" "$__f" "$C_GREY" "$__e" "$C_RESET"
}

pct_v() { # <dest> <n> <total>
  if [ "$3" -gt 0 ]; then printf -v "$1" '%d%%' $(( $2 * 100 / $3 ))
  else printf -v "$1" '0%%'; fi
}

fmt_duration() {
  local t="$1" h m s
  h=$((t / 3600)); m=$(((t % 3600) / 60)); s=$((t % 60))
  if [ "$h" -gt 0 ]; then printf '%dh %02dm %02ds' "$h" "$m" "$s"
  elif [ "$m" -gt 0 ]; then printf '%dm %02ds' "$m" "$s"
  else printf '%ds' "$s"; fi
}

# ---------------------------------------------------------------------------
# Vocabulary -> coloured label
# ---------------------------------------------------------------------------

status_label() {
  case "$1" in
    done)       printf '%s✓ Done%s'   "$C_GREEN"  "$C_RESET" ;;
    running)    printf '%s▶ Running%s' "$C_YELLOW" "$C_RESET" ;;
    failed)     printf '%s✗ Failed%s'      "$C_RED"    "$C_RESET" ;;
    incomplete) printf '%s! Incomplete%s'  "$C_RED"    "$C_RESET" ;;
    skipped)    printf '%s– Skipped%s'      "$C_GREY"   "$C_RESET" ;;
    *)          printf '%s· Pending%s'    "$C_GREY"   "$C_RESET" ;;
  esac
}

status_plain() {
  case "$1" in
    done)       printf '✓ Done' ;;
    running)    printf '▶ Running' ;;
    failed)     printf '✗ Failed' ;;
    incomplete) printf '! Incomplete' ;;
    skipped)    printf '– Skipped' ;;
    *)          printf '· Pending' ;;
  esac
}

gate_mark() {
  case "$1" in
    pass) printf '%s✓%s' "$C_GREEN"  "$C_RESET" ;;
    fail) printf '%s✗%s' "$C_RED"    "$C_RESET" ;;
    run)  printf '%s⋯%s' "$C_YELLOW" "$C_RESET" ;;
    skip) printf '%s⊘%s' "$C_GREY"   "$C_RESET" ;;
    *)    printf '%s·%s' "$C_GREY"   "$C_RESET" ;;
  esac
}

gate_mark_plain() {
  case "$1" in
    pass) printf '✓' ;; fail) printf '✗' ;; run) printf '⋯' ;;
    skip) printf '⊘' ;; *) printf '·' ;;
  esac
}

# Memoized labels. The vocabulary is closed (6 statuses, 5 gate marks), and the
# functions above remain the single source of truth: the table is derived from
# them once at startup, so changing a label is still a one-place edit. Row
# building reads from the table and pays no fork at all.
declare -A ST_LABEL ST_PLAIN GM_LABEL GM_PLAIN
init_labels() {
  local s
  for s in done running failed incomplete skipped pending; do
    ST_LABEL[$s]=$(status_label "$s")
    ST_PLAIN[$s]=$(status_plain "$s")
  done
  for s in pass fail run skip pending; do
    GM_LABEL[$s]=$(gate_mark "$s")
    GM_PLAIN[$s]=$(gate_mark_plain "$s")
  done
}
init_labels

# gates_cell_v <dest> <spec> <coloured:0|1> — gates_cell without a subshell.
gates_cell_v() {
  # direct splitting instead of `read -r -a`: the spec comes from the closed
  # gate vocabulary (pending|run|pass|fail|skip), with no spaces and no glob
  # metacharacters.
  # shellcheck disable=SC2206
  local -a __g=( $2 )
  local __i __out="" __st
  for __i in 0 1 2 3; do
    [ "$__i" -gt 0 ] && __out+=" "
    __st="${__g[$__i]:-pending}"
    if [ "$3" = "1" ]; then
      __out+="${C_GREY}G$__i${C_RESET} ${GM_LABEL[$__st]:-${GM_LABEL[pending]}}"
    else
      __out+="G$__i ${GM_PLAIN[$__st]:-${GM_PLAIN[pending]}}"
    fi
  done
  printf -v "$1" '%s' "$__out"
}

# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

W=100
H=24

# State of the table's scrolling window. FOLLOW=true lets the panel pick the
# slice on its own (it follows the current phase); any scroll key hands control
# to the user until they press `f`.
OFF=0
FOLLOW=true
QUIT=false
VIS=0
TOTAL=0
MAX_OFF=0
FOOTER=0
HEAD=""
LAST_W=0
LAST_H=0
RESIZED=false

# RALPH_WATCH_COLS pins the width (tests, pipes, terminals that don't report).
#
# `tput cols` alone is not enough: with --embedded the panel runs in the
# background (`&`) from ralph, and there tput may not see the terminal — the
# panel fell back to the minimum width and truncated titles on a wide terminal.
# /dev/tty answers even in the background, so it serves as a second source.
calc_width() {
  local cols="${RALPH_WATCH_COLS:-}"

  # stty FIRST: it reads the terminal's real size via ioctl. `tput cols` looks
  # like it works but returns terminfo's 80 when it cannot determine the size —
  # and 80 is a plausible number, so it slipped through unnoticed and the panel
  # ended up half the width on a wide terminal.
  if ! [[ "$cols" =~ ^[0-9]+$ ]]; then
    cols=$(stty size 2>/dev/null < /dev/tty | cut -d' ' -f2 || true)
  fi
  if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -lt 40 ]; then
    cols=$(tput cols 2>/dev/null || true)
  fi
  if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -lt 40 ]; then
    cols="${COLUMNS:-}"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=100

  # No artificial ceiling: the panel follows the terminal. calc_width runs on
  # every frame, so resizing the window shows up in the next draw.
  W=$cols
  [ "$W" -lt 64 ] && W=64
}

# Same ladder as calc_width, for the same reasons: stty reads the real size via
# ioctl and answers even with the panel in the background; tput falls back to
# terminfo's 24 when it does not know.
calc_height() {
  local lines="${RALPH_WATCH_LINES:-}"

  if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
    lines=$(stty size 2>/dev/null < /dev/tty | cut -d' ' -f1 || true)
  fi
  if ! [[ "$lines" =~ ^[0-9]+$ ]] || [ "$lines" -lt 10 ]; then
    lines=$(tput lines 2>/dev/null || true)
  fi
  if ! [[ "$lines" =~ ^[0-9]+$ ]] || [ "$lines" -lt 10 ]; then
    lines="${LINES:-}"
  fi
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24

  H=$lines
  [ "$H" -lt 12 ] && H=12
}

# The _v versions carry no trailing \n: building the two boxes side by side
# needs the borders as text, not as a printed line.
box_top_v() { # <dest> <width> <title>
  local __w="$2" __title="$3" __pre __l __r
  __pre=$(( (__w - ${#__title} - 2) / 2 ))
  repeat_v __l '─' "$__pre"
  repeat_v __r '─' $(( __w - __pre - ${#__title} - 2 ))
  printf -v "$1" '%s┌%s %s %s┐%s' "$C_CYAN" "$__l" "$__title" "$__r" "$C_RESET"
}

box_bottom_v() { # <dest> <width>
  local __b
  repeat_v __b '─' "$2"
  printf -v "$1" '%s└%s┘%s' "$C_CYAN" "$__b" "$C_RESET"
}

phase_counts() {
  local num
  PH_DONE=0; PH_TOTAL=0
  for num in "${PHASE_NUMS[@]}"; do
    PH_TOTAL=$((PH_TOTAL + 1))
    case "${PH_STATUS[$num]}" in done|skipped) PH_DONE=$((PH_DONE + 1)) ;; esac
  done
}

# Every task in the run, not only the current phase's: the bar measures the
# progress of the whole job, the same way the phase bar does.
task_counts() {
  local num i
  TK_DONE=0; TK_TOTAL=0
  for num in "${PHASE_NUMS[@]}"; do
    for ((i=1; i<=${TK_COUNT[$num]:-0}; i++)); do
      TK_TOTAL=$((TK_TOTAL + 1))
      [ "${TK_STATUS[$num:$i]:-pending}" = "done" ] && TK_DONE=$((TK_DONE + 1))
    done
  done
}

run_status_label() {
  case "${META[status]:-running}" in
    running)  printf '%s▶ Running%s' "$C_YELLOW" "$C_RESET" ;;
    waiting)  printf '%s⏸ Waiting for limit reset%s' "$C_YELLOW" "$C_RESET" ;;
    finished) printf '%s✓ Finished%s' "$C_GREEN" "$C_RESET" ;;
    failed)   printf '%s✗ Failed%s' "$C_RED" "$C_RESET" ;;
    *)        printf '%s· %s%s' "$C_GREY" "${META[status]:-?}" "$C_RESET" ;;
  esac
}

run_status_plain() {
  case "${META[status]:-running}" in
    running)  printf '▶ Running' ;;
    waiting)  printf '⏸ Waiting for limit reset' ;;
    finished) printf '✓ Finished' ;;
    failed)   printf '✗ Failed' ;;
    *)        printf '· %s' "${META[status]:-?}" ;;
  esac
}

draw_header() {
  local now elapsed
  now=$(date +%s)
  elapsed=$(( now - ${META[started]:-$now} ))
  [ "${META[status]:-running}" != "running" ] && [ -n "${META[ended]:-}" ] \
    && elapsed=$(( ${META[ended]} - ${META[started]:-$now} ))

  printf '\n%s%sRALPH%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET"

  local col=$(( (W - 4) / 3 ))
  printf '%sProject:%s %s  %sEngine:%s %s  %sStatus:%s %s\n' \
    "$C_CYAN" "$C_RESET" "$(pad "${META[project]:-?}" $((col - 10)))" \
    "$C_CYAN" "$C_RESET" "$(pad "${META[engine]:-?}" $((col - 9)))" \
    "$C_CYAN" "$C_RESET" "$(run_status_label)"
  printf '%sDuration:%s %s  %sRun:%s %s  %sPID:%s %s\n\n' \
    "$C_CYAN" "$C_RESET" "$(pad "$(fmt_duration "$elapsed")" $((col - 11)))" \
    "$C_CYAN" "$C_RESET" "$(pad "${META[run]:-?}" $((col - 6)))" \
    "$C_CYAN" "$C_RESET" "${META[pid]:-?}"
}

draw_panels() {
  phase_counts
  task_counts

  local lw=$(( (W - 1) / 2 )) rw
  rw=$(( W - lw - 2 ))
  local li=$(( lw - 2 )) ri=$(( rw - 2 ))

  local -a L=() R=() LP=() RP=()
  local bw=$(( li - 26 ))
  [ "$bw" -lt 8 ] && bw=8

  local l1 l2 p_ph p_tk n_ph n_tk b_ph b_tk blank tmp
  pad_v n_ph "$PH_DONE/$PH_TOTAL" 7
  pad_v n_tk "$TK_DONE/$TK_TOTAL" 7
  pct_v p_ph "$PH_DONE" "$PH_TOTAL"
  pct_v p_tk "$TK_DONE" "$TK_TOTAL"
  bar_v b_ph "$PH_DONE" "$PH_TOTAL" "$bw"
  bar_v b_tk "$TK_DONE" "$TK_TOTAL" "$bw"
  repeat_v blank ' ' "$bw"

  printf -v l1 'Phases %s  [%s]  %s' "$n_ph" "$b_ph" "$p_ph"
  printf -v l2 'Tasks  %s  [%s]  %s' "$n_tk" "$b_tk" "$p_tk"
  L+=("$l1"); printf -v tmp 'Phases %s  [%s]  %s' "$n_ph" "$blank" "$p_ph"; LP+=("$tmp")
  L+=("$l2"); printf -v tmp 'Tasks  %s  [%s]  %s' "$n_tk" "$blank" "$p_tk"; LP+=("$tmp")
  L+=(""); LP+=("")
  printf -v tmp '%sTest:%s %s' "$C_GREY" "$C_RESET" "${META[test_cmd]:-—}"; L+=("$tmp")
  printf -v tmp 'Test: %s' "${META[test_cmd]:-—}"; LP+=("$tmp")

  local cur="${META[phase_cur]:-}"
  local phase_txt="—"
  [ -n "$cur" ] && phase_txt="$cur · ${PH_TITLE[$cur]:-}"

  local cyc="${META[cycle]:-—}/${META[cycle_max]:-—}"
  printf -v tmp '%sPhase:%s     %s' "$C_CYAN" "$C_RESET" "$phase_txt"; R+=("$tmp")
  printf -v tmp 'Phase:     %s' "$phase_txt"; RP+=("$tmp")
  printf -v tmp '%sCycle:%s     %s    %sGate:%s %s' \
    "$C_CYAN" "$C_RESET" "$cyc" "$C_CYAN" "$C_RESET" "${META[gate]:-—}"; R+=("$tmp")
  printf -v tmp 'Cycle:     %s    Gate: %s' "$cyc" "${META[gate]:-—}"; RP+=("$tmp")
  printf -v tmp '%sActivity:%s  %s' "$C_CYAN" "$C_RESET" "${META[activity]:-—}"; R+=("$tmp")
  printf -v tmp 'Activity:  %s' "${META[activity]:-—}"; RP+=("$tmp")
  printf -v tmp '%sLast error:%s %s%s%s' \
    "$C_CYAN" "$C_RESET" "$C_RED" "${META[last_error]:-—}" "$C_RESET"; R+=("$tmp")
  printf -v tmp 'Last error: %s' "${META[last_error]:-—}"; RP+=("$tmp")

  # Headers and footers of the two boxes, side by side
  local top_l top_r bot_l bot_r
  box_top_v top_l "$li" "PROGRESS"; box_top_v top_r "$ri" "CURRENT WORK"
  box_bottom_v bot_l "$li";          box_bottom_v bot_r "$ri"
  printf '%s %s\n' "$top_l" "$top_r"

  local i n=${#L[@]}
  [ "${#R[@]}" -gt "$n" ] && n=${#R[@]}
  for ((i=0; i<n; i++)); do
    local lc="${L[$i]:-}" lp="${LP[$i]:-}" rc="${R[$i]:-}" rp="${RP[$i]:-}"
    # truncate by the uncoloured text and reapply the coloured content
    if [ "${#lp}" -gt $(( li - 2 )) ]; then pad_v lc "$lp" $(( li - 2 )); lp="$lc"; fi
    if [ "${#rp}" -gt $(( ri - 2 )) ]; then pad_v rc "$rp" $(( ri - 2 )); rp="$rc"; fi
    printf '%s│%s %s%*s %s│%s %s│%s %s%*s %s│%s\n' \
      "$C_CYAN" "$C_RESET" "$lc" $(( li - 2 - ${#lp} )) '' "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$rc" $(( ri - 2 - ${#rp} )) '' "$C_CYAN" "$C_RESET"
  done
  printf '%s %s\n' "$bot_l" "$bot_r"
}

# Table rows are built once per frame, before the visible slice is known:
# scrolling picks the range, it does not rebuild the content.
declare -a ROWS ROW_HL
declare -A PHASE_ROW PHASE_END
RUN_ROW=-1

build_rows() {
  ROWS=(); ROW_HL=(); PHASE_ROW=(); PHASE_END=(); RUN_ROW=-1

  # c_gates=19 fits "G0 ✓ G1 ✓ G2 ✓ G3 ✓" whole; c_status=14 fits the longest
  # label ("! Incomplete"). Shrinking either one truncates information.
  COL_ID=4; COL_STATUS=14; COL_TRY=9; COL_GATES=19
  COL_NAME=$(( W - COL_ID - COL_STATUS - COL_TRY - COL_GATES - 16 ))
  [ "$COL_NAME" -lt 16 ] && COL_NAME=16

  local V="${C_CYAN}│${C_RESET}"

  # The attempt and gate dashes on task rows do not depend on the phase: pad
  # them once per frame instead of once per row.
  local dash_try dash_gates c_try_tk c_gates_tk
  pad_v dash_try   '–' "$COL_TRY"
  pad_v dash_gates '–' "$COL_GATES"
  cell_v c_try_tk   "${C_GREY}${dash_try}${C_RESET}"   "$dash_try"   "$COL_TRY"
  cell_v c_gates_tk "${C_GREY}${dash_gates}${C_RESET}" "$dash_gates" "$COL_GATES"

  local num i st tries row
  local t_name c_name c_id c_st c_try g_col g_pln c_gates
  for num in "${PHASE_NUMS[@]}"; do
    st="${PH_STATUS[$num]}"
    tries="${PH_ATTEMPT[$num]}"
    [ "$tries" = "0" ] && tries="–"

    PHASE_ROW[$num]=${#ROWS[@]}

    pad_v t_name "${PH_TITLE[$num]}" "$COL_NAME"
    cell_v c_name "${C_WHITE}${t_name}${C_RESET}" "$t_name" "$COL_NAME"
    cell_v c_st "${ST_LABEL[$st]:-${ST_LABEL[pending]}}" \
                "${ST_PLAIN[$st]:-${ST_PLAIN[pending]}}" "$COL_STATUS"
    pad_v c_id "F$num" "$COL_ID"
    pad_v c_try "$tries" "$COL_TRY"
    gates_cell_v g_col "${PH_GATES[$num]}" 1
    gates_cell_v g_pln "${PH_GATES[$num]}" 0
    cell_v c_gates "$g_col" "$g_pln" "$COL_GATES"

    # the row holds everything but the right border: the scrollbar goes there
    printf -v row '%s %s %s %s %s %s %s %s %s %s' "$V" \
      "$c_id" "$V" "$c_name" "$V" "$c_st" "$V" "$c_try" "$V" "$c_gates"
    ROWS+=("$row")
    if [ "$st" = "running" ]; then
      ROW_HL+=("$C_HILITE")
      [ "$RUN_ROW" -lt 0 ] && RUN_ROW=$(( ${#ROWS[@]} - 1 ))
    else
      ROW_HL+=("")
    fi

    local tst ttitle t_id
    for ((i=1; i<=${TK_COUNT[$num]:-0}; i++)); do
      tst="${TK_STATUS[$num:$i]:-pending}"
      pad_v ttitle "  ↳ ${TK_TITLE[$num:$i]}" "$COL_NAME"
      pad_v t_id "T$i" "$COL_ID"
      cell_v c_id "${C_GREY}${t_id}${C_RESET}" "$t_id" "$COL_ID"
      cell_v c_st "${ST_LABEL[$tst]:-${ST_LABEL[pending]}}" \
                  "${ST_PLAIN[$tst]:-${ST_PLAIN[pending]}}" "$COL_STATUS"
      printf -v row '%s %s %s %s %s %s %s %s %s %s' "$V" \
        "$c_id" "$V" "$ttitle" "$V" "$c_st" "$V" "$c_try_tk" "$V" "$c_gates_tk"
      ROWS+=("$row")
      if [ "$tst" = "running" ]; then
        ROW_HL+=("$C_HILITE")
        # the running task is the preferred anchor: it is what the user wants to see
        RUN_ROW=$(( ${#ROWS[@]} - 1 ))
      else
        ROW_HL+=("")
      fi
    done
    PHASE_END[$num]=$(( ${#ROWS[@]} - 1 ))
  done
}

clamp_off() {
  [ "$OFF" -gt "$MAX_OFF" ] && OFF=$MAX_OFF
  [ "$OFF" -lt 0 ] && OFF=0
}

# Automatic slice: shows the current phase's block whole when it fits; when it
# does not fit, it centres the running task.
follow_offset() {
  local cur="${META[phase_cur]:-}"
  if [ -z "$cur" ] || [ -z "${PHASE_ROW[$cur]:-}" ]; then
    # no current phase (a finished run, say): keep the start in view
    OFF=0
    [ "${META[status]:-running}" = "failed" ] && [ "$RUN_ROW" -ge 0 ] \
      && OFF=$(( RUN_ROW - VIS / 2 ))
    clamp_off
    return
  fi
  local s="${PHASE_ROW[$cur]}" e="${PHASE_END[$cur]}"
  if [ $(( e - s + 1 )) -le "$VIS" ]; then
    OFF=$(( s - 1 ))   # one line of context above the phase
  elif [ "$RUN_ROW" -ge "$s" ] && [ "$RUN_ROW" -le "$e" ]; then
    OFF=$(( RUN_ROW - VIS / 2 ))
  else
    OFF=$s
  fi
  clamp_off
}

# Sets HEAD, VIS, TOTAL, MAX_OFF, FOOTER and OFF for the frame. Runs in the main
# shell (not a subshell) because the keys need the VIS and MAX_OFF computed here
# in order to page.
build_frame() {
  calc_width
  calc_height
  build_rows

  HEAD=$(draw_header; draw_panels)
  TOTAL=${#ROWS[@]}

  local head_n note_n=0 avail
  # `| wc -l` costs a fork, but counting in pure bash costs MORE: the
  # ${HEAD//[^$'\n']/} substitution evaluates the class character by character
  # and measured 44ms against wc's 2ms on a 2KB HEAD. Forks are not always the
  # villain.
  head_n=$(printf '%s\n' "$HEAD" | wc -l)
  [ -n "${META[note]:-}" ] && note_n=2

  # 4 = table top, column header, separator and footer.
  # 1 = slack for the last line, which the terminal would use to scroll the frame.
  avail=$(( H - head_n - 4 - note_n - 1 ))
  [ "$avail" -lt 3 ] && avail=3

  # --once is a dump: only slice if the height was pinned on purpose.
  if { $ONCE && [ -z "${RALPH_WATCH_LINES:-}" ]; } || [ "$TOTAL" -le "$avail" ]; then
    VIS=$TOTAL; MAX_OFF=0; FOOTER=0; OFF=0
    return
  fi

  FOOTER=1
  VIS=$(( avail - 1 ))
  [ "$VIS" -lt 3 ] && VIS=3
  [ "$VIS" -gt "$TOTAL" ] && VIS=$TOTAL
  MAX_OFF=$(( TOTAL - VIS ))
  if $FOLLOW; then follow_offset; else clamp_off; fi
}

# Right border of visible row i: becomes the scrollbar when content is cut off.
# Called once per drawn row, so the _v version (no subshell) matters: it used to
# be one fork per table row, on every frame and every scroll keypress.
scroll_edge_v() { # <dest> <row index>
  local __i="$2"
  if [ "$FOOTER" -eq 0 ]; then
    printf -v "$1" '%s│%s' "$C_CYAN" "$C_RESET"
    return
  fi
  local __th __top __rel
  __th=$(( VIS * VIS / TOTAL )); [ "$__th" -lt 1 ] && __th=1
  __top=0
  [ "$MAX_OFF" -gt 0 ] && __top=$(( OFF * (VIS - __th) / MAX_OFF ))
  __rel=$(( __i - OFF ))
  if [ "$__rel" -ge "$__top" ] && [ "$__rel" -lt $(( __top + __th )) ]; then
    printf -v "$1" '%s█%s' "$C_CYAN" "$C_RESET"
  else
    printf -v "$1" '%s│%s' "$C_GREY" "$C_RESET"
  fi
}

draw_table() {
  local r_id r_name r_status r_try r_gates
  repeat_v r_id     '─' $((COL_ID+2))
  repeat_v r_name   '─' $((COL_NAME+2))
  repeat_v r_status '─' $((COL_STATUS+2))
  repeat_v r_try    '─' $((COL_TRY+2))
  repeat_v r_gates  '─' $((COL_GATES+2))

  local sep_t sep_m sep_b
  printf -v sep_t '%s┌%s┬%s┬%s┬%s┬%s┐%s' "$C_CYAN" \
    "$r_id" "$r_name" "$r_status" "$r_try" "$r_gates" "$C_RESET"
  printf -v sep_m '%s├%s┼%s┼%s┼%s┼%s┤%s' "$C_CYAN" \
    "$r_id" "$r_name" "$r_status" "$r_try" "$r_gates" "$C_RESET"
  printf -v sep_b '%s└%s┴%s┴%s┴%s┴%s┘%s' "$C_CYAN" \
    "$r_id" "$r_name" "$r_status" "$r_try" "$r_gates" "$C_RESET"

  local V="${C_CYAN}│${C_RESET}"

  local h_id h_name h_status h_try h_gates
  pad_v h_id     'ID'          "$COL_ID"
  pad_v h_name   'Phase / Task' "$COL_NAME"
  pad_v h_status 'Status'      "$COL_STATUS"
  pad_v h_try    'Attempt'     "$COL_TRY"
  pad_v h_gates  'Gates'       "$COL_GATES"

  printf '%s\n' "$sep_t"
  printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$V" \
    "${C_CYAN}${h_id}${C_RESET}" "$V" \
    "${C_CYAN}${h_name}${C_RESET}" "$V" \
    "${C_CYAN}${h_status}${C_RESET}" "$V" \
    "${C_CYAN}${h_try}${C_RESET}" "$V" \
    "${C_CYAN}${h_gates}${C_RESET}" "$V"
  printf '%s\n' "$sep_m"

  local i hl body edge
  for ((i=OFF; i<OFF+VIS && i<TOTAL; i++)); do
    hl="${ROW_HL[$i]}"
    body="${ROWS[$i]}"
    scroll_edge_v edge "$i"
    if [ -n "$hl" ]; then
      # C_RESET (\033[0m) clears the background too. Without reinjecting the
      # highlight after every reset, the running row's highlight died at the
      # first separator and painted a single character — the useful effect
      # (spotting the live row at a glance) vanished exactly on a full table.
      body="${body//"$C_RESET"/$C_RESET$hl}"
      edge="${edge//"$C_RESET"/$C_RESET$hl}"
    fi
    printf '%s%s %s%s\n' "$hl" "$body" "$edge" "$C_RESET"
  done
  printf '%s\n' "$sep_b"

  [ "$FOOTER" -eq 1 ] && draw_scroll_footer
}

draw_scroll_footer() {
  local above=$OFF below=$(( TOTAL - OFF - VIS )) mode help=""
  if $FOLLOW; then
    mode="following the current phase"
  else
    mode="manual scrolling"
  fi
  if [ -n "${KEY_FD:-}" ]; then
    help=" · ↑↓ PgUp/PgDn scroll · f follows the phase"
    $EMBEDDED || help+=" · q quits"
  fi
  printf '%s  ▲ %d above · ▼ %d below · %s%s%s\n' \
    "$C_GREY" "$above" "$below" "$mode" "$help" "$C_RESET"
}

render() {
  printf '%s\n' "$HEAD"
  draw_table
  if [ -n "${META[note]:-}" ]; then
    printf '\n%s%s%s\n' "$C_YELLOW" "${META[note]}" "$C_RESET"
  fi
}

# clamp_lines <dest> <text> <max> — cuts the text to the first <max> lines, with
# no trailing \n. The drawing safety net: a frame with more lines than the screen
# makes the terminal SCROLL, and from then on \033[H writes into a shifted screen
# — the top of the previous frame is left behind and no \033[K reaches it, only
# the \033[2J of a resize. It really happens on a short terminal: the floor of 3
# table rows keeps the frame at 20 lines even on a 12-line screen. Cutting the
# footer is ugly; scrolling corrupts the whole panel and never recovers.
clamp_lines() {
  local __s="$2" __max="$3" __out="" __n=0
  while [ "$__n" -lt "$__max" ]; do
    case "$__s" in
      *$'\n'*) __out+="${__s%%$'\n'*}"$'\n'; __s="${__s#*$'\n'}" ;;
      *)       __out+="$__s"; __s=""; break ;;
    esac
    __n=$(( __n + 1 ))
  done
  printf -v "$1" '%s' "${__out%$'\n'}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

cleanup() {
  $EMBEDDED || { $ONCE || tput rmcup 2>/dev/null; }
  tput cnorm 2>/dev/null || true
}

# Keyboard via /dev/tty, not stdin: with --embedded the panel is started with
# `&` by ralph, which runs without job control — the child stays in the same
# foreground process group, so reading the terminal is allowed (there is no
# SIGTTIN). ralph already gives `< /dev/null` to the engine and the tests and
# reads the manifest on fd 3, so nobody else competes for these keys.
KEY_FD=""

open_keyboard() {
  $ONCE && return 0
  exec 3< /dev/tty 2>/dev/null && KEY_FD=3
  return 0
}

scroll_by() { # <delta in rows>
  FOLLOW=false
  OFF=$(( OFF + $1 ))
  clamp_off
}

handle_key() { # <char lido>
  local c="$1" seq="" tail=""
  if [ "$c" = $'\033' ]; then
    IFS= read -rsn2 -t 0.05 -u "$KEY_FD" seq || true
    case "$seq" in
      '[A') scroll_by -1 ;;
      '[B') scroll_by 1 ;;
      '[H') FOLLOW=false; OFF=0 ;;
      '[F') FOLLOW=false; OFF=$MAX_OFF ;;
      '[5'|'[6'|'[1'|'[4')
        IFS= read -rsn1 -t 0.05 -u "$KEY_FD" tail || true   # engole o '~'
        case "$seq" in
          '[5') scroll_by -"$VIS" ;;
          '[6') scroll_by "$VIS" ;;
          '[1') FOLLOW=false; OFF=0 ;;
          '[4') FOLLOW=false; OFF=$MAX_OFF ;;
        esac
        ;;
    esac
    return
  fi
  case "$c" in
    k|K)   scroll_by -1 ;;
    j|J)   scroll_by 1 ;;
    b|B)   scroll_by -"$VIS" ;;
    ' ')   scroll_by "$VIS" ;;
    g)     FOLLOW=false; OFF=0 ;;
    G)     FOLLOW=false; OFF=$MAX_OFF ;;
    f|F)   FOLLOW=true ;;
    # embedded in ralph, the panel owns the alternate screen ralph opened:
    # quitting here would leave the screen frozen with the run still going.
    q|Q)   $EMBEDDED || QUIT=true ;;
  esac
}

# Ceiling on keys absorbed in one tick. Holding a key or pasting text can fill
# the buffer; beyond this it draws what has accumulated and comes back on the
# next turn, so the panel does not stop updating while it drains.
DRAIN_MAX=64

# Waits INTERVAL seconds, but wakes immediately if the user presses something —
# that is what makes scrolling respond without waiting for the next frame.
wait_tick() {
  local c rc
  if [ -z "$KEY_FD" ]; then
    sleep "$INTERVAL"
    return
  fi
  IFS= read -rsn1 -t "$INTERVAL" -u "$KEY_FD" c
  rc=$?
  if [ "$rc" -eq 0 ]; then
    handle_key "$c"
    # Drain the rest of the buffer before handing control back to the loop.
    # Without this the terminal's autorepeat queued dozens of events and each
    # one paid for a whole frame: scrolling reached its destination long after
    # the key was released. Absorb everything already pending and let the loop
    # draw ONE frame at the final offset. The short -t is what distinguishes
    # "empty buffer" from "still arriving"; `read -t 0` will not do, because it
    # tests without consuming the byte.
    local drained=0
    while [ "$drained" -lt "$DRAIN_MAX" ] \
      && IFS= read -rsn1 -t 0.01 -u "$KEY_FD" c; do
      handle_key "$c"
      drained=$(( drained + 1 ))
    done
  elif [ "$rc" -le 128 ] && [ ! -t "$KEY_FD" ]; then
    # Not a timeout and the fd is no longer a terminal: the tty is really gone.
    # (A signal — SIGWINCH on resize — also interrupts the read; there the fd is
    # still a tty and the keyboard has to stay up.)
    KEY_FD=""
    exec 3<&- 2>/dev/null || true
  fi
}

main() {
  if ! $ONCE && ! $EMBEDDED; then
    tput smcup 2>/dev/null || true
    trap cleanup EXIT INT TERM
    tput civis 2>/dev/null || true
  elif $EMBEDDED; then
    trap 'tput cnorm 2>/dev/null || true' EXIT INT TERM
    tput civis 2>/dev/null || true
  fi

  if $ONCE; then
    if ! read_state; then
      echo "No state in $RUN_STATE — has ralph run in this repo yet?" >&2
      exit 1
    fi
    build_frame
    render
    exit 0
  fi

  open_keyboard

  # A resize reflows the whole panel: the previous frame's lines, wrapped by
  # the terminal at the old width, are left on screen and scramble the top.
  # \033[H + \033[J only clear from the cursor down — what is above stays. On a
  # size change, clear the whole screen before redrawing.
  trap 'RESIZED=true' WINCH
  local frame
  while true; do
    if read_state; then
      build_frame
      frame=$(render)
      if $RESIZED || [ "$W" != "$LAST_W" ] || [ "$H" != "$LAST_H" ]; then
        printf '\033[2J'
        LAST_W=$W; LAST_H=$H; RESIZED=false
      fi
      # Never print more lines than the screen has: see clamp_lines.
      clamp_lines frame "$frame" "$H"
      # \033[K at the START of each line: \033[J only clears from the end of the
      # frame downwards, so a new line shorter than the old one left its tail on
      # screen, and a new BLANK line erased nothing. The header has three blank
      # lines and "RALPH" is short: those were exactly the four positions where
      # the previous frame showed through under the new one, and the debris sat
      # there until someone resized the window.
      # At the start and not the end of the line: W is the terminal's full width,
      # and a line of exactly W columns leaves the cursor with a pending wrap in
      # the last column — a \033[K there would erase the very character just
      # emitted.
      printf '\033[H%s\033[J' $'\033[K'"${frame//$'\n'/$'\n\033[K'}"
      case "${META[status]:-running}" in
        finished|failed)
          $EMBEDDED && break
          ;;
      esac
    else
      printf '\033[H\033[K%sWaiting for ralph to start (%s)…%s\033[J\n' "$C_GREY" "$RUN_STATE" "$C_RESET"
    fi
    wait_tick
    $QUIT && break
  done
}

# Same convention as ralph.sh: RALPH_LIB_ONLY=1 loads the functions without
# drawing, so the suite can test units (e.g. clamp_lines) without a terminal.
[ "${RALPH_LIB_ONLY:-0}" = "1" ] || main
