#!/usr/bin/env bash

# Health check para a Fase 4: Validação End-to-End do Plugin Ils-Harness

echo "========================================"
echo "      ILS-HARNESS HEALTH CHECK          "
echo "========================================"
echo ""

# 1. Check de Symlinks
echo "1. Verificando integridade dos Symlinks (Dual-Manifest)..."
cd "$(dirname "$0")/.."
for skill in skills/*/SKILL.md; do
  if [ -L "$skill" ]; then
    target=$(readlink -f "$skill")
    if [ -f "$target" ]; then
      echo "  [OK] Symlink '$skill' -> válido"
    else
      echo "  [ERRO] Symlink '$skill' quebrado! Alvo: $target"
    fi
  else
    echo "  [AVISO] '$skill' não é um symlink."
  fi
done
echo ""

# 2. Check de Manifesto
echo "2. Verificando Manifestos e Frontmatter..."
if [ -f "plugin.json" ]; then
  if grep -q '"name"' plugin.json; then
    echo "  [OK] plugin.json na raiz presente e válido (Antigravity)."
  else
    echo "  [ERRO] plugin.json não tem a chave 'name'."
  fi
else
  echo "  [ERRO] plugin.json ausente na raiz."
fi

if [ -f ".claude-plugin/plugin.json" ]; then
  echo "  [OK] .claude-plugin/plugin.json presente e válido (Claude)."
else
  echo "  [ERRO] .claude-plugin/plugin.json ausente."
fi

for cmd in commands/*.md; do
  if head -n 10 "$cmd" | grep -q "^name:"; then
    echo "  [OK] '$cmd' possui chave 'name:' no frontmatter."
  else
    echo "  [ERRO] '$cmd' não possui 'name:' no frontmatter!"
  fi
done
echo ""

# 3. Check de Motor (Simulação de Ambiente)
echo "3. Simulando Roteamento do Motor (engine_adapter.sh)..."
source scripts/engine_adapter.sh

export AGY_SESSION_ID=1
export CLAUDECODE_SESSION=""
export ANTIGRAVITY_ENV=""
export CLAUDE_ENV=""
engine1=$(detect_ai_engine)
if [ "$engine1" == "agy" ]; then
  echo "  [OK] Simulação AGY_SESSION_ID roteou para: agy"
else
  echo "  [ERRO] Roteamento falhou, detectou: $engine1"
fi

export AGY_SESSION_ID=""
export CLAUDECODE_SESSION=1
engine2=$(detect_ai_engine)
if [ "$engine2" == "claude" ]; then
  echo "  [OK] Simulação CLAUDECODE_SESSION roteou para: claude"
else
  echo "  [ERRO] Roteamento falhou, detectou: $engine2"
fi
echo ""

# 4. Check de Binários no PATH
echo "4. Verificando CLIs no PATH..."
if command -v agy &> /dev/null; then
  echo "  [OK] 'agy' (Antigravity CLI) encontrado."
else
  echo "  [INFO] 'agy' não encontrado no PATH atual."
fi

if command -v claude &> /dev/null; then
  echo "  [OK] 'claude' (Claude Code) encontrado."
else
  echo "  [INFO] 'claude' não encontrado no PATH atual."
fi

if command -v codex &> /dev/null; then
  echo "  [OK] 'codex' (Codex CLI) encontrado."
else
  echo "  [INFO] 'codex' não encontrado no PATH atual."
fi
echo ""

echo "========================================"
echo "    HEALTH CHECK CONCLUÍDO COM SUCESSO  "
echo "========================================"
