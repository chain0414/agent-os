import test from "node:test";
import assert from "node:assert/strict";
import { generatedMessage, originOf } from "../../native/dsh-host.mjs";
test("generated delivery is attributed to plugin, never a human", () => {
  const m = generatedMessage({
    output: "RESULT",
    taskId: "t",
    deliveryId: "d",
    source: { runtime: "codex" },
  });
  assert.equal(m.source.kind, "agent-collab-generated");
  assert.equal(m.source.deliveryId, "d");
  assert.match(m.content[0].text, /RESULT/);
});
test("kernel context supplies source regardless of model arguments", () => {
  assert.deepEqual(
    originOf({ agent: { id: "real" }, callId: "call" }, "turn"),
    { runtime: "dsh", sessionId: "real", callId: "call", turnId: "turn" },
  );
  assert.throws(() => originOf({}, "turn"), /HOST_ORIGIN_UNAVAILABLE/);
});

import { EventEmitter } from "node:events";
import { DshClient } from "../../native/dsh-client.mjs";
test("DSH teardown waits for the process exit after escalation", async () => {
  const client = new DshClient();
  const child = new EventEmitter();
  child.exitCode = null;
  child.signalCode = null;
  let exited = false;
  child.kill = (signal) => {
    if (signal === "SIGKILL")
      setTimeout(() => {
        exited = true;
        child.signalCode = signal;
        child.emit("exit");
      }, 10);
  };
  client.child = child;
  await client.close();
  assert.equal(exited, true);
});

import { nativeInput } from "../../packages/dsh-plugin/src/native.mjs";
test("delegated tasks bind their native input ID without claiming human authorization", () => {
  const message = nativeInput({ content: "review", requestId: "task-123" });
  assert.equal(message.id, "task-123");
  assert.equal(message.source.kind, "agent-collab-task");
  assert.equal(message.source.taskId, "task-123");
  assert.equal(nativeInput({ content: "confirmed" }).source.kind, "user");
});
