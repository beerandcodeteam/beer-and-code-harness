#!/usr/bin/env bash
#
# sail-guard.sh — hook PreToolUse (Bash) do bc-harness.
#
# Se o projeto atual usa Laravel Sail (vendor/bin/sail presente E um arquivo de
# compose para ele subir — o pacote sozinho vem no esqueleto do Laravel e nao
# prova nada), bloqueia
# comandos que rodariam PHP/DB no host — onde geralmente nao ha PHP instalado
# ou o banco/redis so existe dentro do container — e devolve ao agente o
# comando equivalente via Sail. Evita o loop de "php artisan migrate" falhando
# repetidamente por connection refused.
#
# Entrada: JSON do hook no stdin ({ cwd, tool_input.command, ... }).
# Saida:   exit 0 = deixa passar; exit 2 = bloqueia (stderr vai para o agente).
# Sem parser JSON disponivel (jq/python3), falha aberto: nao bloqueia nada.
#
# BC_HARNESS_SAIL sobrepoe a deteccao: auto (default) | on (exige so o
# vendor/bin/sail) | off (nunca bloqueia). Valor desconhecido vale auto.

set -u

SAIL_MODE="${BC_HARNESS_SAIL:-auto}"
[ "$SAIL_MODE" = "off" ] && exit 0

INPUT="$(cat)"

# --- pre-filtro barato: roda em todo Bash call, sai cedo se nao ha suspeito
case "$INPUT" in
  *php*|*artisan*|*composer*|*vendor/bin/*|*mysql*|*mariadb*|*psql*|*redis-cli*) ;;
  *) exit 0 ;;
esac

# --- extrai cwd e command do JSON (jq > python3 > falha aberto)
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

# --- detecta Sail: sobe do cwd ate a raiz procurando vendor/bin/sail
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

# --- sem compose o sail nao sobe nada: o projeto roda no host (mesma regra do
# detect_sail do ralph.sh). O sail le SAIL_FILES do ambiente ou do .env do
# projeto; o docker compose le COMPOSE_FILE idem.
sail_has_compose() {
  local root="$1" f
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [ -f "$root/$f" ] && return 0
  done
  [ -n "${SAIL_FILES:-}" ] || [ -n "${COMPOSE_FILE:-}" ] && return 0
  [ -f "$root/.env" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?(SAIL_FILES|COMPOSE_FILE)=("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:]#"'"'"'])' "$root/.env"
}

if [ "$SAIL_MODE" != "on" ] && ! sail_has_compose "$SAIL_ROOT"; then
  exit 0
fi

# --- quebra o comando em segmentos (&&, ||, |, ; e quebras de linha)
SEGMENTS=$(printf '%s' "$CMD" | tr '\n' ';' | sed 's/&&/;/g; s/||/;/g; s/|/;/g')

OFFENDER=""
SUGGESTION=""
IFS=';' read -ra PARTS <<< "$SEGMENTS"
for part in "${PARTS[@]}"; do
  # trim + remove prefixos que nao mudam o veredito (sudo, VAR=valor)
  seg=$(printf '%s' "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  seg=$(printf '%s' "$seg" | sed -E 's/^(sudo[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  [ -z "$seg" ] && continue

  # ja esta no Sail ou dentro de docker exec? passa
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
  # normaliza espacos duplicados do rest
  SUGGESTION="./vendor/bin/sail $(printf '%s' "$rest" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')"
  break
done

[ -z "$OFFENDER" ] && exit 0

cat >&2 << EOF
BLOQUEADO pelo sail-guard: este projeto usa Laravel Sail ($SAIL_ROOT/vendor/bin/sail + arquivo de compose).
Comando "$OFFENDER" rodaria no HOST, onde PHP/banco/redis podem nao existir — e vai falhar (connection refused, php not found).
Use o equivalente via Sail:
  $SUGGESTION
Se os containers nao estiverem de pe, suba antes com: ./vendor/bin/sail up -d
Se este projeto NAO roda em containers, nao contorne o bloqueio: peca ao
desenvolvedor para definir BC_HARNESS_SAIL=off no ambiente do Claude Code.
EOF
exit 2
