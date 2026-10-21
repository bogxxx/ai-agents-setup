# AI agents setup (GitHub Copilot + Cursor)

A role-based multi-agent setup ("cantrip") with Archgate ADR governance.

## Roles
| Role | Copilot (`~/.copilot/agents/`) | Cursor (`~/.cursor/agents/`) |
|---|---|---|
| Orchestrator / goal owner | `orchestrator.agent.md` | `cantrip-goal.md` |
| Explorer (read-only) | `explorer.agent.md` | `cantrip-explore.md` |
| Planner | `planner.agent.md` | `cantrip-plan.md` |
| Worker / implementer | `worker.agent.md` | `cantrip-implement.md` |
| Reviewer (static) | `reviewer.agent.md` | `cantrip-review.md` |

The orchestrator owns the task, delegates bounded work, and alone runs verification.

## How it was set up

### GitHub Copilot
1. Create `~/.copilot/agents/` and add one `<name>.agent.md` per role. Each file has YAML frontmatter (`name`, `description`, `model`, `tools`) followed by the system prompt. The orchestrator has no tool restriction; explorer is limited to `view, grep, glob, bash`.
   Subagents are restricted with the `agents` frontmatter field: the orchestrator sets `agents: [explorer, planner, worker, reviewer]` (and its prompt forbids built-in/default agent types such as `general-purpose`), while the four role agents set `agents: []` so they cannot spawn subagents.
   The Copilot runtime does not enforce `agents`, so the orchestrator also declares an agent-scoped `preToolUse` hook that denies any `task` call whose `agent_type` is not a cantrip role. The hook scripts (`copilot/hooks/cantrip-agent-guard.ps1` for Windows, `.sh` for macOS/Linux) are installed to `~/.copilot/cantrip/`.
   Tool lists include both `bash*` and `powershell*` tools; unknown names are ignored, so each agent gets the shell of its platform. Without a shell tool the orchestrator used to fall back to `general-purpose`.
   The orchestrator must delegate to the planner before any non-trivial worker assignment.
2. Put global rules in `~/.copilot/copilot-instructions.md` (here: the Archgate governance loop).
3. Restart Copilot; pick the agent (e.g. `orchestrator`) in the agent selector. It delegates via the `task` tool to the other agents.

### Cursor
1. Create `~/.cursor/agents/` with one markdown file per role (frontmatter: `name`, `description`, optional `model`, `readonly`). `cantrip-goal` is the entry agent that delegates to `cantrip-explore/plan/implement/review`.
2. Add the hook script `~/.cursor/hooks/archgate-check.sh` and register it in `~/.cursor/hooks.json` as an `afterFileEdit` hook. It runs `archgate check` on each edited file inside repos that have `.archgate/`.
3. Restart Cursor.

### Archgate
Install the CLI to `~/.archgate/bin/archgate` and run `archgate init` in a repo to create `.archgate/` (ADRs and lint rules). The agents read ADRs before work and run `archgate check` after.

## Install on a new machine
```sh
git clone <this repo> && cd ai-agents-setup && ./install.sh
```
Existing `~/.cursor/hooks.json` is never overwritten. Adjust `model:` values to ones you have access to.
