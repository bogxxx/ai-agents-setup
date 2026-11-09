// Runs cantrip-agent-guard.sh (sh, and dash when present) and cantrip-agent-guard.ps1 (when pwsh or
// powershell is present) against guard-cases.json. Run: node copilot/hooks/test/guard.test.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const guardSh = path.join(here, "..", "cantrip-agent-guard.sh");
const guardPs1 = path.join(here, "..", "cantrip-agent-guard.ps1");
const cases = JSON.parse(fs.readFileSync(path.join(here, "guard-cases.json"), "utf8").replace(/^\uFEFF/, ""));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "cantrip-guard-"));
const home = path.join(tmp, "home");
const stateDir = path.join(tmp, "state");
const storage = path.join(tmp, "storage");
for (const sid of ["root-session", "root-budget"]) fs.mkdirSync(path.join(home, "session-state", sid), { recursive: true });
fs.mkdirSync(storage);

const onPath = (cmd) => spawnSync("sh", ["-c", `command -v ${cmd}`], { encoding: "utf8" }).status === 0;
const runners = [{ name: "sh", cmd: "sh", args: [guardSh] }];
if (onPath("dash")) runners.push({ name: "dash", cmd: "dash", args: [guardSh] });
const ps = ["pwsh", "powershell"].find(onPath);
if (ps) runners.push({ name: "ps1", cmd: ps, args: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", guardPs1] });

// Copilot and ConvertTo-Json escape these characters; the guards must decode both spellings.
const escaped = (json) => json.replace(/</g, "\\u003c").replace(/>/g, "\\u003e").replace(/&/g, "\\u0026").replace(/'/g, "\\u0027");
const payload = (c, sessionId) =>
  JSON.stringify({ sessionId: sessionId || (c.s === "root" ? "root-session" : "subagent-1234"), toolName: c.t, toolArgs: c.a });

function decide(runner, json, extraEnv = {}) {
  const env = { ...process.env, COPILOT_HOME: home, CANTRIP_STATE_DIR: stateDir, BB_THREAD_STORAGE: storage, ...extraEnv };
  for (const [k, v] of Object.entries(env)) if (v === undefined) delete env[k];
  const res = spawnSync(runner.cmd, runner.args, { input: json, encoding: "utf8", env });
  if (res.status !== 0) throw new Error(`${runner.name} exited ${res.status}: ${res.stderr}`);
  return /"permissionDecision":\s*"deny"/.test(res.stdout) ? "deny" : "allow";
}

let failed = 0;
let total = 0;
function check(runner, label, got, want) {
  total++;
  if (got === want) return;
  failed++;
  console.log(`FAIL [${runner.name}] ${label}: expected ${want}, got ${got}`);
}

for (const runner of runners) {
  cases.forEach((c, i) => {
    const label = c.id || `case ${i}`;
    for (const [variant, json] of [["plain", payload(c)], ["escaped", escaped(payload(c))]]) {
      check(runner, `${label} (${variant})`, decide(runner, json), c.e);
    }
  });
  // E3 relies on the hook seeing BB_THREAD_STORAGE; without it the heredoc write is scanned and denied.
  const a3 = cases.find((c) => c.id === "A3");
  check(runner, "A3 without BB_THREAD_STORAGE", decide(runner, payload(a3), { BB_THREAD_STORAGE: undefined }), "deny");
  // Read budget: with a budget of 2, the third root view is denied; subagent reads are never counted.
  fs.rmSync(stateDir, { recursive: true, force: true });
  const view = JSON.stringify({ sessionId: "root-budget", toolName: "view", toolArgs: { path: "a.py" } });
  const sub = JSON.stringify({ sessionId: "subagent-1234", toolName: "view", toolArgs: { path: "a.py" } });
  const budget = [view, view, sub, view].map((j) => decide(runner, j, { CANTRIP_READ_BUDGET: "2" })).join(",");
  check(runner, "read budget", budget, "allow,allow,allow,deny");
  fs.rmSync(stateDir, { recursive: true, force: true });
  console.log(`[${runner.name}] ${cases.length} cases x 2 payload spellings, plus unset storage and the read budget`);
}

fs.rmSync(tmp, { recursive: true, force: true });
if (!ps) console.log("ps1 guard not run: neither pwsh nor powershell is on PATH");
console.log(`[guard] ${total} checks, ${failed} failed`);
process.exit(failed ? 1 : 0);
