#!/usr/bin/env bash
#
# test-sail-guard.sh — suite red/green do hook scripts/sail-guard.sh.
#
# Alimenta o hook com o JSON do PreToolUse (cwd + tool_input.command) e confere
# o veredito pelo exit code: 0 = deixa passar, 2 = bloqueia.
#
# Uso: scripts/test-sail-guard.sh [nome-do-caso]   (exit 0 = tudo verde)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# GUARD_BIN permite apontar para uma copia patchada (prova red dos testes).
GUARD="${GUARD_BIN:-$ROOT/scripts/sail-guard.sh}"
ONLY="${1:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()  { PASS=$((PASS + 1)); echo -e "  ${GREEN}ok${NC}   $1"; }
bad() { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC} $1"; }

case_enabled() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
header() { echo -e "\n${YELLOW}== $1${NC}"; }

# project <nome> [compose] -> ecoa a raiz de um projeto Laravel com o pacote
# laravel/sail instalado; "compose" cria compose.yaml na raiz.
project() {
  local dir="$TMP/$1"
  mkdir -p "$dir/vendor/bin" "$dir/app/Models"
  touch "$dir/artisan"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/vendor/bin/sail"
  chmod +x "$dir/vendor/bin/sail"
  if [ "${2:-}" = "compose" ]; then
    printf 'services: {}\n' > "$dir/compose.yaml"
  fi
  echo "$dir"
}

# guard <cwd> <command> [VAR=valor...] -> ecoa o exit code do hook. O ambiente
# do dev (BC_HARNESS_SAIL, SAIL_FILES, COMPOSE_FILE) e limpo: so vale o do caso.
guard() {
  local cwd="$1" cmd="$2"; shift 2
  local json rc=0
  json=$(jq -n --arg cwd "$cwd" --arg cmd "$cmd" \
    '{cwd: $cwd, tool_name: "Bash", tool_input: {command: $cmd}}')
  printf '%s' "$json" \
    | env -u BC_HARNESS_SAIL -u SAIL_FILES -u COMPOSE_FILE "$@" \
        bash "$GUARD" > /dev/null 2> "$TMP/stderr" || rc=$?
  echo "$rc"
}

expect() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then ok "$msg"; else bad "$msg (esperado exit $expected, veio $actual)"; fi
}

if ! command -v jq > /dev/null 2>&1; then
  echo "jq ausente — a suite monta o JSON do hook com jq (apt install jq)"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Projeto Sail de verdade (pacote + compose) -> bloqueia o host
# ---------------------------------------------------------------------------
if case_enabled sail-real; then
  header "1. Pacote + compose.yaml -> bloqueia php/composer/vendor/bin no host"
  p=$(project sail-real compose)
  expect 2 "$(guard "$p" "php artisan test")" "php artisan test bloqueado"
  expect 2 "$(guard "$p" "composer install")" "composer bloqueado"
  expect 2 "$(guard "$p" "vendor/bin/phpunit")" "vendor/bin/phpunit bloqueado"
  expect 2 "$(guard "$p/app/Models" "php artisan tinker")" "cwd em subpasta: acha a raiz e bloqueia"
  expect 2 "$(guard "$p" "BC_HARNESS_SAIL=off php artisan test")" "variavel no proprio comando nao desliga o guard"
  expect 0 "$(guard "$p" "./vendor/bin/sail artisan test")" "via sail passa"
  expect 0 "$(guard "$p" "ls -la")" "comando sem php passa"
  guard "$p" "php artisan test" > /dev/null
  if grep -qF "./vendor/bin/sail artisan test" "$TMP/stderr"; then ok "sugere o equivalente via sail"
  else bad "sugere o equivalente via sail"; fi
  if grep -qF "BC_HARNESS_SAIL=off" "$TMP/stderr"; then ok "mensagem cita a saida para quem nao usa containers"
  else bad "mensagem cita a saida para quem nao usa containers"; fi
fi

# ---------------------------------------------------------------------------
# 2. Pacote laravel/sail sem compose (esqueleto do Laravel, app no host)
# ---------------------------------------------------------------------------
if case_enabled sail-no-compose; then
  header "2. Pacote sem compose -> nao e Sail, deixa passar"
  p=$(project sail-no-compose)
  expect 0 "$(guard "$p" "php artisan test")" "php artisan test passa"
  expect 0 "$(guard "$p" "vendor/bin/phpunit --exclude-group oracle")" "vendor/bin/phpunit passa"
  expect 0 "$(guard "$p" "composer install")" "composer passa"
