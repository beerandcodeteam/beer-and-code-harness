#!/usr/bin/env bash
#
# ralph.sh
#
# Orquestrador que le um documento de fases, quebra em fases, e alimenta cada
# uma ao Codex CLI ou Claude Code para implementacao automatica.
#
# Invariantes:
#   1. Cada fase E cada ciclo de correcao roda em sessao NOVA, com prompt
#      auto-contido. Nunca reutiliza sessao.
#   2. Zero perguntas. Do inicio ao fim sem interacao humana.
#   3. Fase so e "completa" quando passa por 4 gates mecanicos, nunca pelo
#      exit code do engine.
#   4. Limite de uso -> espera o reset e re-executa a MESMA fase, sem consumir
#      ciclo de correcao.
#   5. Um commit por fase concluida.
#
# Agnostico de stack: a fase e o CLAUDE.md/AGENTS.md do projeto definem
# linguagem, framework, comandos e convencoes.
#
# Uso:
#   ./ralph.sh [opcoes] [caminho-do-arquivo]
#
# Opcoes:
#   --engine codex|claude    engine de implementacao (default: codex)
#   --from N                 comeca na fase N (limpa do progresso as fases >= N)
#   --keep-going             continua apos uma fase falhar (default: para)
#   --max-cycles N           ciclos de correcao por fase (default: 3)
#   --no-verify              desliga o gate 3 (equivale a RALPH_VERIFY=off)
#   --test-cmd "<cmd>"       comando de teste do projeto (gate 2)
#   --dashboard              painel ao vivo no terminal (requer ralph-watch.sh
#                            ao lado deste script); os logs vao para
#                            .phases/logs/ralph.log
#
# Observabilidade:
#   O estado do run e SEMPRE publicado em .phases/state/ (run.tsv + live.tsv),
#   com ou sem --dashboard. Para acompanhar de outro terminal:
#       ./ralph-watch.sh /caminho/do/repo
#   No engine claude a sessao roda com --output-format stream-json, o que da
#   progresso POR TASK em tempo real: o prompt manda o agente registrar uma
#   tarefa por item `- [ ]` da fase, e o ralph le essas transicoes do stream.
#   No engine codex nao ha stream equivalente: a granularidade e por fase.
#
# Input (primeiro arquivo posicional). Sem argumento, resolve nesta ordem:
#   1. .spec/init/project-phases.md      (cadeia init)
#   2. .spec/project-phases.md           (repos pre-init, com aviso)
#
#   Um PHASES.md de feature tambem e input valido:
#     ./ralph.sh .spec/features/<slug>/PHASES.md
#
# Contrato de formato do input (validado no preflight):
#   - >= 1 heading `## Phase N: <titulo>`
#   - nenhum heading `## Phase ...` fora desse formato
#   - sub-fases em `### Phase N.M:` (nao viram sessao propria)
#   - qualquer outro `## ` encerra a captura da fase anterior
#
# Gates por fase (todos verdes -> commit; qualquer vermelho -> ciclo de correcao):
#   0. engine terminou de verdade (claude: is_error no JSON; codex: exit code)
#   1. a sessao escreveu codigo? SINAL, nao veredito — uma fase ja implementada
#      faz o engine (corretamente) nao escrever nada. Alimenta a causa do ciclo
#      de correcao quando um gate posterior reprova.
#   2. suite de testes do projeto, rodada PELO ralph (fora da sessao do agente)
#   3. sessao verificadora independente, read-only, task a task — o gate final,
#      roda em toda fase (RALPH_VERIFY=always, default). RALPH_VERIFY=auto
#      economiza: so roda quando o veredito do gate 2 nao basta — sessao que
#      nao escreveu nada (claim "ja implementada"), ciclo de correcao, ou
#      gate 2 desabilitado. --no-verify / RALPH_VERIFY=off desliga. No engine
#      claude o verificador usa um modelo barato (RALPH_VERIFY_MODEL, default:
#      sonnet) — e leitura + checklist.
#
# Gates verdes com a arvore limpa => a fase ja estava implementada em HEAD:
# marcada como feita, sem commit (nao ha o que commitar).
#
# Comando de teste (gate 2), primeira regra que resolver:
#   1. --test-cmd "<cmd>"
#   2. RALPH_TEST_CMD
#   3. deteccao por manifest:
#        Laravel Sail (artisan + vendor/bin/sail)  -> vendor/bin/sail test
#        composer.json com scripts.test            -> composer test
#        artisan                                   -> php artisan test
#        package.json com scripts.test             -> npm test
#        pytest.ini / pyproject [tool.pytest]      -> pytest
#        go.mod                                    -> go test ./...
#        Cargo.toml                                -> cargo test
#   4. nada resolvido -> aviso alto + gate 2 pulado (o gate 3 segura sozinho)
#
# Laravel Sail: a suite roda dentro do container, entao Sail tem precedencia
# sobre `composer test`. Containers parados -> abort no preflight (todo gate 2
# falharia, queimando ciclos de correcao).
#
# Variaveis de ambiente:
#   RALPH_TEST_CMD           comando de teste (gate 2); --test-cmd tem prioridade
#   RALPH_VERIFY             gate 3: always (default) | auto | off
#   RALPH_VERIFY_MODEL       modelo do verificador (default: sonnet no claude)
#   RALPH_MAX_CYCLES         ciclos de correcao por fase (default: 3)
#   RALPH_MAX_LIMIT_WAITS    esperas consecutivas por limite, por fase (default: 20)
#   RALPH_LIMIT_WAIT_DEFAULT fallback de espera em segundos (default: 1800)
#   RALPH_LIMIT_BUFFER       segundos extras apos o reset (default: 60)
#
# Exportadas para hooks (ex: notify-n8n.sh) durante cada sessao de engine:
#   RALPH_ENGINE             codex | claude
#   RALPH_PHASE_TITLE        titulo da fase corrente
#   RALPH_PHASE_NUM          numero da fase corrente
#   RALPH_PHASE_TOTAL        total de fases do run
#   RALPH_PHASE_ATTEMPT      ciclo corrente (1 = implementacao inicial)
#   RALPH_PHASE_MAX_ATTEMPTS igual a RALPH_MAX_CYCLES
#
# Exit code: 0 = todas as fases verdes; 1 = alguma falhou ou abortou.
#
# Pre-requisitos:
#   - Codex: npm install -g @openai/codex + OPENAI_API_KEY
#   - Claude: npm install -g @anthropic-ai/claude-code + ANTHROPIC_API_KEY
#   - Raiz de um repo git, com a arvore de trabalho limpa

set -euo pipefail

ENGINE="codex"
INPUT_FILE=""
FROM_PHASE=0
KEEP_GOING=false
TEST_CMD_FLAG=""
MAX_CYCLES="${RALPH_MAX_CYCLES:-3}"
VERIFY_MODE="${RALPH_VERIFY:-always}"
VERIFY_MODEL=""
DASHBOARD=false

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
    --dashboard)   DASHBOARD=true; shift ;;
    -h|--help)     sed -n '2,82p' "$0"; exit 0 ;;
    *)             INPUT_FILE="$1"; shift ;;
  esac
done

PHASES_DIR=".phases"
LOG_DIR=".phases/logs"
PROMPT_DIR=".phases/prompts"
STATE_DIR=".phases/state"
MANIFEST="$PHASES_DIR/manifest.txt"
PROGRESS_FILE="$PHASES_DIR/.progress"
RUN_STATE="$STATE_DIR/run.tsv"
LIVE_STATE="$STATE_DIR/live.tsv"
RALPH_LOG="$LOG_DIR/ralph.log"

MAX_LIMIT_WAITS="${RALPH_MAX_LIMIT_WAITS:-20}"
LIMIT_WAIT_DEFAULT="${RALPH_LIMIT_WAIT_DEFAULT:-1800}"
LIMIT_BUFFER="${RALPH_LIMIT_BUFFER:-60}"

TEST_CMD=""
SAIL_BIN=""
LIMIT_WAITS=0
# Arquivo da fase corrente: o watcher do stream usa os titulos das tasks para
# casar um arquivo escrito com a task que o menciona.
CURRENT_PHASE_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Com --dashboard o painel e dono da tela: as linhas de log vao para
# LOG_SINK (.phases/logs/ralph.log) em vez de disputar o terminal.
LOG_SINK=""

emit() { if [ -n "$LOG_SINK" ]; then echo -e "$1" >> "$LOG_SINK"; else echo -e "$1"; fi; }

