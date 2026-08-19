#!/usr/bin/env bash
#
# ralph-watch.sh
#
# Painel de acompanhamento do ralph.sh em tempo real.
#
# Le o estado publicado pelo ralph em .phases/state/ e redesenha o painel.
# Nao executa nada, nao escreve no estado: e um leitor puro. Pode rodar num
# segundo terminal enquanto o ralph trabalha, ou ser embutido pelo proprio
# ralph via `ralph.sh --dashboard`.
#
# Uso:
#   ./ralph-watch.sh [opcoes] [caminho-do-repo]
#
# Opcoes:
#   --once              desenha um frame e sai (util em script/teste)
#   --interval N        segundos entre frames (default: 1)
#   --embedded          modo chamado pelo ralph: nao troca a tela alternativa
#                       (quem chamou ja trocou) e sai quando o run termina
#   --no-color          desliga ANSI
#   --color             forca ANSI mesmo sem terminal (teste)
#
# Layout: o topo (identificacao, barras, trabalho atual) e fixo; a tabela de
# fases e tasks rola dentro de uma janela que cabe na altura do terminal. Sem
# isso, num plano com dezenas de tasks o cabecalho subia para fora da tela
# alternativa — onde o scroll do terminal nao alcanca.
#
# Teclas (quando ha /dev/tty, inclusive rodando embutido no ralph):
#   ↑/↓ ou k/j     rola uma linha        PgUp/PgDn ou b/espaco  rola uma pagina
#   Home/g         primeira linha        End/G                  ultima linha
#   f              volta a seguir a fase corrente (modo automatico)
#   q              sai do painel (nao interrompe o ralph)
#
# Variaveis de ambiente:
#   RALPH_WATCH_COLS   fixa a largura (teste, pipe, terminal que nao reporta)
#   RALPH_WATCH_LINES  fixa a altura; com --once tambem liga a janela rolante
#
# Contrato de estado (escrito pelo ralph, TSV, um escritor por arquivo):
#
#   .phases/state/run.tsv      escritor: processo principal do ralph
#     META<TAB>chave<TAB>valor
#     PHASE<TAB>num<TAB>status<TAB>tentativa<TAB>"g0 g1 g2 g3"<TAB>titulo
#     TASK<TAB>fase<TAB>indice<TAB>status<TAB>titulo
#
#   .phases/state/live.tsv     escritor: watcher do stream da sessao corrente
#     PHASE<TAB>num
#     ACTIVITY<TAB>texto
#     LIVE<TAB>indice<TAB>status
#
# Dois arquivos com um escritor cada evitam corrida entre o loop principal e o
# watcher do stream, que roda em subprocesso. O merge acontece aqui, na leitura:
# live.tsv tem precedencia sobre run.tsv para as tasks da fase corrente.
#
# Vocabulario de status:
#   fase  pending | running | done | failed | skipped
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

# --color mantem o ANSI quando a saida nao e um terminal (teste, arquivo).
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
# Estado lido
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

  # live.tsv vence para a fase corrente: e o que a sessao esta fazendo agora.
  if [ -f "$LIVE_STATE" ]; then
    while IFS=$'\t' read -r kind a b c; do
      case "$kind" in
        PHASE)    LIVE_PHASE="$a" ;;
        ACTIVITY) [ -n "$a" ] && META[activity]="$a" ;;
        LIVE)
          if [ -n "$LIVE_PHASE" ] && [ -n "${TK_STATUS[$LIVE_PHASE:$a]+x}" ]; then
            # nao rebaixa uma task ja confirmada pelo verificador (gate 3)
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
# Primitivas de desenho
# ---------------------------------------------------------------------------

# As funcoes *_v escrevem o resultado na variavel nomeada em $1 em vez de na
# saida: `printf -v` nao abre subshell, e e isso que permite montar uma linha da
# tabela sem os ~15 forks que o `$(pad ...)` custava. O build_rows monta TODAS as
# linhas a cada frame, entao ali a diferenca e de ~500ms para alguns ms por
# quadro — e o quadro e redesenhado tambem a cada tecla de rolagem.
#
# Toda variavel interna daqui leva prefixo __: o destino vem do chamador, e um
# `pad_v out ...` com um `local out` aqui dentro escreveria na local da funcao em
# vez da do chamador — falha silenciosa, com a saida saindo vazia.

