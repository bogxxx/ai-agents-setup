# AI agents setup (GitHub Copilot + Cursor)

A role-based multi-agent setup ("cantrip") with Archgate ADR governance.

## Setup

### 1. Prerequisites

| Tool | Why | Check |
|---|---|---|
| GitHub Copilot app or Copilot CLI ≥ 1.0.99 | agent-scoped hooks in `.agent.md` frontmatter | `copilot --version` |
| Access to the models in the `model:` fields: claude-opus-5.5, claude-haiku-5.5, gpt-6.1-terra, gpt-6.1-sol, and on Cursor `grok-4.7` and `muse-wonder` | each role has a pinned model; change it if you lack access. Fast mode is off | — |
| git | ADR history, diffs, and the credential helper that Archgate uses | `git --version` |
| Node.js ≥ 18 | runs the `agentStop` Archgate stop gate (without it the gate is skipped) | `node --version` |
| PowerShell 5.1+ (Windows) or `sh` (macOS/Linux) | runs the `preToolUse` guard | — |
| Archgate CLI | ADRs, `archgate check`, lessons tooling | `archgate --version` |
| gh (optional) | GitHub writes that the worker makes | `gh auth status` |
| Cursor (optional) | the `cursor/` agent set | — |

### 2. Install Archgate and sign in

```sh
# macOS / Linux
curl -fsSL https://cli.archgate.dev/install-unix | sh
# Windows (PowerShell)
irm https://cli.archgate.dev/install-windows | iex
```

The CLI is installed to `~/.archgate/bin/`; the agents also find it there when it is not on PATH. Then sign in once. This is a browser device-code flow, and the token is stored by your git credential helper:

```sh
archgate login
```

### 3. Install the cantrip agents and hooks

```sh
git clone https://github.com/bogxxx/ai-agents-setup && cd ai-agents-setup
./install.sh                                                      # macOS / Linux: Copilot + Cursor
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1  # Windows: Copilot
```

This copies:
- `copilot/agents/*.agent.md` to `~/.copilot/agents/`;
- `copilot/copilot-instructions.md` to `~/.copilot/`;
- the hook scripts to `~/.copilot/cantrip/`;
- the Cursor agents and hook to `~/.cursor/`.

An existing `~/.cursor/hooks.json` is never overwritten.

### 4. Install the Archgate Copilot plugin (recommended)

The plugin provides the `reviewer`, `lessons-learned`, `adr-author` and `cli-reference` skills that the orchestrator, explorer, reviewer and worker use when they are installed:

```sh
archgate plugin install --editor copilot
# or manually:
copilot plugin marketplace add "$(archgate plugin url --editor copilot)"
copilot plugin install archgate@archgate
```

Without the plugin, the loop falls back to the plain CLI commands.

> **Known issue:** Archgate reads its login token through `git credential fill` with a 3-second timeout. On a slow machine, Git Credential Manager can take longer, and then `plugin install` reports "Not logged in" right after a successful `archgate login`. Retry when the machine is idle.

### 5. Govern a repository

In each repository the orchestrator should govern:

```sh
archgate init --editor copilot   # creates .archgate/ (ADRs + rules); skip if the repo already has it
archgate check                   # should run cleanly before you start
```

The orchestrator only applies the Archgate loop in repositories with `.archgate/`.

### 6. Use it

Restart Copilot, because running sessions keep the definitions they loaded at start, and select **orchestrator** in the agent picker. In Cursor, use **cantrip-goal**.

Verify the hooks with `node copilot/hooks/test/guard.test.mjs` (any OS; it runs the POSIX guard under `sh` and `dash`, and the PowerShell guard when `pwsh` or `powershell` is installed) or with `powershell -File copilot/hooks/test-hooks.ps1` (add `-IncludeSh` on Windows to also test the POSIX guard).

To update, pull this repository and re-run the installer, then restart open sessions. Do not run `install.sh` on a machine where `~/.copilot/agents/*.agent.md` or `~/.cursor/agents/*.md` are symlinks into another checkout (for example `~/src/bb-setup`): `install.sh` copies with `cp`, which writes through the symlinks and overwrites that checkout's files. Copy only the hook files instead: `cp copilot/hooks/cantrip-agent-guard.sh copilot/hooks/cantrip-agent-guard.ps1 copilot/hooks/archgate-stop-gate.mjs ~/.copilot/cantrip/`.