log()     { emit "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
success() { emit "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn()    { emit "${YELLOW}[$(date '+%H:%M:%S')] $1${NC}"; }
fail()    { emit "${RED}[$(date '+%H:%M:%S')] $1${NC}"; }

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
    warn "Usando .spec/project-phases.md (layout pre-init). O padrao atual e .spec/init/project-phases.md."
  else
    fail "Nenhum documento de fases encontrado."
    fail "Esperado .spec/init/project-phases.md (rode /init:project-phases) ou passe o caminho como argumento."
    exit 1
  fi
}

validate_input_format() {
  local top_level
  top_level=$(grep -cE '^## Phase [0-9]+: ' "$INPUT_FILE" || true)

  if [ "$top_level" -lt 1 ]; then
    fail "Contrato de formato violado: nenhum heading '## Phase N: <titulo>' em $INPUT_FILE"
    fail "ralph quebra o documento por esse heading. Corrija o documento antes de rodar."
    exit 1
  fi

  local malformed
  malformed=$(grep -E '^## Phase' "$INPUT_FILE" | grep -vE '^## Phase [0-9]+: ' || true)
  if [ -n "$malformed" ]; then
    fail "Contrato de formato violado: headings '## Phase' fora do formato '## Phase N: <titulo>':"
    echo "$malformed" | sed 's/^/    /'
    fail "Uma fase com heading torto some silenciosamente do run. Corrija antes de gastar tokens."
    exit 1
  fi

  log "Formato do input OK ($top_level fases declaradas)"
}

exclude_phases_dir() {
  local exclude_file
  exclude_file="$(git rev-parse --git-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  if ! grep -qxF '/.phases/' "$exclude_file" 2>/dev/null; then
    echo '/.phases/' >> "$exclude_file"
    log "Registrado /.phases/ em .git/info/exclude (nao mexe no .gitignore do projeto)"
  fi
}

# Laravel Sail: a suite roda DENTRO do container. Rodar `composer test` /
# `php artisan test` no host falha (sem PHP, sem banco, sem rede do compose).
# Ecoa o caminho do binario sail quando o projeto usa Sail.
detect_sail() {
  [ -f artisan ] || return 1
  if [ -x vendor/bin/sail ]; then
    echo "vendor/bin/sail"
    return 0
  fi
  # Sail declarado no composer.json mas vendor/ ainda nao instalado.
  if [ -f composer.json ] && grep -qF 'laravel/sail' composer.json; then
    echo "vendor/bin/sail"
    return 0
  fi
  return 1
}

# Containers de pe? O wrapper do sail imprime "Sail is not running." e sai != 0.
sail_running() {
  local out rc=0
  out=$("$SAIL_BIN" ps 2>&1) || rc=$?
  grep -qiF 'is not running' <<< "$out" && return 1
  [ "$rc" -ne 0 ] && return 1
  grep -qiE '(^|[[:space:]])(Up|running)([[:space:]]|$)' <<< "$out"
}

# O comando de teste invoca o sail? Olha o executavel (1o token), nao a string
# inteira: um caminho como /tmp/sail-fixture/test.sh nao usa sail.
test_cmd_uses_sail() {
  local first="${TEST_CMD%% *}"
  [ "$(basename -- "$first")" = "sail" ]
}

# Gate 2 so tem valor se rodar de verdade. Sail com containers parados falha
# toda fase e queima ciclos de correcao inuteis — aborta antes da 1a sessao.
check_sail_running() {
  [ -n "$SAIL_BIN" ] || return 0
  test_cmd_uses_sail || return 0

  if [ ! -x "$SAIL_BIN" ]; then
    fail "Laravel Sail detectado, mas $SAIL_BIN nao existe."
    fail "Rode a instalacao de dependencias do projeto (ex: composer install) antes."
    exit 1
  fi

  if ! sail_running; then
    fail "Laravel Sail detectado, mas os containers nao estao de pe."
    fail "A suite de testes (gate 2) roda dentro do container e falharia em toda fase."
    fail "Suba o ambiente antes de rodar o ralph:"
    fail "    $SAIL_BIN up -d"
    exit 1
  fi

  log "Sail: containers de pe"
}

# O gate 2 roda este comando uma vez por ciclo, em toda fase. Se o executavel
# nao existe, TODA fase reprova por um motivo que nao tem nada a ver com o
# codigo, queimando os 3 ciclos de correcao de cada uma — o mesmo estrago que o
# check de containers do Sail evita. Melhor abortar antes da primeira sessao.
#
# O caso real: RALPH_TEST_CMD="vendor/bin/sail ..." exportado no shell do dev
# vence a deteccao por manifest em QUALQUER projeto que ele rode, inclusive um
# sem Sail nenhum. A mensagem precisa dizer de onde o comando veio.
check_test_cmd_runnable() {
  local origin="$1"
  local first="${TEST_CMD%% *}"

  if [[ "$first" == */* ]]; then
    [ -x "$first" ] && return 0
  else
    command -v "$first" > /dev/null 2>&1 && return 0
  fi

  fail "Comando de teste do gate 2 nao executavel: '$first'"
  fail "Comando completo ($origin): $TEST_CMD"
  case "$origin" in
    RALPH_TEST_CMD)
      fail "Essa variavel esta exportada no seu ambiente e vence a deteccao por"
      fail "manifest em qualquer projeto. Para este run, sobreponha com:"
      fail "    --test-cmd '<comando deste projeto>'"
      fail "ou limpe a variavel:  env -u RALPH_TEST_CMD $0 ..."
      ;;
    *)
      fail "Passe --test-cmd '<comando>' com o runner correto deste projeto."
      ;;
  esac
  fail "Abortando antes da primeira sessao: todo gate 2 falharia e queimaria os ciclos de correcao."
  exit 1
}

resolve_test_cmd() {
  SAIL_BIN="$(detect_sail || true)"

  if [ -n "$TEST_CMD_FLAG" ]; then
    TEST_CMD="$TEST_CMD_FLAG"
    log "Gate 2 — comando de teste (--test-cmd): $TEST_CMD"
    check_sail_running
    check_test_cmd_runnable "--test-cmd"
    return 0
  fi

  if [ -n "${RALPH_TEST_CMD:-}" ]; then
    TEST_CMD="$RALPH_TEST_CMD"
    log "Gate 2 — comando de teste (RALPH_TEST_CMD): $TEST_CMD"
    check_sail_running
    check_test_cmd_runnable "RALPH_TEST_CMD"
    return 0
  fi

  # Sail vem ANTES de composer/npm: num projeto Laravel dockerizado o host nao
  # tem PHP nem acesso ao banco, e `composer test` mentiria como gate.
  if [ -n "$SAIL_BIN" ]; then
    TEST_CMD="$SAIL_BIN test"
  elif [ -f composer.json ] && grep -qE '"test"[[:space:]]*:' composer.json; then
    TEST_CMD="composer test"
  elif [ -f artisan ]; then
    TEST_CMD="php artisan test"
  elif [ -f package.json ] && grep -qE '"test"[[:space:]]*:' package.json; then
    TEST_CMD="npm test"
  elif [ -f pytest.ini ] || { [ -f pyproject.toml ] && grep -qF '[tool.pytest' pyproject.toml; }; then
    TEST_CMD="pytest"
  elif [ -f go.mod ]; then
    TEST_CMD="go test ./..."
  elif [ -f Cargo.toml ]; then
    TEST_CMD="cargo test"
  fi

  if [ -n "$TEST_CMD" ]; then
    log "Gate 2 — comando de teste (detectado): $TEST_CMD"
    check_sail_running
    check_test_cmd_runnable "detectado"
  else
    warn "Gate 2 DESABILITADO: nenhum comando de teste resolvido."
    if [ "$VERIFY_MODE" = "off" ]; then
      warn "--no-verify tambem desligou o gate 3: NENHUMA validacao mecanica ativa."
    else
      warn "Passe --test-cmd '<cmd>' ou defina RALPH_TEST_CMD. O gate 3 (verificador) roda em toda fase."
    fi
  fi
}

preflight_checks() {
  if [[ "$ENGINE" != "codex" && "$ENGINE" != "claude" ]]; then
    fail "Engine invalida: $ENGINE. Use 'codex' ou 'claude'."
    exit 1
  fi

  if ! [[ "$FROM_PHASE" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para --from: '$FROM_PHASE'. Use um numero inteiro (ex: --from 5)."
    exit 1
  fi

  if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]] || [ "$MAX_CYCLES" -lt 1 ]; then
    fail "Valor invalido para --max-cycles: '$MAX_CYCLES'. Use um inteiro >= 1."
    exit 1
  fi

  case "$VERIFY_MODE" in
    auto|always|off) ;;
    *)
      fail "Valor invalido para RALPH_VERIFY: '$VERIFY_MODE'. Use auto, always ou off."
      exit 1
      ;;
  esac

  # Verificacao e leitura + checklist: nao precisa do modelo de implementacao.
  # No codex nao ha default seguro de modelo barato — so aplica se pedido.
  if [ -n "${RALPH_VERIFY_MODEL:-}" ]; then
    VERIFY_MODEL="$RALPH_VERIFY_MODEL"
  elif [[ "$ENGINE" == "claude" ]]; then
    VERIFY_MODEL="sonnet"
  fi

  if ! command -v "$ENGINE" &> /dev/null; then
    if [[ "$ENGINE" == "codex" ]]; then
      fail "codex CLI nao encontrado. Instale com: npm install -g @openai/codex"
    else
      fail "Claude Code CLI nao encontrado. Instale com: npm install -g @anthropic-ai/claude-code"
    fi
    exit 1
  fi

  if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
    fail "Requer um repositorio git."
    exit 1
  fi

  resolve_input_file

  if [ ! -f "$INPUT_FILE" ]; then
    fail "Arquivo nao encontrado: $INPUT_FILE"
    exit 1
  fi

  validate_input_format
  exclude_phases_dir

  # Arvore limpa: 'git add -A' da primeira fase engoliria trabalho nao commitado.
  if [ -n "$(git status --porcelain)" ]; then
    fail "Arvore de trabalho suja. ralph commita por fase e engoliria suas mudancas."
    fail "Commite ou stashe antes de rodar:"
    git status --short | sed 's/^/    /'
    exit 1
  fi

  resolve_test_cmd

  success "Pre-checks OK (engine: $ENGINE, input: $INPUT_FILE)"
}

# ---------------------------------------------------------------------------
# Split + progresso
# ---------------------------------------------------------------------------

manifest_entries() { grep -v '^#' "$MANIFEST" || true; }

split_phases() {
  log "Quebrando $INPUT_FILE em fases..."

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

  # Progresso sobrevive entre execucoes, mas so vale para o MESMO input.
  if [ -n "$progress_backup" ]; then
    if [ -n "$old_stamp" ] && [ "$old_stamp" = "$new_stamp" ]; then
      printf '%s\n' "$progress_backup" > "$PROGRESS_FILE"
      log "Progresso anterior preservado (input inalterado)"
    else
      warn "O documento de fases mudou desde a ultima execucao — progresso zerado."
      warn "Fases marcadas como feitas pertenciam a outro plano."
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

    # Heading nivel 2 que nao e "## Phase N:" (ex: "## Open Questions"):
    # encerra a captura para nao vazar a secao para a ultima fase.
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      current_file=""
      continue
    fi

    if [ -n "$current_file" ]; then
      echo "$line" >> "$current_file"
    fi
  done < "$INPUT_FILE"

  success "$phase_count fases extraidas"
}

is_phase_done() {
  local phase_file="$1"
  [ -f "$PROGRESS_FILE" ] && grep -qxF "$phase_file" "$PROGRESS_FILE"
}

mark_phase_done() {
  echo "$1" >> "$PROGRESS_FILE"
}

# --from N tambem limpa do progresso as fases >= N (re-rodar de proposito).
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
  log "--from $FROM_PHASE: progresso das fases >= $FROM_PHASE limpo"
}

# ---------------------------------------------------------------------------
# Estado observavel (.phases/state/) — consumido por ralph-watch.sh
# ---------------------------------------------------------------------------
#
# Dois arquivos, UM ESCRITOR CADA. O watcher do stream roda em subprocesso (fim
# de pipe) e nao compartilha memoria com o loop principal; se os dois
# escrevessem o mesmo arquivo, um sobrescreveria o outro a cada flush.
#   run.tsv   loop principal: fases, gates, tentativas, meta do run
#   live.tsv  watcher do stream: task corrente e atividade da sessao
# O renderer faz o merge na leitura.
#
# O estado e publicado sempre, com ou sem --dashboard: e o que permite abrir o
# ralph-watch.sh em outro terminal no meio de um run que ja comecou.

declare -A META PH_FILE PH_TITLE PH_STATUS PH_ATTEMPT PH_GATES
declare -A TK_TITLE TK_STATUS TK_COUNT
PHASE_NUMS=()

# Titulos das tasks de uma fase, uma por linha, sem o ruido de markdown.
phase_task_titles() {
  local phase_file="$1"
  [ -f "$PHASES_DIR/$phase_file" ] || return 0
  grep -E '^[[:space:]]*- \[[ x]\]' "$PHASES_DIR/$phase_file" 2>/dev/null \
    | sed -E 's/^[[:space:]]*- \[[ x]\][[:space:]]*//
              s/\*\*Task:\*\*[[:space:]]*//
              s/\*\*//g
              s/`//g
              s/[[:space:]]+$//' \
    || true
}

# Arquivos que cada task declara, para o painel saber em qual task o agente
# esta so de ver o que ele edita. Um plano do /plan traz "Arquivos: `caminho`"
# no corpo do item; e o sinal mais confiavel que existe sem depender de o
# modelo cooperar com nenhum protocolo.
#
# Emite: <indice-da-task><TAB><peso><TAB><caminho>
#   peso 1 = declarado na linha "Arquivos:" (o alvo da task)
#   peso 2 = citado em outro ponto do corpo (referencia, espelho, exemplo)
phase_task_files() {
  local phase_file="$1"
  [ -f "$PHASES_DIR/$phase_file" ] || return 0
  awk '
    # extensoes que caracterizam arquivo de codigo/config; sem isso tokens como
    # "services.iss_rate" (coluna) entrariam como se fossem caminho
    BEGIN {
      split("php js jsx ts tsx vue py rb go rs java kt swift cs sql md yml yaml json xml css scss sass html blade twig sh bash env lock toml ini cfg conf tf gradle", e, " ")
      for (i in e) ext[e[i]] = 1
    }
    /^[[:space:]]*- \[[ xX]\]/ { idx++ }
    idx == 0 { next }
    {
      line = $0
      lvl = (line ~ /Arquivos?:/) ? 1 : 2
      while (match(line, /[A-Za-z0-9_][A-Za-z0-9_.\/-]*\.[A-Za-z0-9]+/)) {
        p = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        n = split(p, parts, ".")
        if (!(parts[n] in ext)) continue
        print idx "\t" lvl "\t" p
      }
    }
  ' "$PHASES_DIR/$phase_file" 2>/dev/null || true
}

state_flush() {
  local tmp="$RUN_STATE.$$"
  {
    local k num i
    for k in "${!META[@]}"; do printf 'META\t%s\t%s\n' "$k" "${META[$k]}"; done
    for num in "${PHASE_NUMS[@]}"; do
      printf 'PHASE\t%s\t%s\t%s\t%s\t%s\n' \
        "$num" "${PH_STATUS[$num]}" "${PH_ATTEMPT[$num]}" "${PH_GATES[$num]}" "${PH_TITLE[$num]}"
      for ((i = 1; i <= ${TK_COUNT[$num]:-0}; i++)); do
        printf 'TASK\t%s\t%s\t%s\t%s\n' "$num" "$i" "${TK_STATUS[$num:$i]}" "${TK_TITLE[$num:$i]}"
      done
    done
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$RUN_STATE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

state_meta() { META[$1]="$2"; state_flush; }

state_init() {
  mkdir -p "$STATE_DIR"
  : > "$LIVE_STATE"

  META=(
    [project]="$(basename "$(pwd)")"
    [engine]="$ENGINE"
    [input]="$INPUT_FILE"
    [status]="running"
    [started]="$(date +%s)"
    [ended]=""
    [pid]="$$"
    [run]="run-$(date '+%m%d-%H%M%S')"
    [cycle_max]="$MAX_CYCLES"
    [test_cmd]="${TEST_CMD:-—}"
    [phase_cur]=""
    [cycle]=""
    [gate]=""
    [activity]=""
    [last_error]=""
    [note]=""
  )

  local file num title i t
  while IFS='|' read -r file num title; do
    PHASE_NUMS+=("$num")
    PH_FILE[$num]="$file"
    PH_TITLE[$num]="$title"
    PH_ATTEMPT[$num]="0"
    PH_GATES[$num]="pending pending pending pending"

    if [ "$num" -lt "$FROM_PHASE" ]; then
      PH_STATUS[$num]="skipped"
    elif is_phase_done "$file"; then
      PH_STATUS[$num]="done"
    else
      PH_STATUS[$num]="pending"
    fi

    i=0
    while IFS= read -r t; do
      i=$((i + 1))
      TK_TITLE[$num:$i]="$t"
      # Fase ja concluida em run anterior: as tasks dela estao feitas.
      if [ "${PH_STATUS[$num]}" = "done" ]; then TK_STATUS[$num:$i]="done"
      else TK_STATUS[$num:$i]="pending"; fi
    done < <(phase_task_titles "$file")
    TK_COUNT[$num]="$i"
  done < <(manifest_entries)

  META[phase_total]="${#PHASE_NUMS[@]}"
  state_flush
}

# state_gate <fase> <indice 0..3> <pending|run|pass|fail|skip>
state_gate() {
  local num="$1" idx="$2" val="$3"
  local -a g
  read -r -a g <<< "${PH_GATES[$num]}"
  g[$idx]="$val"
  PH_GATES[$num]="${g[*]}"
  META[gate]="G$idx"
  state_flush
}

state_phase_begin() {
  local num="$1" cycle="$2"
  PH_STATUS[$num]="running"
  PH_ATTEMPT[$num]="$cycle"
  PH_GATES[$num]="pending pending pending pending"
  META[phase_cur]="$num"
  META[cycle]="$cycle"
  META[gate]=""
  META[activity]="iniciando a sessao do engine"
  local i
  for ((i = 1; i <= ${TK_COUNT[$num]:-0}; i++)); do
    # No ciclo de correcao as tasks ja confirmadas pelo verificador permanecem.
    [ "${TK_STATUS[$num:$i]}" = "done" ] || TK_STATUS[$num:$i]="pending"
  done
  : > "$LIVE_STATE"
  state_flush
}

state_phase_end() {
  local num="$1" status="$2"
  PH_STATUS[$num]="$status"
  META[activity]=""
  if [ "$status" = "done" ]; then
    local i
    for ((i = 1; i <= ${TK_COUNT[$num]:-0}; i++)); do TK_STATUS[$num:$i]="done"; done
  fi
  state_flush
}

# Absorve o que o watcher do stream viu, para que o estado sobreviva ao fim da
# sessao (o live.tsv e zerado a cada nova sessao).
state_absorb_live() {
  local num="$1" kind a b
  [ -f "$LIVE_STATE" ] || return 0
  while IFS=$'\t' read -r kind a b; do
    [ "$kind" = "LIVE" ] || continue
    [ -n "${TK_STATUS[$num:$a]+x}" ] || continue
    [ "${TK_STATUS[$num:$a]}" = "done" ] && continue
    TK_STATUS[$num:$a]="$b"
  done < "$LIVE_STATE"
  state_flush
}

# O veredito do gate 3 e a verdade sobre cada task: sobrepoe o que a sessao
# achou que fez.
state_tasks_from_verify() {
  local num="$1" verify_log="$2" n verdict line
  [ -f "$verify_log" ] || return 0
  while IFS= read -r line; do
    n=$(sed -E 's/^TASK ([0-9]+):.*/\1/' <<< "$line")
    verdict=$(sed -E 's/^TASK [0-9]+: ([A-Z]+).*/\1/' <<< "$line")
    [ -n "${TK_STATUS[$num:$n]+x}" ] || continue
    case "$verdict" in
      DONE)       TK_STATUS[$num:$n]="done" ;;
      INCOMPLETE) TK_STATUS[$num:$n]="incomplete" ;;
    esac
  done < <(sed 's/^[[:space:]]*//' "$verify_log" | grep -E '^TASK [0-9]+: (DONE|INCOMPLETE)' || true)
  state_flush
}

# ---------------------------------------------------------------------------
# Watcher do stream (engine claude) — progresso por task em tempo real
# ---------------------------------------------------------------------------
#
# Le o JSONL de `claude --output-format stream-json` e traduz para live.tsv.
# A lista de tarefas do agente e a fonte: o prompt manda criar UMA tarefa por
# item `- [ ]` da fase, na mesma ordem, e marcar antes/depois de cada uma.
# Suporta os dois nomes ja vistos no CLI: TaskCreate/TaskUpdate (2.x) e
# TodoWrite (versoes anteriores).
#
# Roda no fim de um pipe, logo em subprocesso: so escreve arquivo, nunca
# variavel do pai. Sempre retorna 0 — o veredito do engine e do gate 0.

json_str() {
  local line="$1" key="$2" v
  [[ "$line" == *"\"$key\":\""* ]] || return 1
  v="${line#*"\"$key\":\""}"
  printf '%s' "${v%%\"*}"
}

# Texto de campo livre (comando de shell, descricao) vai para uma linha do
# painel: corta o valor em \n / \" e limpa a barra invertida orfa que sobra do
# escape do JSON, senao a atividade aparece como `echo \`.
json_text() {
  local v
  v=$(json_str "$1" "$2") || return 1
  v="${v%%\\n*}"
  v="${v%%\\t*}"
  v="${v%"${v##*[!\\]}"}"
  v="${v//  / }"
  printf '%s' "$v"
}

agent_status_to_ralph() {
  case "$1" in
    in_progress) printf 'running' ;;
    completed)   printf 'done' ;;
    *)           printf 'pending' ;;
  esac
}

# stream_watch <live_file> <phase_num> <quiet> [phase_file]
#
# Fonte primaria: a lista de tarefas do agente. Fonte de reserva: os arquivos
# que ele escreve — nem todo modelo usa a lista, e sem reserva o painel ficaria
# com tudo "pendente" durante uma fase inteira que esta claramente andando.
stream_watch() {
  local live="$1" phase_num="$2" quiet="$3" phase_file="${4:-}"
  local -A st=() idx_of=()
  local -a pending_create=() task_titles=()
  local -a decl_task=() decl_lvl=() decl_path=()
  local next=0 activity="" line tool val tid status idx
  local agent_list_used=0 inferred_max=0 marker_used=0

  # Titulos das tasks, para casar caminho de arquivo -> task.
  if [ -n "$phase_file" ]; then
    while IFS= read -r val; do task_titles+=("$val"); done < <(phase_task_titles "$phase_file")
    # Arquivos declarados por task: o sinal forte, quando o plano os declara.
    while IFS=$'\t' read -r val status tool; do
      [ -n "${tool:-}" ] || continue
      decl_task+=("$val"); decl_lvl+=("$status"); decl_path+=("$tool")
    done < <(phase_task_files "$phase_file")
    status=""; tool=""; val=""
  fi

  # Qual task corresponde a este arquivo?
  #
  # 1) caminho declarado pela propria task ("Arquivos: `app/Models/X.php`") —
  #    o agente edita com caminho absoluto, entao basta ser sufixo;
  # 2) mesmo nome de arquivo entre os declarados;
  # 3) caminho citado em outro ponto do corpo da task (referencia);
  # 4) enunciado da task mencionando o caminho ou o nome do arquivo.
  #
  # A ordem importa: o corpo de uma task costuma citar arquivos de outras
  # (o modelo a espelhar, o teste que a cobre), e casar por esses primeiro
  # jogaria o progresso para a task errada.
  sw_task_for_file() {
    local path="$1" base i t lvl
    base=$(basename -- "$path")
    for lvl in 1 2; do
      for i in "${!decl_path[@]}"; do
        [ "${decl_lvl[$i]}" = "$lvl" ] || continue
        t="${decl_path[$i]}"
        if [ "$path" = "$t" ] || [[ "$path" == *"/$t" ]]; then
          printf '%s' "${decl_task[$i]}"; return 0
        fi
      done
      [ "$lvl" = "1" ] || continue
      for i in "${!decl_path[@]}"; do
        [ "${decl_lvl[$i]}" = "1" ] || continue
        [ "$(basename -- "${decl_path[$i]}")" = "$base" ] || continue
        printf '%s' "${decl_task[$i]}"; return 0
      done
    done
    for i in "${!task_titles[@]}"; do
      t="${task_titles[$i]}"
      if [[ "$t" == *"$path"* ]] || [[ "$t" == *"$base"* ]]; then
        printf '%s' $((i + 1))
        return 0
      fi
    done
    return 1
  }

  # Reserva: o agente escreveu o arquivo da task N. Marca N em andamento e da
  # TODAS as anteriores por concluidas — inclusive as que nunca casaram com um
  # arquivo. Nem toda task cita um: "adicionar as operacoes plus/minus/times a
  # App\Money" e feita dentro do arquivo da task anterior. Promover so as que
  # foram tocadas deixava essas pendentes ate o fim da fase, e o painel dava um
  # salto de "Pendente" direto para "Concluida", como se nunca tivessem rodado.
  #
  # E um palpite baseado na ordem em que o agente trabalha; o gate 3 corrige no
  # fim da fase, e uma task realmente nao feita volta como INCOMPLETE.
  sw_infer_from_file() {
    local path="$1" n i
    [ "$agent_list_used" -eq 1 ] && return 0
    n=$(sw_task_for_file "$path") || return 0
    for ((i = 1; i < n; i++)); do
      st["$i"]="done"
    done
    [ "${st[$n]:-}" = "done" ] || st["$n"]="running"
    [ "$n" -gt "$inferred_max" ] && inferred_max="$n"
    return 0
  }

  sw_flush() {
    local tmp="$live.$$" k
    {
      printf 'PHASE\t%s\n' "$phase_num"
      printf 'ACTIVITY\t%s\n' "$activity"
      for k in "${!st[@]}"; do printf 'LIVE\t%s\t%s\n' "$k" "${st[$k]}"; done
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$live" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  }

  sw_say() {
    [ "$quiet" = "1" ] && return 0
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC}   $1"
  }

  # Marcadores RALPH-TASK <n> START|DONE emitidos pelo agente como texto. Sao a
  # fonte primaria: ao contrario da lista de tarefas, existem em sessao headless
  # (onde TaskCreate/TodoWrite simplesmente nao estao disponiveis, mesmo depois
  # de o agente tentar carrega-las com ToolSearch).
  sw_markers() {
    local raw="$1" m n verb hit=0 i
    # `|| [ -n "$m" ]`: o ultimo match pode chegar sem quebra de linha final
    while IFS= read -r m || [ -n "$m" ]; do
      [ -n "$m" ] || continue
      n="${m#RALPH-TASK }"; n="${n%% *}"
      verb="${m##* }"
      [[ "$n" =~ ^[0-9]+$ ]] || continue
      if [ "$marker_used" -eq 0 ]; then
        # o protocolo textual assumiu: descarta o que a reserva inferiu
        marker_used=1
        st=()
      fi
      case "$verb" in
        START)
          # as anteriores ficam concluidas: o agente trabalha em ordem e nao
          # emite DONE de todas quando emenda um item no outro
          for ((i = 1; i < n; i++)); do [ -n "${st[$i]:-}" ] || st["$i"]="done"; done
          [ "${st[$n]:-}" = "done" ] || st["$n"]="running"
          sw_say "task $n em execucao"
          ;;
        DONE)
          st["$n"]="done"
          sw_say "task $n concluida"
          ;;
      esac
      hit=1
    done < <(grep -oE 'RALPH-TASK[[:space:]]+[0-9]+[[:space:]]+(START|DONE)' <<< "$raw" \
             | tr -s '[:blank:]' ' ' || true)
    [ "$hit" -eq 1 ] && sw_flush
    return 0
  }

  # Sinal de vida imediato: a sessao comecou, logo o primeiro item esta em
  # andamento. Sem isto a fase inteira aparecia "Pendente" ate o primeiro
  # evento reconhecido — que, sem lista de tarefas, podia nunca chegar.
  st[1]="running"
  sw_flush

  while IFS= read -r line; do
    # marcadores podem vir em qualquer bloco de texto do assistente
    case "$line" in
      *RALPH-TASK*) sw_markers "$line" ;;
    esac
    [ "$marker_used" -eq 1 ] && agent_list_used=1   # a reserva por arquivo cala
    case "$line" in
      # --- lista de tarefas: TaskCreate / TaskUpdate (CLI 2.x) --------------
      *'"name":"TaskCreate"'*)
        val=$(json_str "$line" subject) || val=""
        pending_create+=("$val")
        activity="planejando: $val"
        # A lista do agente assumiu: descarta o que a reserva tinha inferido.
        if [ "$agent_list_used" -eq 0 ]; then
          agent_list_used=1
          st=()
        fi
        sw_flush
        ;;
      *'"task":{"id":"'*)
        val="${line#*'"task":{"id":"'}"; val="${val%%\"*}"
        next=$((next + 1))
        idx_of["$val"]="$next"
        st["$next"]="pending"
        [ ${#pending_create[@]} -gt 0 ] && pending_create=("${pending_create[@]:1}")
        sw_flush
        ;;
      *'"name":"TaskUpdate"'*)
        tid=$(json_str "$line" taskId) || tid=""
        status=$(json_str "$line" status) || status=""
        idx="${idx_of[$tid]:-$tid}"
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ -n "$status" ]; then
          st["$idx"]=$(agent_status_to_ralph "$status")
          case "$status" in
            in_progress) sw_say "task $idx em execucao" ;;
            completed)   sw_say "task $idx concluida" ;;
          esac
          sw_flush
        fi
        ;;
      # --- lista de tarefas: TodoWrite (CLI anterior) -----------------------
      *'"name":"TodoWrite"'*)
        local rest="$line" chunk i2=0
        agent_list_used=1
        st=()
        while [[ "$rest" == *'"status":"'* ]]; do
          chunk="${rest#*'"status":"'}"
          status="${chunk%%\"*}"
          i2=$((i2 + 1))
          st["$i2"]=$(agent_status_to_ralph "$status")
          rest="$chunk"
        done
        activity="atualizou a lista de tarefas"
        sw_flush
        ;;
      # --- atividade corrente ----------------------------------------------
      *'"type":"tool_use"'*)
        tool=$(json_str "$line" name) || tool=""
        case "$tool" in
          Bash)
            val=$(json_text "$line" description) || val=$(json_text "$line" command) || val=""
            activity="bash: ${val:0:60}"
            ;;
          Edit|Write|NotebookEdit)
            val=$(json_str "$line" file_path) || val=""
            activity="$tool: $(basename -- "${val:-?}")"
            [ -n "$val" ] && sw_infer_from_file "$val"
            ;;
          Read|Glob|Grep)
            activity="lendo o projeto ($tool)"
            ;;
          ToolSearch|"") ;;
          *) activity="$tool" ;;
        esac
        sw_flush
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Prompts (auto-contidos — cada sessao e nova)
# ---------------------------------------------------------------------------

context_preamble() {
  cat <<'PREAMBLE'
## Descubra a stack e as convencoes antes de escrever codigo
Este projeto pode ser de qualquer linguagem ou framework. NAO assuma nenhuma
stack. Antes de comecar, LEIA os que existirem, nesta ordem:
1. AGENTS.md ou CLAUDE.md — convencoes, comandos e regras do projeto
2. .spec/init/project-description.md — descricao geral do projeto
3. .spec/init/user-stories.md — user stories
4. .spec/init/database-schema.md — modelo de dados
5. os documentos citados no proprio texto da fase (ex: SPEC.md/PLAN.md da feature)
Use os comandos de build, teste e execucao definidos por esses documentos e pelo
tooling ja presente no repositorio. Se o projeto tiver uma ferramenta de memoria
ou contexto configurada, use-a para entender o historico.
PREAMBLE

  # O gate 2 roda ESTE comando. Se o agente rodar outro (ex: `php artisan test`
  # no host de um projeto Sail), ele ve verde e o gate ve vermelho.
  if [ -n "$TEST_CMD" ]; then
    echo
    echo "## Comando de teste deste projeto"
    echo "Rode a suite SEMPRE com:"
    echo
    echo "    $TEST_CMD"
    echo
    echo "Este e o comando exato usado para validar a fase. Nao use outro runner"
    echo "nem rode os testes por fora dele."
    if [ -n "$SAIL_BIN" ]; then
      echo "O projeto usa Laravel Sail: artisan, composer, php e testes rodam DENTRO"
      echo "do container, via '$SAIL_BIN <cmd>'. Nunca rode essas ferramentas no host."
    fi
  fi
}

# O painel acompanha a fase task a task lendo as transicoes da lista de tarefas
# do agente no stream. Sem este bloco o ralph so sabe "fase em execucao" e o
# progresso por task fica parado ate o gate 3.
# So faz sentido no claude: o codex nao expoe um stream equivalente.
task_protocol_block() {
  [[ "$ENGINE" == "claude" ]] || return 0
  cat <<'PROTO'

## Protocolo de progresso (obrigatorio)
Um orquestrador externo le a sua saida em tempo real para mostrar ao operador
humano em qual item desta fase voce esta. O canal e TEXTO PURO, nao depende de
ferramenta nenhuma: escreva, como uma linha isolada da sua resposta,

    RALPH-TASK <n> START     antes de comecar o item n
    RALPH-TASK <n> DONE      quando o codigo E os testes do item n estiverem prontos

onde `<n>` e a posicao do item `- [ ]` nesta fase (1 para o primeiro, 2 para o
segundo, e assim por diante — nao use o codigo T03/T12 do enunciado).

Regras:
- trabalhe em um item por vez, na ordem;
- emita o START antes da primeira edicao daquele item e o DONE so quando ele
  estiver realmente pronto;
- nao emita DONE de um item que voce nao implementou;
- as duas linhas sao obrigatorias mesmo que o item seja pequeno.

Se a sua sessao tiver ferramenta de lista de tarefas (TaskCreate/TaskUpdate ou
TodoWrite), use-a tambem, com uma tarefa por item na mesma ordem — mas as
linhas `RALPH-TASK` continuam obrigatorias: em sessao headless essa ferramenta
costuma nao existir, e sem as linhas o operador fica cego durante a fase.
PROTO
}

build_impl_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior implementando uma fase deste projeto."
    echo
    context_preamble
    task_protocol_block
    cat <<'TASK'

## Sua tarefa agora
Implemente COMPLETAMENTE a fase descrita abaixo.

Para cada item:
1. Implemente o codigo completo (nao deixe TODOs ou placeholders)
2. Crie os testes listados, seguindo o framework de testes do projeto
3. Rode os testes com o comando de teste do projeto
4. Se um teste falhar, corrija o codigo e rode novamente
5. So passe pro proximo item quando os testes passarem

## Regras obrigatorias
- Use SEMPRE os comandos, o runner de testes e as ferramentas ja adotados pelo
  projeto (nao introduza uma stack ou ferramenta nova por conta propria)
- Testes e fixtures/factories devem criar todas as dependencias necessarias
- Nomes de classes, arquivos e metodos devem seguir EXATAMENTE o que esta descrito
- Nao pule nenhum item marcado com [ ]
- Ao final, valide que toda a suite de testes da fase passa

## Fase a implementar
TASK
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# Prompt de correcao: auto-contido. Carrega a fase inteira + a causa REAL
# da falha (nunca "os testes falharam" generico).
build_fix_prompt() {
  local phase_file="$1" cycle="$2" gate="$3" cause="$4"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior corrigindo uma fase parcialmente implementada."
    echo
    context_preamble
    task_protocol_block
    cat <<'INTRO'

## Situacao
Uma sessao anterior tentou implementar a fase abaixo e NAO passou na verificacao.
Voce esta numa sessao nova: nao tem memoria do que foi feito. Leia o codigo atual
antes de mudar qualquer coisa.

## Regras obrigatorias
- Corrija APENAS o que falta. Nao reimplemente o que ja esta correto e testado.
- Nao deixe TODOs, placeholders ou testes pulados.
- Rode a suite de testes do projeto ao final e garanta que ela passa.
INTRO
    echo
    echo "## Motivo da falha ($gate)"
    echo '```'
    echo "$cause"
    echo '```'
    echo
    echo "## Fase a completar"
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

Voce e um verificador independente. NAO escreva, edite ou crie nenhum arquivo.
Seu unico trabalho e ler o codigo real e dizer o que esta feito e o que nao esta.

Para CADA task marcada com `- [ ]` ou `- [x]` na fase abaixo, na ordem em que
aparecem, confira os acceptance criteria contra o codigo real (arquivos, classes,
testes, rotas, migrations — o que a task exigir) e emita EXATAMENTE UMA linha:

TASK <n>: DONE
TASK <n>: INCOMPLETE — <o que falta>

Regras:
- <n> e o indice da task na fase, comecando em 1.
- Uma linha TASK para cada task, sem excecao, sem agrupar.
- Nao emita nenhum outro texto alem das linhas TASK.
- Codigo ausente, TODO, placeholder ou teste faltando => INCOMPLETE.
- Na duvida, INCOMPLETE.

Execucao (headless — leia com atencao):
- Voce roda em sessao nao-interativa: o processo MORRE quando este turno acaba.
  Nao existe turno seguinte, nao existe notificacao de tarefa concluida.
- NUNCA rode nada em background (`run_in_background`, `&`, `nohup`) nem espere
  por notificacao de conclusao. O resultado nunca chegara e a fase sera reprovada
  por falta das linhas TASK.
- Rode comandos apenas de forma SINCRONA e apenas se forem rapidos (segundos):
  `grep`, `ls`, `route:list`, `schedule:list`, `test --filter=<Arquivo>`.
- NAO rode a suite completa (`artisan test` sem filtro): ela leva dezenas de
  minutos e nao cabe neste gate. Para tasks cujo criterio e "suite verde",
  verifique pela EXISTENCIA e pelo CONTEUDO dos testes exigidos e pelo log de
  teste da propria fase, e emita o veredito com base nisso.
- Emitir as linhas TASK e a ULTIMA coisa que voce faz e e OBRIGATORIO. Terminar o
  turno sem elas reprova a fase, mesmo que o codigo esteja correto. Se ficou sem
  evidencia suficiente para alguma task, emita INCOMPLETE para ela — nunca
  termine o turno anunciando que vai aguardar algo.

## Fase a verificar
VERIFY
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# ---------------------------------------------------------------------------
# Limite de uso (item 5) — so olha o FIM do log, com padroes por engine
# ---------------------------------------------------------------------------

# Ecoa o epoch de reset se encontrado, "0" para limite sem horario.
# Retorna 0 quando detecta limite, 1 quando nao ha limite.
detect_usage_limit() {
  local log_file="$1"
  local tail_txt pattern epoch human now

  # A mensagem de limite sai no FIM da execucao. Olhar o log inteiro faz output
  # de teste do projeto ("429", "Too Many Requests") disparar espera de 30min.
  tail_txt=$(tail -n 20 "$log_file" 2>/dev/null || true)

  # O Claude Code nao tem UMA mensagem de limite. Ja foram vistas:
  #   "Claude AI usage limit reached|1753362600"          (epoch cru)
  #   "You've hit your session limit · resets 11:10am"    (horario humano)
  #   "5-hour limit reached"
  # O denominador comum e api_error_status 429 no JSON de resultado — casar so
  # a frase deixa o limite passar por gate 0 e queima todos os ciclos de
  # correcao em segundos, que e exatamente o que o invariante 4 evita.
  if [[ "$ENGINE" == "claude" ]]; then
    pattern='usage limit reached|hit your (session|usage|[0-9]+-hour) limit|[0-9]+-hour limit reached|"api_error_status"[[:space:]]*:[[:space:]]*429'
  else
    pattern='rate limit reached|quota exceeded|usage limit reached|too many requests'
  fi

  grep -qiE "$pattern" <<< "$tail_txt" || return 1

  epoch=$(grep -oiE 'usage limit reached[^0-9]*[0-9]{10,13}' <<< "$tail_txt" \
    | grep -oE '[0-9]{10,13}' | tail -1 || true)

  if [ -z "$epoch" ]; then
    epoch=$(grep -oiE 'reset[a-z ]*[0-9]{10,13}' <<< "$tail_txt" \
      | grep -oE '[0-9]{10,13}' | tail -1 || true)
  fi

  # Horario humano ("resets 11:10am", "resets at 3pm"): resolve para a proxima
  # ocorrencia. Sem isso o run cai no fallback de 30min mesmo sabendo a hora.
  if [ -z "$epoch" ]; then
    human=$(grep -oiE 'resets?[[:space:]]+(at[[:space:]]+)?[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' <<< "$tail_txt" \
      | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' | tail -1 || true)
    if [ -n "$human" ]; then
      epoch=$(date -d "$human" +%s 2>/dev/null || true)
      now=$(date +%s)
      if [ -n "$epoch" ] && [ "$epoch" -le "$now" ]; then
        epoch=$(date -d "tomorrow $human" +%s 2>/dev/null || echo "$epoch")
      fi
    fi
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
    fail "Limite de uso atingido $LIMIT_WAITS vezes seguidas nesta fase (cap: $MAX_LIMIT_WAITS)."
    fail "Abortando em vez de dormir indefinidamente."
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
    warn "Limite de uso atingido. Reset previsto para $(date -d "@$epoch" '+%d/%m %H:%M:%S')."
  else
    wait_secs=$LIMIT_WAIT_DEFAULT
    warn "Limite de uso atingido. Sem horario de reset no output; aguardando fallback."
  fi

  warn "Espera $LIMIT_WAITS/$MAX_LIMIT_WAITS — aguardando $(format_duration "$wait_secs") ate retomar a MESMA fase..."

  META[status]="waiting"
  local remaining=$wait_secs chunk
  while [ "$remaining" -gt 0 ]; do
    chunk=60
    [ "$remaining" -lt 60 ] && chunk=$remaining
    state_meta activity "limite de uso — retomando em $(format_duration "$remaining")"
    sleep "$chunk"
    remaining=$((remaining - chunk))
    [ "$remaining" -gt 0 ] && log "Retomando em $(format_duration "$remaining")..."
  done
  META[status]="running"
  state_meta activity "retomando a fase"

  success "Reset provavelmente concluido. Retomando execucao."
}

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

# run_engine <prompt_file> <log_file> <mode: impl|verify>
# Loop de resiliencia a limite de uso: nao consome ciclo de correcao.
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
      # < /dev/null: claude -p le stdin quando nao e TTY. Sem o redirect ele
      # consome o stream de quem chamou (ex: o manifest do loop de fases).
      if [[ "$mode" == "verify" ]]; then
        env -u CLAUDECODE claude --dangerously-skip-permissions \
          "${model_args[@]}" \
          -p "$(cat "$prompt_file")" \
          --allowedTools "Read,Glob,Grep" \
          --output-format text < /dev/null 2>&1 | tee "$log_file" || rc=$?
      else
        # stream-json: eventos linha a linha ENQUANTO a sessao roda — e o que
        # da progresso por task ao painel. O JSON de resultado continua sendo a
        # ultima linha, com "type":"result" e is_error: o gate 0 nao muda.
        # O exit code do CLI e sinal fraco; quem decide e o gate 0.
        local quiet=0
        $DASHBOARD && quiet=1
        if env -u CLAUDECODE claude --dangerously-skip-permissions \
             -p "$(cat "$prompt_file")" \
             --output-format stream-json --verbose < /dev/null 2>&1 \
             | tee "$log_file" \
             | stream_watch "$LIVE_STATE" "${RALPH_PHASE_NUM:-0}" "$quiet" "$CURRENT_PHASE_FILE"; then
          rc=0
        else
          rc=$?
        fi
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

# Gate 0 — o engine terminou de verdade?
# Preenche GATE_CAUSE quando vermelho.
GATE_CAUSE=""

gate0_engine_finished() {
  local log_file="$1" rc="$2"

  if [[ "$ENGINE" == "claude" ]]; then
    # is_error tem que sair do EVENTO DE RESULTADO, nunca do log inteiro.
    # Com --output-format stream-json o log carrega toda a conversa, e um
    # tool_result de ferramenta que falhou (um grep sem match, um teste
    # vermelho, um ls de arquivo inexistente) tambem traz "is_error":true.
    # Isso e trabalho normal do agente, nao falha do engine: varrer o arquivo
    # todo reprovava a fase inteira por causa de um comando que retornou 1.
    local result_line
    result_line=$(grep -F '"type":"result"' "$log_file" | tail -n 1)
    [ -z "$result_line" ] && result_line=$(grep -F '"type": "result"' "$log_file" | tail -n 1)

    if [ -z "$result_line" ]; then
      GATE_CAUSE="O engine terminou sem emitir um resultado. Ultimas linhas do output:"$'\n'"$(tail -n 40 "$log_file")"
      return 1
    fi
    if grep -qE '"is_error"[[:space:]]*:[[:space:]]*true' <<< "$result_line"; then
      GATE_CAUSE="O engine reportou is_error=true no resultado. Ultimas linhas do output:"$'\n'"$(tail -n 40 "$log_file")"
      return 1
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="O engine saiu com codigo $rc. Ultimas linhas do output:"$'\n'"$(tail -n 40 "$log_file")"
    return 1
  fi

  return 0
}

# Assinatura da arvore: rastreados (status + diff) e nao-rastreados (conteudo).
# Sem mutar o index.
tree_signature() {
  {
    git status --porcelain
    git diff HEAD
    git ls-files --others --exclude-standard -z | xargs -0 -r sha256sum 2> /dev/null
  } 2> /dev/null | sha256sum | cut -c1-16
}

# Gate 1 — esta sessao escreveu codigo?
#
# SINAL, nao veredito. Uma fase pode ja estar implementada antes da sessao
# (tasks `[x]`, run anterior commitada, dev implementou a mao). Nesse caso o
# engine correto NAO escreve nada, e reprovar aqui seria um falso negativo:
# so os gates 2 e 3 sabem se o codigo esta completo.
#
# O retorno alimenta a causa do ciclo de correcao ("a sessao nao escreveu
# nada") quando algum gate posterior reprova.
gate1_session_wrote() {
  local sig_before="$1"
  [ "$(tree_signature)" != "$sig_before" ]
}

# Gate 2 — a suite do projeto passa, rodada PELO ralph (fora da sessao do agente)?
gate2_tests_pass() {
  local test_log="$1"

  if [ -z "$TEST_CMD" ]; then
    return 0
  fi

  log "Gate 2 — rodando a suite do projeto: $TEST_CMD"
  local rc=0
  # < /dev/null: sail test (docker compose exec) anexa stdin e consumiria o
  # stream de quem chamou, alem de poder travar esperando input.
  bash -c "$TEST_CMD" < /dev/null > "$test_log" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="O comando de teste do projeto ('$TEST_CMD') falhou com codigo $rc. Saida:"$'\n'"$(tail -n 200 "$test_log")"
    return 1
  fi

  success "Gate 2 — suite verde"
  return 0
}

# Gate 3 — sessao verificadora independente, read-only, task a task.
# O gate final: roda em toda fase por default (always). Modo auto economiza,
# rodando so quando o veredito do gate 2 nao basta:
#   - a sessao nao escreveu nada (claim "ja implementada" — so a verificacao
#     independente confirma isso sem confiar na palavra do engine)
#   - ciclo de correcao (a fase ja reprovou uma vez)
#   - gate 2 desabilitado (sem suite, o verificador e o unico gate)
# GATE3_RAN diz ao caminho "ja implementada" quais gates de fato validaram HEAD.
GATE3_RAN=0

gate3_independent_verify() {
  local phase_file="$1" cycle="$2" session_wrote="$3"
  local verify_log="$LOG_DIR/${phase_file%.md}.verify-${cycle}.log"

  GATE3_RAN=0

  case "$VERIFY_MODE" in
    off)
      log "Gate 3 pulado (--no-verify)"
      return 0
      ;;
    auto)
      if [ "$cycle" -eq 1 ] && [ "$session_wrote" -eq 1 ] && [ -n "$TEST_CMD" ]; then
        log "Gate 3 pulado: a sessao escreveu codigo e a suite passou (RALPH_VERIFY=always para rodar sempre)"
        return 0
      fi
      ;;
  esac

  local expected
  expected=$(grep -cE '^[[:space:]]*- \[[ x]\]' "$PHASES_DIR/$phase_file" || true)

  if [ "$expected" -eq 0 ]; then
    warn "Gate 3 pulado: a fase nao declara nenhuma task '- [ ]'"
    return 0
  fi

  GATE3_RAN=1
  log "Gate 3 — sessao verificadora independente ($expected tasks${VERIFY_MODEL:+, modelo: $VERIFY_MODEL})"

  local prompt_file
  prompt_file=$(build_verify_prompt "$phase_file" "$cycle")
  run_engine "$prompt_file" "$verify_log" verify || true

  local task_lines
  task_lines=$(sed 's/^[[:space:]]*//' "$verify_log" | grep -E '^TASK [0-9]+: (DONE|INCOMPLETE)' || true)

  local parsed
  parsed=$(printf '%s' "$task_lines" | grep -c . || true)

  if [ "$parsed" -eq 0 ]; then
    GATE_CAUSE="O verificador independente nao emitiu nenhuma linha 'TASK <n>: DONE|INCOMPLETE' — nao foi possivel confirmar que a fase esta completa. Ultimas linhas do verificador:"$'\n'"$(tail -n 40 "$verify_log")"
    return 1
  fi

  if [ "$parsed" -ne "$expected" ]; then
    GATE_CAUSE="O verificador cobriu $parsed de $expected tasks — cobertura incompleta. Linhas emitidas:"$'\n'"$task_lines"
    return 1
  fi

  local incomplete
  incomplete=$(printf '%s\n' "$task_lines" | grep 'INCOMPLETE' || true)

  if [ -n "$incomplete" ]; then
    GATE_CAUSE="O verificador independente encontrou tasks incompletas:"$'\n'"$incomplete"
    return 1
  fi

  success "Gate 3 — $parsed/$expected tasks confirmadas no codigo"
  return 0
}

# ---------------------------------------------------------------------------
# Execucao de fase
# ---------------------------------------------------------------------------

commit_phase() {
  local phase_num="$1" phase_title="$2"
  git add -A
  if git diff --cached --quiet; then
    fail "Nada para commitar apos os gates — estado inesperado."
    return 1
  fi
  git commit -q -m "feat(phase-${phase_num}): ${phase_title}"
  log "Commit criado: feat(phase-${phase_num}): ${phase_title}"
}

commit_wip() {
  local phase_num="$1"
  [ -n "$(git status --porcelain)" ] || return 0
  git add -A
  git commit -q -m "wip(phase-${phase_num}): incomplete — see .phases/logs/"
  warn "Commit wip criado para a fase $phase_num — a proxima fase parte de arvore limpa"
}

# run_phase <phase_file> <phase_num> <phase_title> <seq> <total>
run_phase() {
  local phase_file="$1" phase_num="$2" phase_title="$3" seq="$4" total="$5"
  local phase_start
  phase_start=$(date +%s)

  export RALPH_PHASE_TITLE="$phase_title"
  export RALPH_PHASE_NUM="$phase_num"
  export RALPH_PHASE_TOTAL="$total"
  CURRENT_PHASE_FILE="$phase_file"

  LIMIT_WAITS=0
  GATE_CAUSE=""

  echo ""
  log "[$seq/$total] Phase $phase_num: $phase_title"

  local cycle=1
  while [ "$cycle" -le "$MAX_CYCLES" ]; do
    export RALPH_PHASE_ATTEMPT="$cycle"
    [ "$cycle" -gt 1 ] && warn "Ciclo de correcao $cycle/$MAX_CYCLES..."

    state_phase_begin "$phase_num" "$cycle"

    local prompt_file log_file rc=0 sig_before
    log_file="$LOG_DIR/${phase_file%.md}.cycle-${cycle}.log"

    if [ "$cycle" -eq 1 ]; then
      prompt_file=$(build_impl_prompt "$phase_file" "$cycle")
    else
      prompt_file=$(build_fix_prompt "$phase_file" "$cycle" "$LAST_GATE" "$GATE_CAUSE")
    fi

    sig_before=$(tree_signature)
    run_engine "$prompt_file" "$log_file" impl || rc=$?

    state_absorb_live "$phase_num"
    state_meta activity "avaliando os gates"
    GATE_CAUSE=""

    # Gate 1 e sinal, nao veredito: uma fase ja implementada faz o engine
    # (corretamente) nao escrever nada. Quem decide sao os gates 2 e 3.
    # O sinal tambem alimenta o modo auto do gate 3: sessao sem escrita e
    # exatamente o caso em que a verificacao independente e obrigatoria.
    local no_change_note="" session_wrote=1
    if ! gate1_session_wrote "$sig_before"; then
      session_wrote=0
      no_change_note="A sessao anterior terminou sem alterar nenhum arquivo. "
      warn "Gate 1 — a sessao nao escreveu nada; validando o codigo existente"
    fi

    # O painel espelha cada gate na hora em que ele roda. A ordem e a mesma da
    # avaliacao: quem reprova para a cadeia e vira ciclo de correcao.
    local verify_log="$LOG_DIR/${phase_file%.md}.verify-${cycle}.log"
    local gate_verdict="green"

    if ! gate0_engine_finished "$log_file" "$rc"; then
      state_gate "$phase_num" 0 fail
      LAST_GATE="gate 0 — engine nao concluiu"
      fail "Gate 0 vermelho"
      gate_verdict="red"
    else
      state_gate "$phase_num" 0 pass
      if [ "$session_wrote" -eq 1 ]; then state_gate "$phase_num" 1 pass
      else state_gate "$phase_num" 1 skip; fi

      if [ -n "$TEST_CMD" ]; then state_gate "$phase_num" 2 run; else state_gate "$phase_num" 2 skip; fi

      if ! gate2_tests_pass "$LOG_DIR/${phase_file%.md}.test-${cycle}.log"; then
        state_gate "$phase_num" 2 fail
        LAST_GATE="gate 2 — suite de testes do projeto"
        GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
        fail "Gate 2 vermelho — testes do projeto falharam"
        gate_verdict="red"
      else
        [ -n "$TEST_CMD" ] && state_gate "$phase_num" 2 pass
        state_gate "$phase_num" 3 run
        state_meta activity "verificador independente lendo o codigo"

        if ! gate3_independent_verify "$phase_file" "$cycle" "$session_wrote"; then
          state_tasks_from_verify "$phase_num" "$verify_log"
          state_gate "$phase_num" 3 fail
          LAST_GATE="gate 3 — verificacao independente"
          GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
          fail "Gate 3 vermelho — implementacao incompleta"
          gate_verdict="red"
        else
          state_tasks_from_verify "$phase_num" "$verify_log"
          if [ "$GATE3_RAN" -eq 1 ]; then state_gate "$phase_num" 3 pass
          else state_gate "$phase_num" 3 skip; fi
        fi
      fi
    fi

    if [ "$gate_verdict" = "red" ]; then
      state_meta last_error "$(printf '%s' "$GATE_CAUSE" | head -n 1 | cut -c1-70)"
    else
      local phase_duration=$(($(date +%s) - phase_start))

      # Gates verdes e nada a commitar => a fase ja estava implementada em HEAD
      # (run anterior commitada, tasks [x], codigo escrito a mao).
      if [ -z "$(git status --porcelain)" ]; then
        success "Phase $phase_num: $phase_title — JA IMPLEMENTADA (nada a commitar)"
        if [ "$GATE3_RAN" -eq 1 ]; then
          log "Gates 2 e 3 verdes contra o codigo em HEAD; nenhum commit criado."
        else
          log "Gate 2 verde contra o codigo em HEAD; nenhum commit criado."
        fi
        mark_phase_done "$phase_file"
        state_phase_end "$phase_num" done
        return 0
      fi

      success "Phase $phase_num: $phase_title — COMPLETA ($(format_duration "$phase_duration"))"
      if ! commit_phase "$phase_num" "$phase_title"; then
        LAST_GATE="commit"
        state_phase_end "$phase_num" failed
        return 1
      fi
      mark_phase_done "$phase_file"
      state_phase_end "$phase_num" done
      return 0
    fi

    cycle=$((cycle + 1))
  done

  local phase_duration=$(($(date +%s) - phase_start))
  state_phase_end "$phase_num" failed
  fail "Phase $phase_num: $phase_title — FALHOU apos $MAX_CYCLES ciclos ($(format_duration "$phase_duration"))"
  fail "Ultima causa ($LAST_GATE):"
  printf '%s\n' "$GATE_CAUSE" | head -n 20 | sed 's/^/    /'
  fail "Logs em: $LOG_DIR/${phase_file%.md}.*"

  # O trabalho parcial fica na arvore; o preflight da proxima execucao exige
  # arvore limpa. Diga o que fazer em vez de deixar o dev descobrir no abort.
  if [ -n "$(git status --porcelain)" ]; then
    warn "O trabalho parcial desta fase ficou na arvore. Antes de re-rodar o ralph:"
    warn "    commite (o ralph revalida a fase e segue) ou 'git checkout -- . && git clean -fd' (descarta)"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Dashboard embutido (--dashboard)
# ---------------------------------------------------------------------------
#
# O painel e o ralph-watch.sh, o mesmo que roda em outro terminal — aqui ele so
# e iniciado em background e mandado desenhar sobre a tela alternativa. Manter
# um unico renderer evita duas implementacoes do mesmo layout divergindo.
#
# O ralph.sh continua funcionando sozinho: sem o ralph-watch.sh ao lado, o
# --dashboard degrada para o modo de log com um aviso.

DASH_PID=""

start_dashboard() {
  $DASHBOARD || return 0

  local watch
  watch="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-watch.sh"

  if [ ! -f "$watch" ]; then
    warn "--dashboard pedido, mas $watch nao existe. Seguindo com o log normal."
    warn "O estado continua publicado em $RUN_STATE — da para acompanhar de outro terminal."
    DASHBOARD=false
    return 0
  fi

  mkdir -p "$LOG_DIR"
  : > "$RALPH_LOG"
  LOG_SINK="$RALPH_LOG"

  tput smcup 2>/dev/null || true
  bash "$watch" --embedded . &
  DASH_PID=$!
}

stop_dashboard() {
  [ -n "$DASH_PID" ] || return 0
  kill "$DASH_PID" 2>/dev/null || true
  wait "$DASH_PID" 2>/dev/null || true
  DASH_PID=""
  tput rmcup 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  LOG_SINK=""
}

# Sem isto, um Ctrl-C no meio de um run deixa o terminal na tela alternativa e
# sem cursor.
on_exit() {
  local code=$?
  if [ -n "${META[status]:-}" ] && [ "${META[status]}" = "running" ]; then
    META[status]="failed"
    META[ended]="$(date +%s)"
    state_flush
  fi
  stop_dashboard
  exit "$code"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

LAST_GATE=""

main() {
  preflight_checks
  split_phases
  apply_from_override
  state_init
  trap on_exit EXIT INT TERM
  start_dashboard

  local total_phases
  total_phases=$(manifest_entries | wc -l)

  if [ "$total_phases" -eq 0 ]; then
    fail "Nenhuma fase extraida de $INPUT_FILE."
    exit 1
  fi

  if [ "$FROM_PHASE" -gt "$total_phases" ]; then
    fail "--from $FROM_PHASE excede o total de fases ($total_phases)."
    exit 1
  fi

  echo ""
  log "$total_phases fases para implementar (engine: $ENGINE, max-cycles: $MAX_CYCLES)"
  [ "$FROM_PHASE" -gt 1 ] && log "Iniciando a partir da fase $FROM_PHASE"
  echo ""

  local file num title
  while IFS='|' read -r file num title; do
    if [ "$num" -lt "$FROM_PHASE" ]; then
      echo -e "  ${BLUE}[$num] $title (pulada por --from)${NC}"
    elif is_phase_done "$file"; then
      echo -e "  ${GREEN}[$num] $title (ja completada)${NC}"
    else
      echo -e "  ${YELLOW}[$num] $title${NC}"
    fi
  done < <(manifest_entries)

  local start_time
  start_time=$(date +%s)
  echo ""
  log "Inicio: $(date '+%d/%m/%Y %H:%M:%S')"

  local seq=0
  local failed_phases=() skipped_phases=() completed_phases=()

  # fd 3, nunca stdin: comandos do corpo (claude -p, sail test / docker compose
  # exec) leem stdin quando nao e TTY e engoliriam o resto do manifest — o run
  # pararia apos a primeira fase.
  while IFS='|' read -r -u 3 file num title; do
    seq=$((seq + 1))

    if [ "$num" -lt "$FROM_PHASE" ]; then
      log "Pulando Phase $num: $title (antes de --from $FROM_PHASE)"
      skipped_phases+=("$title")
      continue
    fi

    if is_phase_done "$file"; then
      log "Pulando Phase $num: $title (ja completada)"
      skipped_phases+=("$title")
      continue
    fi

    if run_phase "$file" "$num" "$title" "$seq" "$total_phases"; then
      completed_phases+=("$title")
    else
      failed_phases+=("$title")
      if $KEEP_GOING; then
        warn "--keep-going: seguindo para a proxima fase"
        commit_wip "$num"
      else
        warn "Parando na primeira fase que falhou (use --keep-going para continuar)"
        break
      fi
    fi
  done 3< <(manifest_entries)

  local end_time total_duration
  end_time=$(date +%s)
  total_duration=$((end_time - start_time))

  META[ended]="$end_time"
  META[activity]=""
  META[gate]=""
  if [ ${#failed_phases[@]} -eq 0 ]; then META[status]="finished"; else META[status]="failed"; fi
  # O live.tsv e da sessao, nao do run: mante-lo faria o painel exibir para
  # sempre a ultima acao de uma sessao que ja terminou.
  : > "$LIVE_STATE"
  state_flush

  # O painel some com a tela alternativa: o relatorio final tem que sair depois,
  # no terminal de verdade, senao o run termina sem deixar rastro na rolagem.
  stop_dashboard

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "RELATORIO FINAL (engine: $ENGINE)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local phase
  if [ ${#completed_phases[@]} -gt 0 ]; then
    echo ""
    success "Completadas (${#completed_phases[@]}):"
    for phase in "${completed_phases[@]}"; do printf '    %b%s%b\n' "$GREEN" "$phase" "$NC"; done
  fi

  if [ ${#skipped_phases[@]} -gt 0 ]; then
    echo ""
    log "Puladas (${#skipped_phases[@]}):"
    for phase in "${skipped_phases[@]}"; do printf '    %s\n' "$phase"; done
  fi

  if [ ${#failed_phases[@]} -gt 0 ]; then
    echo ""
    fail "Falharam (${#failed_phases[@]}):"
    for phase in "${failed_phases[@]}"; do printf '    %b%s%b\n' "$RED" "$phase" "$NC"; done
    echo ""
    fail "Verifique os logs em $LOG_DIR/"
  fi

  echo ""
  log "Inicio: $(date -d "@$start_time" '+%d/%m/%Y %H:%M:%S')"
  log "Fim:    $(date -d "@$end_time" '+%d/%m/%Y %H:%M:%S')"
  log "Duracao total: $(format_duration "$total_duration")"
  echo ""

  [ ${#failed_phases[@]} -eq 0 ] || exit 1
}

# RALPH_LIB_ONLY=1 carrega as funcoes sem executar o run — a suite usa isso
# para testar unidades (ex: stream_watch) sem subir um repo fixture inteiro.
[ "${RALPH_LIB_ONLY:-0}" = "1" ] || main