# pad_v <destino> <texto> <largura> — o pad, escrevendo numa variavel.
pad_v() {
  local __s="$2" __w="$3" __n
  __n=${#2}
  if [ "$__n" -gt "$__w" ]; then
    if [ "$__w" -gt 1 ]; then __s="${__s:0:__w-1}…"; else __s="${__s:0:__w}"; fi
    __n=$__w
  fi
  printf -v "$1" '%s%*s' "$__s" $((__w - __n)) ''
}

# pad <texto> <largura> — trunca com reticencia ou completa com espacos.
# Em locale UTF-8 ${#s} conta caracteres, nao bytes: e o que mantem o
# alinhamento das colunas com acentos e box-drawing.
pad() {
  local REPLY_PAD
  pad_v REPLY_PAD "$1" "$2"
  printf '%s' "$REPLY_PAD"
}

# cell_v <destino> <colorido> <plain> <largura> — celula colorida com padding
# correto: mede o texto SEM ANSI (plain) e completa a diferenca. Colorir depois
# de padear inflaria a largura visivel, porque o ANSI conta em ${#s}.
cell_v() {
  local __n=${#3}
  if [ "$__n" -gt "$4" ]; then pad_v "$1" "$3" "$4"; return; fi
  printf -v "$1" '%s%*s' "$2" $(( $4 - __n )) ''
}

repeat_v() { local __ch="$2" __n="$3" __out="" __i; for ((__i=0; __i<__n; __i++)); do __out+="$__ch"; done; printf -v "$1" '%s' "$__out"; }

bar_v() { # <destino> <feito> <total> <largura>
  local __done="$2" __total="$3" __width="$4"
  local __filled=0 __f __e
  [ "$__total" -gt 0 ] && __filled=$(( __done * __width / __total ))
  [ "$__filled" -gt "$__width" ] && __filled=$__width
  repeat_v __f '█' "$__filled"
  repeat_v __e '░' $(( __width - __filled ))
  printf -v "$1" '%s%s%s%s%s' "$C_GREEN" "$__f" "$C_GREY" "$__e" "$C_RESET"
}

pct_v() { # <destino> <n> <total>
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
# Vocabulario -> rotulo colorido
# ---------------------------------------------------------------------------

status_label() {
  case "$1" in
    done)       printf '%s✓ Concluída%s'   "$C_GREEN"  "$C_RESET" ;;
    running)    printf '%s▶ Em execução%s' "$C_YELLOW" "$C_RESET" ;;
    failed)     printf '%s✗ Falhou%s'      "$C_RED"    "$C_RESET" ;;
    incomplete) printf '%s! Incompleta%s'  "$C_RED"    "$C_RESET" ;;
    skipped)    printf '%s– Pulada%s'      "$C_GREY"   "$C_RESET" ;;
    *)          printf '%s· Pendente%s'    "$C_GREY"   "$C_RESET" ;;
  esac
}

status_plain() {
  case "$1" in
    done)       printf '✓ Concluída' ;;
    running)    printf '▶ Em execução' ;;
    failed)     printf '✗ Falhou' ;;
    incomplete) printf '! Incompleta' ;;
    skipped)    printf '– Pulada' ;;
    *)          printf '· Pendente' ;;
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

# Rotulos memoizados. O vocabulario e fechado (6 status, 5 marcas de gate), e as
# funcoes acima continuam sendo a unica fonte de verdade: a tabela e derivada
# delas uma vez no startup, entao mudar um rotulo continua sendo mexer em um
# lugar so. Quem monta linha le da tabela e nao paga fork nenhum.
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

