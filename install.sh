#!/bin/sh
# Installs the agent setup into the user-level Copilot and Cursor config dirs.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HOME/.copilot/agents" "$HOME/.cursor/agents" "$HOME/.cursor/hooks"
cp "$here"/copilot/agents/*.agent.md "$HOME/.copilot/agents/"
cp "$here"/copilot/copilot-instructions.md "$HOME/.copilot/"
mkdir -p "$HOME/.copilot/cantrip"
cp "$here"/copilot/hooks/cantrip-agent-guard.ps1 "$here"/copilot/hooks/cantrip-agent-guard.sh "$here"/copilot/hooks/archgate-stop-gate.mjs "$HOME/.copilot/cantrip/"
cp "$here"/cursor/agents/*.md "$HOME/.cursor/agents/"
cp "$here"/cursor/hooks/archgate-check.sh "$HOME/.cursor/hooks/"
[ -f "$HOME/.cursor/hooks.json" ] && echo "~/.cursor/hooks.json exists; merge cursor/hooks.json manually." \
  || sed "s#/Users/bohdan.krechko#$HOME#" "$here/cursor/hooks.json" > "$HOME/.cursor/hooks.json"
echo done
