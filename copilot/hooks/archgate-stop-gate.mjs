#!/usr/bin/env node
// agentStop gate for the cantrip orchestrator: enforces the Archgate closing loop.
// When files changed since the last clean stop, every changed repository that has `.archgate/`
// must pass `archgate check --base`, and the final report must contain an `## Archgate` section.
// Stops while subagents are still running are allowed. After MAX_BLOCKS consecutive blocks the stop is allowed.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const MAX_BLOCKS = 3;
const EDIT_TOOLS = new Set(["edit", "create", "apply_patch", "str_replace_editor", "str_replace", "write", "multi_edit"]);
const SHELL_TOOLS = new Set(["powershell", "bash", "write_powershell", "write_bash"]);
const MUTATING_SHELL = [
  /\bgit\b[^;|&\r\n]*?\s(commit|merge|rebase|cherry-pick|revert|reset|restore|checkout|switch|stash|am|apply|rm|mv)\b/i,
  /\b(Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item|Rename-Item)\b/i,
  /\[(System\.)?IO\.File\]::(Write|Append|Delete|Move|Copy)/i,
  /(^|[;&|(]\s*)\s*(rm|mv|cp|touch|mkdir|tee)\s/im,
  /\bsed\s+-i/i,
  /\s--(fix|write)\b/i,
  /(^|[^0-9&=>-])>>?(?!\s*(\$null|\/dev\/null|nul\b|&))\s*\S/i,
];
const REPORT_HEADING = /^#{1,3}\s*Archgate\b/im;

function readInput() {
  try {
    return JSON.parse(fs.readFileSync(0, "utf8"));
  } catch {
    return null;
  }
}

function findGitRoot(start) {
  let dir = start;
  for (let i = 0; i < 64 && dir; i++) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
  return null;
}

function existingDir(p) {
  let dir = p;
  while (dir && !fs.existsSync(dir)) {
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
  return dir && fs.statSync(dir).isDirectory() ? dir : dir && path.dirname(dir);
}

function patchPaths(patch) {
  const out = [];
  for (const m of String(patch).matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm)) out.push(m[1].trim());
  for (const m of String(patch).matchAll(/^\*\*\* Move to: (.+)$/gm)) out.push(m[1].trim());
  return out;
}

function archgateCommand() {
  if (process.env.ARCHGATE_BIN) {
    const bin = process.env.ARCHGATE_BIN;
    return /\.m?js$/.test(bin) ? [process.execPath, [bin]] : [bin, []];
  }
  const local = path.join(os.homedir(), ".archgate", "bin", process.platform === "win32" ? "archgate.exe" : "archgate");
  return [fs.existsSync(local) ? local : "archgate", []];
}

function runCheck(repo) {
  const [cmd, prefix] = archgateCommand();
  const res = spawnSync(cmd, [...prefix, "check", "--base", "--output", "json"], {
    cwd: repo,
    encoding: "utf8",
    timeout: 150000,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (res.error) return { ran: false, detail: res.error.message };
  const text = res.stdout || "";
  const start = text.indexOf("{");
  if (start < 0) return { ran: false, detail: (res.stderr || text || `exit ${res.status}`).trim().slice(0, 400) };
  try {
    return { ran: true, result: JSON.parse(text.slice(start)) };
  } catch {
    return { ran: false, detail: "unparsable archgate output" };
  }
}

function failures(result) {
  const out = [];
  for (const r of result.results || []) {
    const errors = (r.violations || []).filter((v) => v.severity === "error");
    if (r.status !== "fail" && errors.length === 0) continue;
    const shown = (errors.length ? errors : r.violations || []).slice(0, 5);
    const lines = shown.length
      ? shown.map((v) => `- ${r.adrId}/${r.ruleId}: ${v.file || ""}${v.line ? `:${v.line}` : ""} ${v.message}`)
      : [`- ${r.adrId}/${r.ruleId}: ${r.description || "failed"}`];
    out.push({ ruleId: r.ruleId, adrId: r.adrId, lines });
  }
  if (!out.length && result.ruleErrors) out.push({ ruleId: null, lines: [`- ${result.ruleErrors} rule(s) errored while running`] });
  return out;
}

const input = readInput();
if (!input) process.exit(0);
const sessionId = input.sessionId || input.session_id;
const transcript = input.transcriptPath || input.transcript_path;
const cwd = input.cwd || process.cwd();
const copilotHome = process.env.COPILOT_HOME || path.join(os.homedir(), ".copilot");
if (!sessionId || !fs.existsSync(path.join(copilotHome, "session-state", sessionId))) process.exit(0);
if (!transcript || !fs.existsSync(transcript)) process.exit(0);

const stateDir = process.env.CANTRIP_STATE_DIR || path.join(os.tmpdir(), "cantrip-stop-gate");
const stateFile = path.join(stateDir, `${sessionId}.json`);
let state = { cleanLine: 0, blocks: 0 };
try {
  state = { ...state, ...JSON.parse(fs.readFileSync(stateFile, "utf8")) };
} catch {}
const save = () => {
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(stateFile, JSON.stringify(state));
};

const lines = fs.readFileSync(transcript, "utf8").split(/\r?\n/);
const changedPaths = new Set();
let shellChange = false;
let lastChange = -1;
let report = "";
const pending = new Set();

for (let i = Math.min(state.cleanLine, lines.length); i < lines.length; i++) {
  if (!lines[i]) continue;
  let ev;
  try {
    ev = JSON.parse(lines[i]);
  } catch {
    continue;
  }
  const data = ev.data || {};
  if (ev.type === "subagent.started" && data.toolCallId) pending.add(data.toolCallId);
  else if ((ev.type === "subagent.completed" || ev.type === "subagent.failed") && data.toolCallId) pending.delete(data.toolCallId);
  else if (ev.type === "tool.execution_start") {
    const name = data.toolName;
    const args = data.arguments;
    if (EDIT_TOOLS.has(name)) {
      const paths = typeof args === "string" ? patchPaths(args) : args?.path ? [args.path] : patchPaths(args?.input || args?.patch || "");
      paths.forEach((p) => changedPaths.add(path.resolve(cwd, p)));
      lastChange = i;
      report = "";
    } else if (SHELL_TOOLS.has(name)) {
      const cmd = typeof args === "string" ? args : `${args?.command || ""}\n${args?.input || ""}`;
      if (MUTATING_SHELL.some((re) => re.test(cmd))) {
        shellChange = true;
        lastChange = i;
        report = "";
      }
    } else if (name === "task_complete" && !ev.agentId) {
      report += `\n${args?.summary || ""}`;
    }
  } else if (ev.type === "assistant.message" && !ev.agentId && data.content) {
    report += `\n${data.content}`;
  }
}

const markClean = () => {
  state = { cleanLine: lines.at(-1) === "" ? lines.length - 1 : lines.length, blocks: 0 };
  save();
  process.exit(0);
};

if (pending.size) process.exit(0);
if (lastChange < 0) markClean();

const repos = new Set();
for (const p of changedPaths) {
  const dir = existingDir(path.dirname(p));
  const root = dir && findGitRoot(dir);
  if (root) repos.add(root);
}
if (shellChange) {
  const root = findGitRoot(cwd);
  if (root) repos.add(root);
}
const governed = [...repos].filter((r) => fs.existsSync(path.join(r, ".archgate")));
if (!governed.length) markClean();

const hasReport = REPORT_HEADING.test(report);
const problems = [];
const notes = [];
for (const repo of governed) {
  const check = runCheck(repo);
  if (!check.ran) {
    notes.push(`archgate check could not run in ${repo}: ${check.detail}. Report this in the Archgate section; do not claim compliance.`);
    continue;
  }
  if (check.result.pass === false) {
    // A failing rule named in the Archgate section is acknowledged (pre-existing or blocked) and does not block.
    const open = failures(check.result).filter((f) => !(hasReport && f.ruleId && report.includes(f.ruleId)));
    if (open.length || !hasReport) {
      const lines = open.flatMap((f) => f.lines);
      problems.push(`archgate check --base fails in ${repo}:\n${(lines.length ? lines : ["- see `archgate check --base`"]).join("\n")}`);
    }
  }
}
if (!hasReport) {
  problems.push("Your final report has no `## Archgate` section. It must list: the ADRs applied; the check result at baseline and at the end; the reviewer findings; the lessons learned; and the ADR or rule changes made or proposed.");
}

if (!problems.length) markClean();
if (state.blocks >= MAX_BLOCKS) markClean();

state.blocks += 1;
save();
const reason = [
  "Archgate stop gate: the closing loop is not complete for the files changed in this task.",
  ...problems,
  ...notes,
  "Delegate fixes to a worker (you do not edit files), re-run `archgate check --base`, run the lessons-learned step, and finish with the `## Archgate` section.",
  "If a failure is pre-existing or genuinely blocked, name its rule id in the Archgate section with the reason; named failures are treated as acknowledged.",
].join("\n\n");
process.stdout.write(JSON.stringify({ decision: "block", reason }));
