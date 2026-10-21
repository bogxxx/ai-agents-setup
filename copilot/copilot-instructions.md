# Archgate governance

Use Archgate's prevention, detection, and learning loop in repositories initialized with `.archgate/`. The CLI is available at `~/.archgate/bin/archgate` if it is not on PATH.

Before investigating, planning, or editing, read the applicable ADRs: use `archgate adr list`, `archgate review-context` for existing changes, and `archgate adr show <id>` for the decisions governing the intended files. An empty changed-file briefing does not mean no ADRs apply to planned work.

Treat applicable ADRs as project constraints. Cite conflicting decisions and obtain an explicit decision before changing architecture; do not invent or silently bypass rules. Pass relevant ADR IDs and constraints to delegated agents.

The agent responsible for verification runs `archgate check` after changes, fixes in-scope violations, and distinguishes pre-existing findings. Use `--staged` only when the full intended change is staged; do not stage files merely to run checks. Read-only agents and implementation workers retain their existing execution boundaries and hand verification to the orchestrator.

Report missing CLI, missing project initialization, and failed checks explicitly; do not claim enforcement when it did not run. Do not initialize projects or import ADRs without authorization.

Close the learning loop. Turn recurring lessons into the layer that enforces them: an executable `.rules.ts` rule, a test, or an ADR. New ADRs, new rules, and clarifying amendments may be made in the branch under review, in their own commit, and listed in the final report. Reversing or materially changing an accepted decision requires an explicit user decision. Never adopt a lesson silently.
