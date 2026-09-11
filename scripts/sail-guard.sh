#!/usr/bin/env bash
#
# sail-guard.sh — bc-harness PreToolUse (Bash) hook.
#
# If the current project uses Laravel Sail (vendor/bin/sail present), blocks
# commands that would run PHP/DB on the host — where PHP is usually not
# installed or the database/redis only exists inside the container — and
# hands the agent the equivalent command via Sail. Avoids the loop of
# "php artisan migrate" repeatedly failing with connection refused.
#
# Input:  hook JSON on stdin ({ cwd, tool_input.command, ... }).
# Output: exit 0 = let it through; exit 2 = block (stderr goes to the agent).
# With no JSON parser available (jq/python3), fails open: blocks nothing.

set -u

INPUT="$(cat)"

# --- cheap pre-filter: runs on every Bash call, exits early if nothing suspect
case "$INPUT" in
  *php*|*artisan*|*composer*|*vendor/bin/*|*mysql*|*mariadb*|*psql*|*redis-cli*) ;;
  *) exit 0 ;;
esac

# --- extract cwd and command from the JSON (jq > python3 > fail open)
if command -v jq > /dev/null 2>&1; then
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
elif command -v python3 > /dev/null 2>&1; then
  CWD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("cwd",""))')
  CMD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tool_input",{}).get("command",""))')
else
  exit 0
fi
[ -z "$CMD" ] && exit 0

# --- detect Sail: walk up from cwd to the root looking for vendor/bin/sail
SAIL_ROOT=""
dir="${CWD:-$PWD}"
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
  if [ -f "$dir/vendor/bin/sail" ]; then
    SAIL_ROOT="$dir"
    break
  fi
  dir=$(dirname "$dir")
done
[ -z "$SAIL_ROOT" ] && exit 0

# --- split the command into segments (&&, ||, |, ; and line breaks)
SEGMENTS=$(printf '%s' "$CMD" | tr '\n' ';' | sed 's/&&/;/g; s/||/;/g; s/|/;/g')

OFFENDER=""
SUGGESTION=""
IFS=';' read -ra PARTS <<< "$SEGMENTS"
for part in "${PARTS[@]}"; do
  # trim + strip prefixes that don't change the verdict (sudo, VAR=value)
  seg=$(printf '%s' "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  seg=$(printf '%s' "$seg" | sed -E 's/^(sudo[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  [ -z "$seg" ] && continue

  # already inside Sail or inside docker exec? let it through
  case "$seg" in
    sail\ *|./vendor/bin/sail*|vendor/bin/sail*|*docker\ compose\ exec*|*docker-compose\ exec*|*docker\ exec*) continue ;;
  esac

  rest=""
  case "$seg" in
    php\ artisan\ *)          rest="artisan ${seg#php artisan }" ;;
    php[0-9.]*\ artisan\ *)   rest="artisan ${seg#* artisan }" ;;
    php|php\ *)               rest="php ${seg#php}" ;;
    php[0-9.]*\ *)            rest="php ${seg#* }" ;;
    ./artisan\ *|artisan\ *)  rest="artisan ${seg#*artisan }" ;;
    composer|composer\ *)     rest="composer ${seg#composer}" ;;
    ./vendor/bin/*)           rest="bin ${seg#./vendor/bin/}" ;;
    vendor/bin/*)             rest="bin ${seg#vendor/bin/}" ;;
    mysql|mysql\ *)           rest="mysql" ;;
    mariadb|mariadb\ *)       rest="mariadb" ;;
    psql|psql\ *)             rest="psql" ;;
    redis-cli|redis-cli\ *)   rest="redis" ;;
    *) continue ;;
  esac

  OFFENDER="$seg"
  # normalize double spaces in rest
  SUGGESTION="./vendor/bin/sail $(printf '%s' "$rest" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')"
  break
done

[ -z "$OFFENDER" ] && exit 0

cat >&2 << EOF
BLOCKED by sail-guard: this project uses Laravel Sail ($SAIL_ROOT/vendor/bin/sail exists).
Command "$OFFENDER" would run on the HOST, where PHP/database/redis may not exist — and it will fail (connection refused, php not found).
Use the Sail equivalent instead:
  $SUGGESTION
If the containers are not up, bring them up first with: ./vendor/bin/sail up -d
EOF
exit 2