## Roles
| Role | Copilot (`~/.copilot/agents/`) | Cursor (`~/.cursor/agents/`) |
|---|---|---|
| Orchestrator / goal owner | `orchestrator.agent.md` | `cantrip-goal.md` |
| Explorer (read-only) | `explorer.agent.md` | `cantrip-explore.md` |
| Planner | `planner.agent.md` | `cantrip-plan.md` |
| Worker / implementer | `worker.agent.md` | `cantrip-implement.md` |
| Reviewer (static) | `reviewer.agent.md` | `cantrip-review.md` |

The orchestrator owns the task, runs the Archgate preflight and closing loop, and confirms the result. It does not edit files and does little reading itself. Most of the tool calls are made by the worker and the explorer: the worker makes every change and runs the verification commands listed in its assignment, and the explorer does the reading, including the Archgate briefing and the lesson evidence.

Explorers have a shell, and it is read-only. They use it for Archgate inspection (`adr list`, `review-context`, `adr show`) and git inspection (`status`, `diff`, `log`, `show`). Commands that change the repository or the environment belong to the worker. On Cursor, `readonly: true` enforces that: file edits and state-changing shell commands are blocked, and read-only shell commands still run. On Copilot, the explorer keeps `bash` and `powershell`, and its prompt forbids mutating commands.

Fast mode is not allowed on any role. Cursor's worker (`cantrip-implement`) and explorer (`cantrip-explore`) are pinned to `grok-4.7` with `reasoning_effort=xhigh` and `fast=false`. Every other Cursor role sets `fast=false` as well. Do not override these models.

## How it works

### GitHub Copilot
1. Create `~/.copilot/agents/` and add one `<name>.agent.md` per role. Each file has YAML frontmatter (`name`, `description`, `model`, `tools`) followed by the system prompt. The orchestrator has no `edit`/`create` tools; its shell is for Archgate commands, read-only inspection, and verification. Explorer and planner are limited to read and shell tools, and the reviewer's tools are read-only. The explorer's shell is read-only: Archgate inspection and git inspection, not commands that change the repository.
   Subagents are restricted with the `agents` frontmatter field: the orchestrator sets `agents: [explorer, planner, worker, reviewer]` (and its prompt forbids built-in/default agent types such as `general-purpose`), while the four role agents set `agents: []` so they cannot spawn subagents.
   Tool lists include both `bash*` and `powershell*` tools; unknown names are ignored, so each agent gets the shell of its platform. Without a shell tool the orchestrator used to fall back to `general-purpose`.
   The orchestrator must delegate to the planner before any non-trivial worker assignment, and gives every change to a worker, including git, GitHub, and ADR operations.
2. The orchestrator declares two agent-scoped hooks. Their scripts live in `copilot/hooks/` and are installed to `~/.copilot/cantrip/`:
   - **`preToolUse` guard** (`cantrip-agent-guard.ps1` on Windows, `.sh` on macOS/Linux). It denies `task` calls whose `agent_type` is not a cantrip role; the runtime does not enforce `agents`. In the orchestrator's own session it also caps `view`/`grep`/`glob` calls at 30 (`CANTRIP_READ_BUDGET`), and denies file edits and mutating shell commands: git merge, commit, push and worktree; gh writes; file writes and redirection; `--fix`/`--write`; package installs; and `archgate adr create`/`update`. The orchestrator must delegate those to a worker. Subagent calls are told apart because only root sessions have a `~/.copilot/session-state/<sessionId>` directory. The orchestrator hands an assignment to a spawned agent through a quoted heredoc: `cat > "$BB_THREAD_STORAGE/<name>.md" <<'EOF'` (or, in PowerShell, `@'` ... `'@ | Set-Content -LiteralPath`), then `spawn --assignment-file`. The guard skips the body of such a heredoc, because it is data, and of a quoted heredoc piped into `bb plugin run role-picker spawn|ask`; the header and every other line are still scanned. The skip applies only when the hook sees `BB_THREAD_STORAGE`. Thread storage may only be used as the `--assignment-file` argument of a `bb plugin run role-picker spawn` simple command that starts a line or follows `;` (or `do`): any other use is denied, including `set --`, `printf`, `echo ... | sh`, assignments and positional-parameter execution such as `sh "$8"`, including assigning it to a variable, redefining `BB_THREAD_STORAGE`, looping over it, or running or sourcing a file from it. Aliases, functions and `PATH` changes are denied, because they could rebind `bb`, `cat` or `sh`. If the pre-scan fails, the command is denied. `--assignment "$(cat <<'EOF' ...)"` is still denied.
   - **`agentStop` Archgate stop gate** (`archgate-stop-gate.mjs`, needs `node`). When files changed since the last clean stop, it runs `archgate check --base` in every changed repository that has `.archgate/`. It blocks the stop until the check passes, or the failing rule is named as pre-existing or blocked, and the final report has an `## Archgate` section. It skips stops while subagents are running and gives up after 3 consecutive blocks.
   Hook timeouts are fail-open, so the guard has a 60-second timeout to allow for slow PowerShell startup.