fi

# ---------------------------------------------------------------------------
# 3. Demais formas de declarar compose que o sail / docker compose aceitam
# ---------------------------------------------------------------------------
if case_enabled compose-variants; then
  header "3. Variantes de compose -> Sail"
  for f in compose.yml docker-compose.yaml docker-compose.yml; do
    p=$(project "variant-$f")
    printf 'services: {}\n' > "$p/$f"
    expect 2 "$(guard "$p" "php artisan test")" "$f -> bloqueia"
  done

  p=$(project env-sail-files)
  printf 'APP_NAME=x\nSAIL_FILES=docker/compose.dev.yaml\n' > "$p/.env"
  expect 2 "$(guard "$p" "php artisan test")" "SAIL_FILES no .env -> bloqueia"

  p=$(project env-compose-file)
  printf 'export COMPOSE_FILE=docker/compose.yaml\n' > "$p/.env"
  expect 2 "$(guard "$p" "php artisan test")" "export COMPOSE_FILE no .env -> bloqueia"

  p=$(project env-commented)
  printf '# SAIL_FILES=docker/compose.dev.yaml\nCOMPOSE_FILE=\nSAIL_FILES= # vazio\n' > "$p/.env"
  expect 0 "$(guard "$p" "php artisan test")" "comentado/vazio no .env nao conta"

  p=$(project env-quoted)
  printf 'SAIL_FILES="docker/compose.dev.yaml"\n' > "$p/.env"
  expect 2 "$(guard "$p" "php artisan test")" "SAIL_FILES entre aspas -> bloqueia"

  p=$(project env-quoted-empty)
  printf 'SAIL_FILES=""\nCOMPOSE_FILE='"''"'\n' > "$p/.env"
  expect 0 "$(guard "$p" "php artisan test")" "aspas vazias no .env nao contam"

  p=$(project env-process)
  expect 2 "$(guard "$p" "php artisan test" SAIL_FILES=docker/compose.yaml)" "SAIL_FILES no ambiente -> bloqueia"
fi

# ---------------------------------------------------------------------------
# 4. BC_HARNESS_SAIL sobrepoe a deteccao
# ---------------------------------------------------------------------------
if case_enabled sail-mode; then
  header "4. BC_HARNESS_SAIL=off/on/invalido"
  p=$(project mode-off compose)
  expect 0 "$(guard "$p" "php artisan test" BC_HARNESS_SAIL=off)" "off -> passa mesmo com compose"

  p=$(project mode-on)
  expect 2 "$(guard "$p" "php artisan test" BC_HARNESS_SAIL=on)" "on -> bloqueia sem compose"

  p=$(project mode-on-no-pkg)
  rm -f "$p/vendor/bin/sail"
  expect 0 "$(guard "$p" "php artisan test" BC_HARNESS_SAIL=on)" "on sem vendor/bin/sail -> passa (nao ha sail para sugerir)"

  p=$(project mode-bad-compose compose)
  expect 2 "$(guard "$p" "php artisan test" BC_HARNESS_SAIL=sim)" "invalido vale auto (com compose bloqueia)"
  p=$(project mode-bad-no-compose)
  expect 0 "$(guard "$p" "php artisan test" BC_HARNESS_SAIL=sim)" "invalido vale auto (sem compose passa)"
fi

# ---------------------------------------------------------------------------
# 5. Fora de projeto Sail -> nunca bloqueia
# ---------------------------------------------------------------------------
if case_enabled no-sail; then
  header "5. Sem vendor/bin/sail -> passa"
  p="$TMP/plain"
  mkdir -p "$p"
  printf 'services: {}\n' > "$p/compose.yaml"
  expect 0 "$(guard "$p" "php artisan test")" "compose sem sail -> passa"
fi

# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}TODOS VERDES: $PASS asserts${NC}"
else
  echo -e "${RED}FALHAS: $FAIL${NC} / verdes: $PASS"
fi
exit $((FAIL > 0 ? 1 : 0))
