#!/usr/bin/env bash
#
# engine_adapter.sh
# Isolamento do driver de execução para orquestração de CLIs de IA.

detect_ai_engine() {
  # 1. Verifica variáveis de ambiente
  if [ -n "${AGY_SESSION_ID:-}" ] || [ -n "${ANTIGRAVITY_ENV:-}" ]; then
    echo "agy"
    return 0
  fi
  if [ -n "${CLAUDECODE_SESSION:-}" ] || [ -n "${CLAUDE_ENV:-}" ]; then
    echo "claude"
    return 0
  fi

  # 2. Fallback command -v
  if command -v agy &> /dev/null; then
    echo "agy"
    return 0
  fi
  if command -v claude &> /dev/null; then
    echo "claude"
    return 0
  fi
  if command -v codex &> /dev/null; then
    echo "codex"
    return 0
  fi

  # Default
  echo "claude"
}

# run_ai_prompt <engine> <mode: impl|verify> <prompt_file> <log_file> [extra_args...]
run_ai_prompt() {
  local engine="$1"
  local mode="$2"
  local prompt_file="$3"
  local log_file="$4"
  shift 4
  local extra_args=("$@")

  local rc=0

  case "$engine" in
    agy)
      # Flags para headless/autônomo em Antigravity
      if [[ "$mode" == "verify" ]]; then
        agy exec --sandbox read-only "${extra_args[@]}" - < "$prompt_file" 2>&1 | tee "$log_file" || rc=$?
      else
        agy exec --sandbox danger-full-access "${extra_args[@]}" - < "$prompt_file" 2>&1 | tee "$log_file" || rc=$?
      fi
      ;;
    codex)
      if [[ "$mode" == "verify" ]]; then
        codex exec --sandbox read-only "${extra_args[@]}" - < "$prompt_file" 2>&1 | tee "$log_file" || rc=$?
      else
        codex exec --sandbox danger-full-access - < "$prompt_file" 2>&1 | tee "$log_file" || rc=$?
      fi
      ;;
    claude|*)
      # < /dev/null: claude -p le stdin quando nao e TTY. Sem o redirect ele
      # consome o stream de quem chamou (ex: o manifest do loop de fases).
      if [[ "$mode" == "verify" ]]; then
        env -u CLAUDECODE claude --dangerously-skip-permissions \
          "${extra_args[@]}" \
          -p "$(cat "$prompt_file")" \
          --allowedTools "Read,Glob,Grep" \
          --output-format text < /dev/null 2>&1 | tee "$log_file" || rc=$?
      else
        # JSON: o exit code do CLI e sinal fraco; o gate 0 le is_error.
        env -u CLAUDECODE claude --dangerously-skip-permissions \
          "${extra_args[@]}" \
          -p "$(cat "$prompt_file")" \
          --output-format json < /dev/null 2>&1 | tee "$log_file" || rc=$?
      fi
      ;;
  esac

  return "$rc"
}
