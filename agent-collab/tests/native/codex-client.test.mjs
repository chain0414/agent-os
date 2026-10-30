import test from "node:test";
import assert from "node:assert/strict";
import {
  CodexNativeClient,
  trustedCodexOrigin,
  generatedItems,
} from "../../native/codex-client.mjs";
test("Codex origin comes only from app-server context", () => {
  assert.deepEqual(
    trustedCodexOrigin({ threadId: "a", turnId: "t", callId: "c" }),
    { runtime: "codex", sessionId: "a", turnId: "t", callId: "c" },
  );
  assert.throws(
    () => trustedCodexOrigin({ arguments: { threadId: "forged" } }),
    /ORIGIN_UNAVAILABLE/,
  );
});
test("generated delivery is a function result, never a user message", () => {
  const items = generatedItems({ deliveryId: "d", output: "do not execute" });
  assert.equal(items[0].type, "function_call");
  assert.equal(items[1].type, "function_call_output");
  assert.equal(items[1].output, "do not execute");
  assert.ok(items.every((i) => i.role !== "user"));
});

test("dynamic tool dispatch binds kernel identity, not tool arguments", async () => {
  const client = new CodexNativeClient();
  let called;
  let response;
  client.child = {
    stdin: {
      write(line) {
        response = JSON.parse(line);
      },
    },
  };
  client.sessions.set("real", {
    onTool: async (event) => {
      called = event;
      return { queued: true };
    },
  });
  await client.handle({
    id: 7,
    method: "item/tool/call",
    params: {
      threadId: "real",
      turnId: "turn",
      callId: "call",
      tool: "agent_collab_delegate",
      arguments: { threadId: "forged", content: "fixed" },
    },
  });
  assert.equal(called.origin.sessionId, "real");
  assert.equal(response.result.success, true);
});
test("invalid native origin never invokes tool body", async () => {
  const client = new CodexNativeClient();
  let response;
  client.child = {
    stdin: {
      write(line) {
        response = JSON.parse(line);
      },
    },
  };
  await client.handle({
    id: 8,
    method: "item/tool/call",
    params: {
      tool: "agent_collab_delegate",
      arguments: { threadId: "forged" },
    },
  });
  assert.equal(response.result.success, false);
});
test("asynchronous delivery starts an empty read-only turn and returns receipt", async () => {
  const client = new CodexNativeClient();
  client.sessions.set("session", {});
  let injected;
  let turn;
  client.request = async (method, params) => {
    injected = { method, params };
  };
  client.runTurn = async (...args) => {
    turn = args;
    return { turnId: "new", output: "consumed" };
  };
  const r = await client.deliverGenerated("session", {
    deliveryId: "d",
    taskId: "t",
    output: "generated data",
  });
  assert.equal(injected.method, "thread/inject_items");
  assert.equal(turn[1], null);
  assert.equal(turn[2].mode, "review");
  assert.equal(r.received, true);
  assert.equal(r.deliveryId, "d");
  assert.equal(r.sourceEvidence.userInputAdded, false);
});

test("unknown sessions cannot receive generated content", async () => {
  const client = new CodexNativeClient();
  let sent = false;
  client.request = async () => {
    sent = true;
  };
  await assert.rejects(
    client.deliverGenerated("forged", { deliveryId: "d", output: "x" }),
    /SESSION_UNBOUND/,
  );
  assert.equal(sent, false);
});

test("native turn admission carries the broker request identity", async () => {
  const client = new CodexNativeClient();
  client.sessions.set("owned", { cwd: "/tmp" });
  let captured;
  client.request = async (method, params) => {
    captured = { method, params };
    client.turns.set("turn", {
      done: true,
      status: "completed",
      messages: ["done"],
    });
    return { turn: { id: "turn" } };
  };
  await client.runTurn("owned", "fixed", { requestId: "broker-task-1" });
  assert.equal(captured.params.clientUserMessageId, "broker-task-1");
});
test("runTurn refuses a session not created by this client", async () => {
  const client = new CodexNativeClient();
  let called = false;
  client.request = async () => {
    called = true;
  };
  await assert.rejects(client.runTurn("unowned", "fixed"), /SESSION_UNBOUND/);
  assert.equal(called, false);
});
test("close rejects an unfinished turn rather than retaining its timeout", async () => {
  const client = new CodexNativeClient();
  client.sessions.set("owned", { cwd: "/tmp" });
  client.request = async () => ({ turn: { id: "turn" } });
  const running = client.runTurn("owned", "fixed", { timeout: 50 });
  const settled = assert.rejects(running, /CODEX_PROCESS_CLOSED/);
  await new Promise((resolve) => setImmediate(resolve));
  await client.close();
  await settled;
  assert.equal(client.turns.get("turn").resolve, undefined);
  assert.equal(client.turns.get("turn").reject, undefined);
});

test("turn timeout removes completion callbacks and permits late terminal events", async () => {
  const client = new CodexNativeClient();
  client.sessions.set("owned", { cwd: "/tmp" });
  client.request = async () => ({ turn: { id: "turn" } });
  await assert.rejects(
    client.runTurn("owned", "fixed", { timeout: 5 }),
    /CODEX_TURN_TIMEOUT/,
  );
  assert.equal(client.turns.get("turn").resolve, undefined);
  assert.equal(client.turns.get("turn").reject, undefined);
  await client.handle({
    method: "turn/completed",
    params: { turn: { id: "turn", status: "completed" } },
  });
  assert.equal(client.turns.get("turn").done, true);
});