# gates_cell_v <destino> <spec> <colorido:0|1> — o gates_cell sem subshell.
gates_cell_v() {
  # splitting direto no lugar de `read -r -a`: o spec vem do vocabulario fechado
  # de gates (pending|run|pass|fail|skip), sem espaco nem metacaractere de glob.
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

# Estado da janela rolante da tabela. FOLLOW=true deixa o painel escolher o
# recorte sozinho (segue a fase corrente); qualquer tecla de rolagem passa o
# controle para o usuario ate ele apertar `f`.
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

# RALPH_WATCH_COLS fixa a largura (teste, pipe, terminal que nao reporta).
#
# `tput cols` sozinho nao basta: com --embedded o painel roda em background
# (`&`) a partir do ralph, e ali o tput pode nao enxergar o terminal — o painel
# caia para a largura minima e truncava os titulos num terminal largo.
# /dev/tty responde mesmo em background, entao serve de segunda fonte.
calc_width() {
  local cols="${RALPH_WATCH_COLS:-}"

  # stty PRIMEIRO: le o tamanho real do terminal por ioctl. `tput cols` parece
  # funcionar mas devolve o 80 do terminfo quando nao consegue determinar o
  # tamanho — e 80 e um numero plausivel, entao passava batido e o painel
  # ficava com metade da largura num terminal largo.
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

  # Sem teto artificial: o painel acompanha o terminal. calc_width roda a cada
  # frame, entao redimensionar a janela reflete no desenho seguinte.
  W=$cols
  [ "$W" -lt 64 ] && W=64
}

# Mesma escada do calc_width, pelas mesmas razoes: stty le o tamanho real por
# ioctl e responde mesmo com o painel em background; tput cai para o 24 do
# terminfo quando nao sabe.
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

# As versoes _v nao levam o \n final: quem monta os dois boxes lado a lado
# precisa das bordas como texto, nao como linha impressa.
box_top_v() { # <destino> <largura> <titulo>
  local __w="$2" __title="$3" __pre __l __r
  __pre=$(( (__w - ${#__title} - 2) / 2 ))
  repeat_v __l '─' "$__pre"
  repeat_v __r '─' $(( __w - __pre - ${#__title} - 2 ))
  printf -v "$1" '%s┌%s %s %s┐%s' "$C_CYAN" "$__l" "$__title" "$__r" "$C_RESET"
}

box_bottom_v() { # <destino> <largura>
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

# Todas as tasks do run, nao so as da fase corrente: a barra mede o progresso
# do trabalho inteiro, do mesmo jeito que a de fases.
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
    running)  printf '%s▶ Em execução%s' "$C_YELLOW" "$C_RESET" ;;
    waiting)  printf '%s⏸ Aguardando reset de limite%s' "$C_YELLOW" "$C_RESET" ;;
    finished) printf '%s✓ Concluído%s' "$C_GREEN" "$C_RESET" ;;
    failed)   printf '%s✗ Falhou%s' "$C_RED" "$C_RESET" ;;
    *)        printf '%s· %s%s' "$C_GREY" "${META[status]:-?}" "$C_RESET" ;;
  esac
}

run_status_plain() {
  case "${META[status]:-running}" in
    running)  printf '▶ Em execução' ;;
    waiting)  printf '⏸ Aguardando reset de limite' ;;
    finished) printf '✓ Concluído' ;;
    failed)   printf '✗ Falhou' ;;
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
  printf '%sProjeto:%s %s  %sEngine:%s %s  %sStatus:%s %s\n' \
    "$C_CYAN" "$C_RESET" "$(pad "${META[project]:-?}" $((col - 10)))" \
    "$C_CYAN" "$C_RESET" "$(pad "${META[engine]:-?}" $((col - 9)))" \
    "$C_CYAN" "$C_RESET" "$(run_status_label)"
  printf '%sDuração:%s %s  %sRun:%s %s  %sPID:%s %s\n\n' \
    "$C_CYAN" "$C_RESET" "$(pad "$(fmt_duration "$elapsed")" $((col - 10)))" \
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

  printf -v l1 'Fases  %s  [%s]  %s' "$n_ph" "$b_ph" "$p_ph"
  printf -v l2 'Tasks  %s  [%s]  %s' "$n_tk" "$b_tk" "$p_tk"
  L+=("$l1"); printf -v tmp 'Fases  %s  [%s]  %s' "$n_ph" "$blank" "$p_ph"; LP+=("$tmp")
  L+=("$l2"); printf -v tmp 'Tasks  %s  [%s]  %s' "$n_tk" "$blank" "$p_tk"; LP+=("$tmp")
  L+=(""); LP+=("")
  printf -v tmp '%sTeste:%s %s' "$C_GREY" "$C_RESET" "${META[test_cmd]:-—}"; L+=("$tmp")
  printf -v tmp 'Teste: %s' "${META[test_cmd]:-—}"; LP+=("$tmp")

  local cur="${META[phase_cur]:-}"
  local fase_txt="—"
  [ -n "$cur" ] && fase_txt="$cur · ${PH_TITLE[$cur]:-}"

  local cyc="${META[cycle]:-—}/${META[cycle_max]:-—}"
  printf -v tmp '%sFase:%s      %s' "$C_CYAN" "$C_RESET" "$fase_txt"; R+=("$tmp")
  printf -v tmp 'Fase:      %s' "$fase_txt"; RP+=("$tmp")
  printf -v tmp '%sCiclo:%s     %s    %sGate:%s %s' \
    "$C_CYAN" "$C_RESET" "$cyc" "$C_CYAN" "$C_RESET" "${META[gate]:-—}"; R+=("$tmp")
  printf -v tmp 'Ciclo:     %s    Gate: %s' "$cyc" "${META[gate]:-—}"; RP+=("$tmp")
  printf -v tmp '%sAtividade:%s %s' "$C_CYAN" "$C_RESET" "${META[activity]:-—}"; R+=("$tmp")
  printf -v tmp 'Atividade: %s' "${META[activity]:-—}"; RP+=("$tmp")
  printf -v tmp '%sÚltimo erro:%s %s%s%s' \
    "$C_CYAN" "$C_RESET" "$C_RED" "${META[last_error]:-—}" "$C_RESET"; R+=("$tmp")
  printf -v tmp 'Último erro: %s' "${META[last_error]:-—}"; RP+=("$tmp")

  # Cabecalhos e rodapes dos dois boxes, lado a lado
  local top_l top_r bot_l bot_r
  box_top_v top_l "$li" "PROGRESSO"; box_top_v top_r "$ri" "TRABALHO ATUAL"
  box_bottom_v bot_l "$li";          box_bottom_v bot_r "$ri"
  printf '%s %s\n' "$top_l" "$top_r"

  local i n=${#L[@]}
  [ "${#R[@]}" -gt "$n" ] && n=${#R[@]}
  for ((i=0; i<n; i++)); do
    local lc="${L[$i]:-}" lp="${LP[$i]:-}" rc="${R[$i]:-}" rp="${RP[$i]:-}"
    # trunca pelo texto sem cor e reaplica o conteudo colorido
    if [ "${#lp}" -gt $(( li - 2 )) ]; then pad_v lc "$lp" $(( li - 2 )); lp="$lc"; fi
    if [ "${#rp}" -gt $(( ri - 2 )) ]; then pad_v rc "$rp" $(( ri - 2 )); rp="$rc"; fi
    printf '%s│%s %s%*s %s│%s %s│%s %s%*s %s│%s\n' \
      "$C_CYAN" "$C_RESET" "$lc" $(( li - 2 - ${#lp} )) '' "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$rc" $(( ri - 2 - ${#rp} )) '' "$C_CYAN" "$C_RESET"
  done
  printf '%s %s\n' "$bot_l" "$bot_r"
}

# Linhas da tabela montadas uma vez por frame, antes de saber o recorte: quem
# rola escolhe o intervalo, nao remonta o conteudo.
declare -a ROWS ROW_HL
declare -A PHASE_ROW PHASE_END
RUN_ROW=-1

build_rows() {
  ROWS=(); ROW_HL=(); PHASE_ROW=(); PHASE_END=(); RUN_ROW=-1

  # c_gates=19 cabe "G0 ✓ G1 ✓ G2 ✓ G3 ✓" inteiro; c_status=14 cabe o rotulo
  # mais longo ("▶ Em execução"). Encolher qualquer um deles corta a informacao.
  COL_ID=4; COL_STATUS=14; COL_TRY=9; COL_GATES=19
  COL_NAME=$(( W - COL_ID - COL_STATUS - COL_TRY - COL_GATES - 16 ))
  [ "$COL_NAME" -lt 16 ] && COL_NAME=16

  local V="${C_CYAN}│${C_RESET}"

  # Os tracinhos de tentativa e gates das linhas de task nao dependem da fase:
  # padeia uma vez por frame em vez de uma vez por linha.
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

    # a linha guarda tudo menos a borda direita: ali vai a barra de rolagem
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
        # a task em execucao e a ancora preferida: e o que o usuario quer ver
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

# Recorte automatico: mostra o bloco da fase corrente inteiro quando ele cabe;
# quando nao cabe, centra a task em execucao.
follow_offset() {
  local cur="${META[phase_cur]:-}"
  if [ -z "$cur" ] || [ -z "${PHASE_ROW[$cur]:-}" ]; then
    # sem fase corrente (run terminado, por exemplo): mantem o comeco a vista
    OFF=0
    [ "${META[status]:-running}" = "failed" ] && [ "$RUN_ROW" -ge 0 ] \
      && OFF=$(( RUN_ROW - VIS / 2 ))
    clamp_off
    return
  fi
  local s="${PHASE_ROW[$cur]}" e="${PHASE_END[$cur]}"
  if [ $(( e - s + 1 )) -le "$VIS" ]; then
    OFF=$(( s - 1 ))   # uma linha de contexto acima da fase
  elif [ "$RUN_ROW" -ge "$s" ] && [ "$RUN_ROW" -le "$e" ]; then
    OFF=$(( RUN_ROW - VIS / 2 ))
  else
    OFF=$s
  fi
  clamp_off
}

# Define HEAD, VIS, TOTAL, MAX_OFF, FOOTER e OFF para o frame. Roda no shell
# principal (nao em subshell) porque as teclas precisam do VIS e do MAX_OFF
# calculados aqui para paginar.
build_frame() {
  calc_width
  calc_height
  build_rows

  HEAD=$(draw_header; draw_panels)
  TOTAL=${#ROWS[@]}

  local head_n note_n=0 avail
  # `| wc -l` custa um fork, mas contar em bash puro sai MAIS caro: a
  # substituicao ${HEAD//[^$'\n']/} avalia a classe caractere a caractere e
  # mediu 44ms contra 2ms do wc num HEAD de 2KB. Fork nao e sempre o vilao.
  head_n=$(printf '%s\n' "$HEAD" | wc -l)
  [ -n "${META[note]:-}" ] && note_n=2

  # 4 = topo, cabecalho de coluna, separador e rodape da tabela.
  # 1 = folga da ultima linha, que o terminal usaria para rolar o frame.
  avail=$(( H - head_n - 4 - note_n - 1 ))
  [ "$avail" -lt 3 ] && avail=3

  # --once e um dump: so recorta se a altura foi fixada de proposito.
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

# Borda direita da linha visivel i: vira barra de rolagem quando ha corte.
# Chamada uma vez por linha desenhada, entao a versao _v (sem subshell) importa:
# era um fork por linha da tabela, a cada frame e a cada tecla de rolagem.
scroll_edge_v() { # <destino> <indice da linha>
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
  pad_v h_name   'Fase / Task' "$COL_NAME"
  pad_v h_status 'Status'      "$COL_STATUS"
  pad_v h_try    'Tentativa'   "$COL_TRY"
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
      # C_RESET (\033[0m) zera tambem o fundo. Sem reinjetar o realce depois de
      # cada reset, o destaque da linha em execucao morria no primeiro separador
      # e so pintava um caractere — o efeito util (achar a linha viva de
      # relance) desaparecia justamente na tabela cheia.
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
    mode="seguindo a fase atual"
  else
    mode="rolagem manual"
  fi
  if [ -n "${KEY_FD:-}" ]; then
    help=" · ↑↓ PgUp/PgDn rolam · f segue a fase"
    $EMBEDDED || help+=" · q sai"
  fi
  printf '%s  ▲ %d acima · ▼ %d abaixo · %s%s%s\n' \
    "$C_GREY" "$above" "$below" "$mode" "$help" "$C_RESET"
}

render() {
  printf '%s\n' "$HEAD"
  draw_table
  if [ -n "${META[note]:-}" ]; then
    printf '\n%s%s%s\n' "$C_YELLOW" "${META[note]}" "$C_RESET"
  fi
}

# clamp_lines <destino> <texto> <max> — corta o texto nas primeiras <max> linhas
# e sem \n no fim. Rede de seguranca do desenho: um frame com mais linhas que a
# tela faz o terminal ROLAR, e a partir dai o \033[H passa a escrever numa tela
# deslocada — o topo do quadro anterior fica para tras e nenhum \033[K alcanca,
# so o \033[2J do redimensionamento. Acontece de verdade em terminal baixo: o
# piso de 3 linhas de tabela mantem o frame em 20 linhas mesmo numa tela de 12.
# Cortar o rodape e feio; rolar corrompe o painel inteiro e nao se recupera.
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

# Teclado pelo /dev/tty, nao pelo stdin: com --embedded o painel e iniciado com
# `&` pelo ralph, que roda sem job control — o filho fica no mesmo grupo de
# processo em foreground, entao ler o terminal e permitido (nao ha SIGTTIN). O
# ralph ja da `< /dev/null` no engine e nos testes e le o manifest pelo fd 3,
# entao ninguem mais disputa essas teclas.
KEY_FD=""

open_keyboard() {
  $ONCE && return 0
  exec 3< /dev/tty 2>/dev/null && KEY_FD=3
  return 0
}

scroll_by() { # <delta em linhas>
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
    # embutido no ralph o painel e dono da tela alternativa que o ralph abriu:
    # sair aqui deixaria a tela congelada com o run ainda em andamento.
    q|Q)   $EMBEDDED || QUIT=true ;;
  esac
}

# Teto de teclas absorvidas num tick. Segurar uma tecla ou colar texto pode
# encher o buffer; alem disso desenha o que ja acumulou e volta na proxima volta,
# para o painel nao parar de atualizar enquanto drena.
DRAIN_MAX=64

# Espera INTERVAL segundos, mas acorda na hora se o usuario apertar algo — e o
# que faz a rolagem responder sem esperar o proximo frame.
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
    # Drena o resto do buffer antes de devolver o controle ao loop. Sem isso o
    # autorepeat do terminal enfileirava dezenas de eventos e cada um pagava um
    # frame inteiro: a rolagem chegava ao destino muito depois da tecla soltar.
    # Absorve tudo que ja esta pendente e deixa o loop desenhar UM frame com o
    # deslocamento final. O -t curto e o que distingue "buffer vazio" de "ainda
    # chegando"; `read -t 0` nao serve, porque testa sem consumir o byte.
    local drained=0
    while [ "$drained" -lt "$DRAIN_MAX" ] \
      && IFS= read -rsn1 -t 0.01 -u "$KEY_FD" c; do
      handle_key "$c"
      drained=$(( drained + 1 ))
    done
  elif [ "$rc" -le 128 ] && [ ! -t "$KEY_FD" ]; then
    # Nao foi timeout e o fd nao e mais um terminal: o tty sumiu de verdade.
    # (Um sinal — SIGWINCH ao redimensionar — tambem interrompe o read; ali o
    # fd continua sendo tty e o teclado precisa continuar de pe.)
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
      echo "Nenhum estado em $RUN_STATE — o ralph ja rodou neste repo?" >&2
      exit 1
    fi
    build_frame
    render
    exit 0
  fi

  open_keyboard

  # Redimensionar reflui o painel inteiro: as linhas do frame anterior, que o
  # terminal quebrou na largura antiga, sobram na tela e embaralham o topo.
  # \033[H + \033[J so limpam do cursor para baixo — o que ficou acima
  # permanece. Numa mudanca de tamanho, limpa a tela toda antes de redesenhar.
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
      # Nunca imprime mais linhas do que a tela tem: ver clamp_lines.
      clamp_lines frame "$frame" "$H"
      # \033[K no INICIO de cada linha: \033[J so limpa do fim do frame para
      # baixo, entao uma linha nova mais curta que a antiga deixava o rabo dela
      # na tela e uma linha nova EM BRANCO nao apagava nada. O cabecalho tem tres
      # linhas em branco e o "RALPH" e curto: eram justamente as quatro posicoes
      # onde o quadro anterior aparecia por baixo do novo, e o lixo ficava ali
      # ate alguem redimensionar a janela.
      # No inicio e nao no fim da linha: W e a largura cheia do terminal, e uma
      # linha de exatamente W colunas deixa o cursor com wrap pendente na ultima
      # coluna — um \033[K ali apagaria o proprio caractere que acabou de sair.
      printf '\033[H%s\033[J' $'\033[K'"${frame//$'\n'/$'\n\033[K'}"
      case "${META[status]:-running}" in
        finished|failed)
          $EMBEDDED && break
          ;;
      esac
    else
      printf '\033[H\033[K%sAguardando o ralph iniciar (%s)…%s\033[J\n' "$C_GREY" "$RUN_STATE" "$C_RESET"
    fi
    wait_tick
    $QUIT && break
  done
}

# Mesma convencao do ralph.sh: RALPH_LIB_ONLY=1 carrega as funcoes sem desenhar,
# para a suite testar unidades (ex: clamp_lines) sem precisar de um terminal.
[ "${RALPH_LIB_ONLY:-0}" = "1" ] || main
