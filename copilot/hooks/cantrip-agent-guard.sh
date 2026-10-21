#!/bin/sh
# preToolUse guard for the cantrip orchestrator.
# - Every agent in the session: `task` may only launch cantrip agents.
# - The orchestrator itself (root session): no file edits and no mutating shell commands; delegate them to a worker.
payload=$(cat)
compact=$(printf '%s' "$payload" | tr -d '\n\r' | sed 's/"[[:space:]]*:[[:space:]]*/":/g')

deny() {
  reason=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"permissionDecision":"deny","permissionDecisionReason":"%s"}\n' "$reason"
  exit 0
}

names=$(printf '%s' "$compact" | grep -oE '"(toolName|tool_name|name)":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/')
[ -z "$names" ] && exit 0

has_name() { printf '%s\n' "$names" | grep -xE "$1" >/dev/null; }

if has_name 'task|Task|Agent'; then
  types=$(printf '%s' "$compact" | grep -oE '"agent_type":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/')
  [ -z "$types" ] && types="(none)"
  for t in $types; do
    case "$t" in
      explorer|planner|worker|reviewer) ;;
      *) deny "Forbidden agent_type '$t'. The orchestrator may only delegate to cantrip agents: explorer, planner, worker, reviewer. Built-in and default agents are not allowed. Delegate to the matching cantrip role; run verification commands with your own shell tool." ;;
    esac
  done
fi

# Only root sessions have a session-state directory; subagent calls carry their own agent id.
sid=$(printf '%s' "$compact" | grep -oE '"(sessionId|session_id)":"[^"]*"' | head -n 1 | sed 's/.*:"\(.*\)"/\1/')
home_dir=${COPILOT_HOME:-$HOME/.copilot}
[ -n "$sid" ] && [ -d "$home_dir/session-state/$sid" ] || exit 0

if has_name 'edit|create|apply_patch|str_replace_editor|str_replace|write|multi_edit|Edit|Write|MultiEdit|NotebookEdit'; then
  deny "The orchestrator does not edit files. Delegate this change to a worker with a self-contained assignment (objective, files, governing ADRs, acceptance criteria)."
fi

if has_name 'view|grep|glob|rg|Read|Grep|Glob'; then
  budget=${CANTRIP_READ_BUDGET:-30}
  state_dir=${CANTRIP_STATE_DIR:-${TMPDIR:-/tmp}/cantrip-guard}
  mkdir -p "$state_dir"
  reads=$(cat "$state_dir/$sid.reads" 2>/dev/null || echo 0)
  reads=$((reads + 1))
  printf '%s' "$reads" > "$state_dir/$sid.reads"
  if [ "$reads" -gt "$budget" ]; then
    deny "Read budget exhausted ($budget view/grep/glob calls this session). Reading code is the explorer's job: delegate the question to an explorer, or ask the worker to report the hunk you need. Use git diff --stat to see what changed."
  fi
  exit 0
fi

has_name 'powershell|bash|write_powershell|write_bash|Bash' || exit 0

text=$(printf '%s' "$compact" | grep -oE '"(command|input)":"([^"\\]|\\.)*"' | sed 's/^"[a-z]*":"//; s/"$//' \
  | sed 's/\\u003[eE]/>/g; s/\\u003[cC]/</g; s/\\u0026/\&/g; s/\\u0027/'"'"'/g; s/\\n/\
/g; s/\\"/"/g; s/\\\\/\\/g')

matches() { printf '%s\n' "$text" | grep -iE "$1" >/dev/null; }

mutating=0
matches '(^|[^a-z])git[^;|&]*[[:space:]](commit|merge|rebase|cherry-pick|revert|push|pull|reset|restore|checkout|switch|stash|am|apply|add|rm|mv|clean|tag|init|clone)([^a-z-]|$)' && mutating=1
matches '(^|[^a-z])git[^;|&]*[[:space:]]worktree[[:space:]]+(add|remove|move|prune)' && mutating=1
matches '(^|[^a-z])git[^;|&]*[[:space:]]branch[[:space:]]+(-[dDmMcCf]|--(delete|move|copy|force))' && mutating=1
matches '(^|[^a-z])gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit|merge|close|reopen|comment|review|ready|delete|lock|transfer|checkout)' && mutating=1
matches '(^|[^a-z])gh[[:space:]]+(release|repo|label|workflow|run|secret|variable)[[:space:]]+(create|delete|edit|upload|enable|disable|run|rerun|cancel|set|clone|fork)' && mutating=1
matches '(^|[^a-z])gh[[:space:]]+api[^;|]*(-X|--method)[[:space:]]*(POST|PUT|PATCH|DELETE)' && mutating=1
matches '(Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item|Rename-Item|Clear-Content|Export-Csv|Export-Clixml|Expand-Archive|Compress-Archive|Set-ItemProperty|-OutFile)' && mutating=1
matches '(^|[;&|(])[[:space:]]*(rm|mv|cp|touch|mkdir|rmdir|tee|truncate|ln|del|copy|move|ren|md|rd)[[:space:]]' && mutating=1
matches '(^|[^a-z])(sed[[:space:]]+-i|perl[[:space:]]+-[a-z]*i)' && mutating=1
matches '[[:space:]]--(fix|write)([^a-z-]|$)' && mutating=1
matches '(^|[^a-z])((uv[[:space:]]+(add|remove|lock))|(uv[[:space:]]+pip[[:space:]]+install)|(pip3?[[:space:]]+install)|(npm[[:space:]]+(install|i|ci|uninstall|update))|(pnpm[[:space:]]+(add|install|remove))|(yarn[[:space:]]+(add|install|remove))|(bun[[:space:]]+(add|install|remove)))([^a-z]|$)' && mutating=1
matches '(^|[^a-z])archgate[^;|]*[[:space:]](init|adr[[:space:]]+(create|update|import))' && mutating=1
if matches '(^|[^a-z])ruff[[:space:]]+format' && ! matches 'ruff[[:space:]]+format[^;|]*--(check|diff)'; then mutating=1; fi
if matches '(^|[^a-z])black[[:space:]]' && ! matches 'black[^;|]*--check'; then mutating=1; fi
# Output redirection to a file; redirections to null devices or other streams are fine.
stripped=$(printf '%s\n' "$text" | sed -E 's/[0-9&*]?>>?[[:space:]]*(&[0-9]|\/dev\/null|\$null|[Nn][Uu][Ll])//g; s/(=|-)>//g')
printf '%s\n' "$stripped" | grep -E '>' >/dev/null && mutating=1

if [ "$mutating" -eq 1 ]; then
  deny "The orchestrator does not run commands that change the repository or environment. Delegate it to a worker. Your own shell use is limited to Archgate preflight and checks, read-only inspection (git status/diff/log/show), and verification in check mode."
fi
exit 0
