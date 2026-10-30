#!/usr/bin/env node
// Protocol acceptance only: isolated home, ephemeral thread, no turn/start or model invocation.
import { spawn } from "node:child_process";
import { mkdtemp, rm, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
const home = await mkdtemp(join(tmpdir(), "agent-collab-codex-home-"));
await chmod(home, 0o700);
const report = {
  mode: "isolated-protocol-no-model",
  initialize: "not-run",
  threadStart: "not-run",
  injectFunctionCallOutput: "not-run",
  runtimeDeliveryVerified: false,
};
let child, lines;
const pending = new Map();
let next = 0;
function request(method, params) {
  return new Promise((resolve) => {
    const id = ++next;
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve({ accepted: false, code: "timeout" });
    }, 10_000);
    pending.set(id, { resolve, timer });
    child.stdin.write(
      JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n",
    );
  });
}
try {
  child = spawn(
    process.argv[2] ?? "/Applications/Codex.app/Contents/Resources/codex",
    ["app-server", "--stdio"],
    {
      cwd: home,
      env: { PATH: process.env.PATH, CODEX_HOME: home },
      stdio: ["pipe", "pipe", "ignore"],
    },
  );
  child.stdin.on("error", () => {});
  child.on("error", () => {
    for (const { resolve, timer } of pending.values()) {
      clearTimeout(timer);
      resolve({ accepted: false, code: "process-unavailable" });
    }
    pending.clear();
  });
  lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    clearTimeout(entry.timer);
    entry.resolve(
      Object.hasOwn(message, "result")
        ? { accepted: true, result: message.result }
        : { accepted: false, code: "protocol-rejected" },
    );
  });
  const initialized = await request("initialize", {
    clientInfo: { name: "agent-collab-probe", version: "0.1.0" },
    capabilities: { experimentalApi: true },
  });
  report.initialize = initialized.accepted ? "accepted" : initialized.code;
  if (initialized.accepted) {
    child.stdin.write(
      JSON.stringify({ jsonrpc: "2.0", method: "initialized" }) + "\n",
    );
    const thread = await request("thread/start", {
      cwd: home,
      ephemeral: true,
      sandbox: "read-only",
      approvalPolicy: "never",
    });
    report.threadStart = thread.accepted ? "accepted" : thread.code;
    const threadId = thread.result?.thread?.id;
    if (thread.accepted && typeof threadId === "string") {
      const injection = await request("thread/inject_items", {
        threadId,
        items: [
          {
            type: "function_call_output",
            call_id: "agent-collab-isolated-probe",
            output: "Fixed protocol acceptance probe. No user authorization.",
          },
        ],
      });
      report.injectFunctionCallOutput = injection.accepted
        ? "accepted"
        : injection.code;
    }
  }
} catch {
  report.failure = "probe-failed";
} finally {
  lines?.close();
  for (const { timer, resolve } of pending.values()) {
    clearTimeout(timer);
    resolve({ accepted: false, code: "probe-closed" });
  }
  pending.clear();
  if (child && child.exitCode === null) {
    child.stdin.end();
    child.kill("SIGTERM");
    await new Promise((resolve) => {
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        resolve();
      }, 2000);
      child.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
  await rm(home, { recursive: true, force: true });
}
process.stdout.write(JSON.stringify(report, null, 2) + "\n");
