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

The orchestrator owns the task, delegates all hands-on work, runs verification, and runs the Archgate preflight and closing loop. It does not edit files itself.

## How it was set up

### GitHub Copilot
1. Create `~/.copilot/agents/` and add one `<name>.agent.md` per role. Each file has YAML frontmatter (`name`, `description`, `model`, `tools`) followed by the system prompt. The orchestrator has no `edit`/`create` tools; its shell is for Archgate commands, read-only inspection, and verification. Explorer and planner are limited to read and shell tools, and the reviewer to read tools.
   Subagents are restricted with the `agents` frontmatter field: the orchestrator sets `agents: [explorer, planner, worker, reviewer]` (and its prompt forbids built-in/default agent types such as `general-purpose`), while the four role agents set `agents: []` so they cannot spawn subagents.
   Tool lists include both `bash*` and `powershell*` tools; unknown names are ignored, so each agent gets the shell of its platform. Without a shell tool the orchestrator used to fall back to `general-purpose`.
   The orchestrator must delegate to the planner before any non-trivial worker assignment, and gives every change to a worker, including git, GitHub, and ADR operations.
2. The orchestrator declares two agent-scoped hooks. Their scripts live in `copilot/hooks/` and are installed to `~/.copilot/cantrip/`:
   - **`preToolUse` guard** (`cantrip-agent-guard.ps1` on Windows, `.sh` on macOS/Linux). It denies `task` calls whose `agent_type` is not a cantrip role; the runtime does not enforce `agents`. In the orchestrator's own session it also denies file edits and mutating shell commands: git merge, commit, push and worktree; gh writes; file writes and redirection; `--fix`/`--write`; package installs; and `archgate adr create`/`update`. The orchestrator must delegate those to a worker. Subagent calls are told apart because only root sessions have a `~/.copilot/session-state/<sessionId>` directory.
   - **`agentStop` Archgate stop gate** (`archgate-stop-gate.mjs`, needs `node`). When files changed since the last clean stop, it runs `archgate check --base` in every changed repository that has `.archgate/`. It blocks the stop until the check passes, or the failing rule is named as pre-existing or blocked, and the final report has an `## Archgate` section. It skips stops while subagents are running and gives up after 3 consecutive blocks.
   Hook timeouts are fail-open, so the guard has a 60-second timeout to allow for slow PowerShell startup.
3. Put global rules in `~/.copilot/copilot-instructions.md` (here: the Archgate governance and learning loop).
4. Restart Copilot; pick the agent (e.g. `orchestrator`) in the agent selector. Running sessions keep the definitions they loaded at start.

Test the hooks with `powershell -File copilot/hooks/test-hooks.ps1`. It runs the guard cases in `copilot/hooks/test/guard-cases.json`, and the stop gate tests when `node` is available. On Windows, add `-IncludeSh` to also test the POSIX guard; it is slow under MSYS.

### Archgate loop in the orchestrator
- **Preflight**: `archgate adr list`, `review-context --base`, `adr show` for the governing ADRs, a baseline `check --base`, and lessons from recent `.archgate/` history (`git log -- .archgate/`). It briefs every delegation with the ADR IDs and their Do's and Don'ts.
- **Closing loop**: `check --base` → reviewer against ADRs → lessons learned (`archgate session-context`, the `lessons-learned` skill if installed). Each lesson is encoded at the layer that enforces it: a `.rules.ts` rule, a test, or a new or amended ADR. The worker writes these with `archgate adr create`/`update` on the same branch, in a separate commit. Reversing an accepted decision is only proposed to the user. The final report ends with an `## Archgate` section.
- The Archgate Copilot plugin (`reviewer`, `lessons-learned`, `adr-author` skills) is used when installed. Installing it requires `archgate login`; the loop falls back to the CLI without it.

### Cursor
1. Create `~/.cursor/agents/` with one markdown file per role (frontmatter: `name`, `description`, optional `model`, `readonly`). `cantrip-goal` is the entry agent that delegates to `cantrip-explore/plan/implement/review`. It follows the same preflight and closing loop, enforced by its prompt only.
2. Add the hook script `~/.cursor/hooks/archgate-check.sh` and register it in `~/.cursor/hooks.json` as an `afterFileEdit` hook. It runs `archgate check` on each edited file inside repos that have `.archgate/`.
3. Restart Cursor.

### Archgate
Install the CLI to `~/.archgate/bin/archgate` and run `archgate init` in a repo to create `.archgate/` (ADRs and lint rules). The agents read ADRs before work and run `archgate check` after.

## Install on a new machine
```sh
git clone <this repo> && cd ai-agents-setup && ./install.sh
```
On Windows (Copilot only): `powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1`.

Existing `~/.cursor/hooks.json` is never overwritten. Adjust `model:` values to ones you have access to.