3. Put global rules in `~/.copilot/copilot-instructions.md` (here: the Archgate governance and learning loop).
4. Restart Copilot; pick the agent (e.g. `orchestrator`) in the agent selector. Running sessions keep the definitions they loaded at start.

Test the hooks with `node copilot/hooks/test/guard.test.mjs`, or with `powershell -File copilot/hooks/test-hooks.ps1`. Both run the guard cases in `copilot/hooks/test/guard-cases.json`; the node runner also checks both payload spellings (plain and `\u003c`-escaped) and runs without PowerShell. `test-hooks.ps1` also runs the stop gate tests when `node` is available. On Windows, add `-IncludeSh` to also test the POSIX guard; it is slow under MSYS.

### Archgate loop in the orchestrator
- **Preflight**: the orchestrator runs `archgate adr list` and a baseline `check --base`. The explorer produces the briefing: `review-context --base`, `adr show` for the governing ADRs, and lessons from recent `.archgate/` history (`git log -- .archgate/`). Every delegation carries the ADR IDs and their Do's and Don'ts.
- **Closing loop**: the worker runs `check --base` with its verification, the reviewer checks the diff against the ADRs, the explorer gathers the lesson evidence (`archgate session-context`, the `lessons-learned` skill if installed), and the orchestrator decides and re-runs the final check. Each lesson is encoded at the layer that enforces it: a `.rules.ts` rule, a test, or a new or amended ADR. The worker writes these with `archgate adr create`/`update` on the same branch, in a separate commit. Reversing an accepted decision is only proposed to the user. The final report ends with an `## Archgate` section.
- The Archgate Copilot plugin (`reviewer`, `lessons-learned`, `adr-author` skills) is used when installed. Installing it requires `archgate login`; the loop falls back to the CLI without it.

### Cursor
1. Create `~/.cursor/agents/` with one markdown file per role (frontmatter: `name`, `description`, optional `model`, `readonly`). `cantrip-goal` is the entry agent that delegates to `cantrip-explore/plan/implement/review`. It follows the same preflight and closing loop, enforced by its prompt only. `cantrip-explore` is `readonly: true`, which still allows its read-only shell. `cantrip-implement` and `cantrip-explore` use `grok-4.7` at extra-high reasoning with fast mode off.

   The `model:` lines use bracket parameters on purpose. Do not replace them with a picker slug.

   | Role | Pin | What a slug does instead |
   |---|---|---|
   | goal, plan | `claude-opus-5-5[effort=medium,fast=false]` | `claude-opus-5-5-medium` follows the picker effort and can turn Fast on |
   | explore, implement | `grok-4.7[reasoning_effort=xhigh,fast=false]` | `grok-4.7-xhigh` drops `fast=false`. On Premium and above, Fast is the default speed tier, so the agent runs Fast |
   | review | `muse-wonder[effort=medium,fast=false]` | `muse-wonder-1.0-high` is Muse High |

   Cursor's subagent launcher only offers one variant per model family, taken from the model picker. If Muse Wonder is set to High there, Medium is not in that list, and a parent agent that "fixes" an unrecognized id will write the High slug into `~/.cursor/agents/`. Grok's effort parameter is `reasoning_effort`, not `effort`. `fast=false` has to stay in the file. There is a separate Cursor bug where a subagent still runs Fast when the parent chat is on another model, even with that pin. The workaround is to open the model picker, select Grok 4.7, turn Fast on and then off so the off state is saved, then start a new chat. Set Muse Wonder's effort to Medium in that same picker before expecting the review agent to run at Medium.
2. Add the hook script `~/.cursor/hooks/archgate-check.sh` and register it in `~/.cursor/hooks.json` as an `afterFileEdit` hook. It runs `archgate check` on each edited file inside repos that have `.archgate/`.
3. Restart Cursor.
