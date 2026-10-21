#!/bin/sh
# preToolUse guard for the orchestrator: the task tool may only launch cantrip agents.
payload=$(cat)
compact=$(printf '%s' "$payload" | tr -d '\n\r' | sed 's/[[:space:]]*:[[:space:]]*/:/g')
case "$compact" in
  *'"toolName":"task"'*|*'"tool_name":"task"'*|*'"tool_name":"Task"'*|*'"tool_name":"Agent"'*|*'"name":"task"'*) ;;
  *) exit 0 ;;
esac
types=$(printf '%s' "$compact" | grep -o '"agent_type":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/')
[ -z "$types" ] && types="(none)"
for t in $types; do
  case "$t" in
    explorer|planner|worker|reviewer) ;;
    *)
      printf '{"permissionDecision":"deny","permissionDecisionReason":"Forbidden agent_type %s. The orchestrator may only delegate to cantrip agents: explorer, planner, worker, reviewer. Built-in and default agents are not allowed. Delegate to the matching cantrip role; run verification commands with your own shell tool."}\n' "'$t'"
      exit 0 ;;
  esac
done
exit 0
