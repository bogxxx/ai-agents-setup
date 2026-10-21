// Tests for archgate-stop-gate.mjs. Run: node copilot/hooks/test/stop-gate.test.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const gate = path.join(here, "..", "archgate-stop-gate.mjs");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "cantrip-gate-"));
const home = path.join(tmp, "home");
const stateDir = path.join(tmp, "state");
fs.mkdirSync(path.join(home, "session-state", "root"), { recursive: true });

const governed = path.join(tmp, "governed");
fs.mkdirSync(path.join(governed, ".git"), { recursive: true });
fs.mkdirSync(path.join(governed, ".archgate"), { recursive: true });
fs.mkdirSync(path.join(governed, "src"), { recursive: true });
const plain = path.join(tmp, "plain");
fs.mkdirSync(path.join(plain, ".git"), { recursive: true });

const fakeArchgate = path.join(tmp, "fake-archgate.mjs");
fs.writeFileSync(
  fakeArchgate,
  `process.stdout.write(process.env.FAKE_CHECK || JSON.stringify({ pass: true, results: [] }));`,
);
const failing = JSON.stringify({
  pass: false,
  results: [
    {
      adrId: "GEN-003",
      ruleId: "tests-next-to-code",
      status: "fail",
      violations: [{ file: "src/a.py", line: 3, message: "missing test", severity: "error" }],
    },
  ],
});

const ev = {
  user: () => ({ type: "user.message", data: { content: "do it" } }),
  started: (id) => ({ type: "subagent.started", data: { toolCallId: id, agentName: "worker" } }),
  completed: (id) => ({ type: "subagent.completed", data: { toolCallId: id } }),
  edit: (p) => ({ type: "tool.execution_start", agentId: "w1", data: { toolName: "edit", arguments: { path: p } } }),
  patch: (p) => ({
    type: "tool.execution_start",
    agentId: "w1",
    data: { toolName: "apply_patch", arguments: `*** Begin Patch\n*** Update File: ${p}\n@@\n-a\n+b\n*** End Patch` },
  }),
  shell: (cmd, agentId = "w1") => ({ type: "tool.execution_start", agentId, data: { toolName: "powershell", arguments: { command: cmd } } }),
  say: (text) => ({ type: "assistant.message", data: { content: text } }),
  done: (summary) => ({ type: "tool.execution_start", data: { toolName: "task_complete", arguments: { summary } } }),
};

let n = 0;
function run({ events, sessionId = "root", check, cwd = governed, keepState = false }) {
  if (!keepState) fs.rmSync(stateDir, { recursive: true, force: true });
  const transcript = path.join(tmp, `t${n++}.jsonl`);
  fs.writeFileSync(transcript, events.map((e) => JSON.stringify(e)).join("\n") + "\n");
  const res = spawnSync(process.execPath, [gate], {
    input: JSON.stringify({ sessionId, transcriptPath: transcript, cwd, stop_hook_active: false }),
    encoding: "utf8",
    env: { ...process.env, COPILOT_HOME: home, CANTRIP_STATE_DIR: stateDir, ARCHGATE_BIN: fakeArchgate, FAKE_CHECK: check || "" },
  });
  if (res.status !== 0) throw new Error(`gate exited ${res.status}: ${res.stderr}`);
  return res.stdout ? JSON.parse(res.stdout) : null;
}

const report = "Done.\n\n## Archgate\nADRs: GEN-003. Check: pass at baseline and end. Lessons: none.";
const file = path.join(governed, "src", "a.py");
const cases = [
  ["subagent session is ignored", () => run({ sessionId: "w1", events: [ev.edit(file)] }) === null],
  ["no changes allows stop", () => run({ events: [ev.user(), ev.say("Answer only.")] }) === null],
  ["changes with report and passing check allow stop", () => run({ events: [ev.user(), ev.edit(file), ev.say(report)] }) === null],
  ["report in task_complete summary counts", () => run({ events: [ev.user(), ev.patch(file), ev.done(report)] }) === null],
  [
    "missing Archgate section blocks",
    () => /no `## Archgate` section/.test(run({ events: [ev.user(), ev.edit(file), ev.say("Done.")] })?.reason || ""),
  ],
  [
    "report written before the last change does not count",
    () => run({ events: [ev.user(), ev.edit(file), ev.say(report), ev.edit(file), ev.say("Fixed.")] })?.decision === "block",
  ],
  [
    "failing check blocks and lists the rule",
    () => /GEN-003\/tests-next-to-code: src\/a\.py:3/.test(run({ events: [ev.user(), ev.edit(file), ev.say("Done.\n## Archgate\nall good")], check: failing })?.reason || ""),
  ],
  [
    "failing rule named in the report is acknowledged",
    () => run({ events: [ev.user(), ev.edit(file), ev.say("## Archgate\ntests-next-to-code fails on main already (pre-existing).")], check: failing }) === null,
  ],
  ["running subagent allows stop", () => run({ events: [ev.user(), ev.started("c1"), ev.edit(file), ev.say("Waiting.")] }) === null],
  ["finished subagent is gated", () => run({ events: [ev.user(), ev.started("c1"), ev.edit(file), ev.completed("c1"), ev.say("Done.")] })?.decision === "block"],
  ["ungoverned repo allows stop", () => run({ cwd: plain, events: [ev.user(), ev.edit(path.join(plain, "x.py")), ev.say("Done.")] }) === null],
  ["mutating shell in governed cwd is gated", () => run({ events: [ev.user(), ev.shell("git merge origin/feature --no-edit"), ev.say("Merged.")] })?.decision === "block"],
  ["read-only shell is not a change", () => run({ events: [ev.user(), ev.shell("git --no-pager diff --stat 2>&1", undefined), ev.say("Looked.")] }) === null],
  [
    "allows after three consecutive blocks, then gates new changes again",
    () => {
      fs.rmSync(stateDir, { recursive: true, force: true });
      const events = [ev.user(), ev.edit(file), ev.say("Done.")];
      const outcomes = [0, 1, 2, 3].map(() => run({ events, keepState: true })?.decision || "allow");
      const later = run({ events: [...events, ev.edit(file), ev.say("again")], keepState: true })?.decision || "allow";
      fs.rmSync(stateDir, { recursive: true, force: true });
      return outcomes.join(",") === "block,block,block,allow" && later === "block";
    },
  ],
];

let failed = 0;
fs.rmSync(stateDir, { recursive: true, force: true });
for (const [name, fn] of cases) {
  let ok = false;
  try {
    ok = fn();
  } catch (e) {
    console.log(`  error: ${e.message}`);
  }
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
}
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`[stop-gate] ${cases.length} cases, ${failed} failed`);
process.exit(failed ? 1 : 0);
