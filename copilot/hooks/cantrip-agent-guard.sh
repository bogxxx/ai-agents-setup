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

# JSON-decode the command; an escaped backslash is parked on \001 so that "\\n" or "C:\\repo" keep their backslash.
bs=$(printf '\001')
tab=$(printf '\t')
text=$(printf '%s' "$compact" | grep -oE '"(command|input)":"([^"\\]|\\.)*"' | sed 's/^"[a-z]*":"//; s/"$//' \
  | sed 's/\\\\/'"$bs"'/g; s/\\u003[eE]/>/g; s/\\u003[cC]/</g; s/\\u0026/\&/g; s/\\u0027/'"'"'/g; s/\\r//g; s/\\t/'"$tab"'/g; s/\\n/\
/g; s/\\"/"/g; s/'"$bs"'/\\/g')

# Data that never runs is not scanned: the body of a quoted heredoc piped into role-picker (spawn/ask),
# and a quoted heredoc written to "$BB_THREAD_STORAGE/<name>.md|txt". Bash forms apply to the bash tool,
# PowerShell here-strings to the powershell tool. Headers and every other line are scanned; anything
# that does not parse exactly (or follows an unbalanced quote, paren, continuation or other heredoc) is scanned.
sh_forms=0; ps_forms=0
if has_name 'bash|Bash' && ! has_name 'powershell|write_powershell|write_bash'; then sh_forms=1; fi
if has_name 'powershell' && ! has_name 'bash|Bash|write_bash|write_powershell'; then ps_forms=1; fi
scan_awk='
function flush(  i) { for (i = 1; i <= n; i++) print buf[i]; n = 0 }
function count(s, re,  t) { t = s; return gsub(re, "", t) }
# Only a bb role-picker spawn at command position (line start, or after a semicolon or the do keyword), with no quote before it on
# the line and no earlier ambiguity, may have its thread-storage assignment file replaced by a neutral token.
function strip(   l, pre) {
  if (bad) return
  l = tolower($0)
  if (!match(l, spawn_re)) return
  pre = substr(l, 1, RSTART - 1)
  if (pre ~ noq) return
  if (!match(l, arg_re)) return
  $0 = substr($0, 1, RSTART - 1) "\"ASSIGNMENT\"" substr($0, RSTART + RLENGTH)
}
function taints(s) {
  if (s ~ /<</ || s ~ /\\/ || s ~ /`/) return 1
  if (count(s, q) % 2 || count(s, "\"") % 2 || count(s, "`") % 2) return 1
  return count(s, "\\(") != count(s, "\\)")
}
BEGIN {
  q = "\047"
  tagre = "<<[ \t]*" q "[A-Za-z_][A-Za-z0-9_]*" q "[ \t]*$"
  args = "([ \t][^;&|<>$`()#" q "\"\\\\]*)?$"
  rp = "bb[ \t]+plugin[ \t]+run[ \t]+role-picker[ \t]+(spawn|ask)" args
  e1sh = "^[ \t]*" rp
  e3sh = "^[ \t]*cat[ \t]+>[ \t]*\"\\$BB_THREAD_STORAGE/[A-Za-z0-9_][A-Za-z0-9._-]*\\.(md|txt)\"[ \t]*$"
  e1ps = "^\\|[ \t]*" rp
  bet = "[^;&|$`()\"" q "]*"
  spawn_re = "(^|;)[ \t]*(do[ \t]+)?bb[ \t]+plugin[ \t]+run[ \t]+role-picker[ \t]+spawn" bet "--assignment-file[ \t]+\"\\$\\{?(env:)?bb_thread_storage\\}?[\\\\/][a-z0-9_$][a-z0-9._$-]*\\.(md|txt)\""
  arg_re = "\"\\$\\{?(env:)?bb_thread_storage\\}?[\\\\/][a-z0-9_$][a-z0-9._$-]*\\.(md|txt)\""
  noq = "[\"" q "`(]"
  e3ps = "^\\|[ \t]*set-content[ \t]+-literalpath[ \t]+\"\\$env:bb_thread_storage\\\\[a-z0-9_][a-z0-9._-]*\\.(md|txt)\"([ \t]+-encoding[ \t]+utf8)?[ \t]*$"
}
st == 1 {
  if ($0 == tag) { st = 0; n = 0 } else buf[++n] = $0
  next
}
st == 2 {
  if (substr($0, 1, 2) != q "@") { buf[++n] = $0; next }
  st = 0
  rest = tolower(substr($0, 3)); sub(/^[ \t]+/, "", rest)
  if (rest ~ e1ps) { n = 0; print substr(rest, 2); next }
  if (store && rest ~ e3ps) { n = 0; next }
  flush(); print; bad = 1; next
}
{
  if (!bad && ps) {
    s = $0; gsub(/^[ \t]+|[ \t]+$/, "", s)
    if (s == "@" q) { n = 0; buf[++n] = $0; st = 2; next }
  }
  if (!bad && sh && match($0, tagre)) {
    head = substr($0, 1, RSTART - 1)
    tag = substr($0, RSTART + 2); sub(/^[ \t]*/, "", tag); tag = substr(tag, 2); sub(q "[ \t]*$", "", tag)
    if (head ~ e1sh) { print head; n = 0; st = 1; next }
    if (store && head ~ e3sh && head !~ /\.\./) { n = 0; buf[++n] = $0; st = 1; next }
  }
  strip()
  if (taints($0)) bad = 1
  print
}
END { if (st) flush() }
'
scan=$(printf '%s\n' "$text" | awk -v sh="$sh_forms" -v ps="$ps_forms" -v store="${BB_THREAD_STORAGE:+1}" "$scan_awk") \
  || deny "The guard could not parse this command, so it cannot tell that it is safe. Run it as a plain command."

matches() { printf '%s\n' "$scan" | grep -iE "$1" >/dev/null; }

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
stripped=$(printf '%s\n' "$scan" | sed -E 's/[0-9&*]?>>?[[:space:]]*(&[0-9]|\/dev\/null|\$null|[Nn][Uu][Ll])//g; s/(=|-)>//g')
printf '%s\n' "$stripped" | grep -E '>' >/dev/null && mutating=1
# Thread storage is writable through the heredoc form above, so it may only be read: never redefined or executed.
printf '%s\n' "$scan" | grep -iE 'bb_thread_storage|thread-storage' >/dev/null && mutating=1
# Aliases, functions, PATH changes and exported functions could rebind bb, cat or sh to something else.
matches '(^|[^a-z])(alias|function|hash)[[:space:]]' && mutating=1
matches '(^|[^a-z])export[[:space:]]+-f' && mutating=1
matches '\([[:space:]]*\)' && mutating=1
# Execution of positional parameters or of a value is not provable: deny it.
matches '(^|[^a-z0-9_-])(sh|bash|zsh|dash|ksh|source|eval|exec|python3?|node|perl|ruby|pwsh|powershell|iex|invoke-expression)[[:space:]]+"?\$[0-9@*{]' && mutating=1
matches '(^|[;&|(])[[:space:]]*\.[[:space:]]+"?\$[0-9@*{]' && mutating=1
matches '(^|[;&|(])[[:space:]]*"?\$[0-9@*{]' && mutating=1
matches '(^|[;|(])[[:space:]]*&[[:space:]]+"?\$' && mutating=1
matches '(^|[ ;&|(])PATH=' && mutating=1
matches '\$env:PATH[[:space:]]*=' && mutating=1
matches '\$env:bb_thread_storage[[:space:]]*=' && mutating=1
matches '(^|[^a-z0-9_-])(sh|bash|zsh|dash|ksh|source|eval|exec|python3?|node|perl|ruby|pwsh|powershell|iex|invoke-expression)[[:space:]][^;|&]*bb_thread_storage' && mutating=1
matches '(^|[;&|(])[[:space:]]*\.[[:space:]]+[^;|&]*bb_thread_storage' && mutating=1
matches '(^|[;&|(])[[:space:]]*(&[[:space:]]*)?"?\$\{?(env:)?bb_thread_storage' && mutating=1
matches 'bb_thread_storage[^;&]*\|[[:space:]]*(sh|bash|zsh|dash|ksh|pwsh|powershell|iex|invoke-expression)([^a-z]|$)' && mutating=1

if [ "$mutating" -eq 1 ]; then
  hint='To hand over an assignment, write it with cat > "$BB_THREAD_STORAGE/<name>.md" <<'"'"'EOF'"'"', the text, then EOF on its own line, then run bb plugin run role-picker spawn <role> --assignment-file "$BB_THREAD_STORAGE/<name>.md".'
  deny "The orchestrator does not run commands that change the repository or environment. Delegate it to a worker. Your own shell use is limited to Archgate preflight and checks, read-only inspection (git status/diff/log/show), and verification in check mode. $hint"
fi
exit 0
