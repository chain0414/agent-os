import test from "node:test";
import assert from "node:assert/strict";
import { NativeCoordinator } from "../../native/coordinator.mjs";

test("native dispatch returns a task and later delivers generated results with exact receipt", async () => {
  const events = [];
  const rpc = async (auth, method, p) => {
    events.push({ auth, method, p });
    if (method === "delegate") return { id: "task-1", state: "queued" };
    if (method === "takeTask")
      return {
        id: "task-1",
        kind: "review",
        content: "plan",
        source: "from",
        target: "to",
      };
    if (method === "claimResult")
      return {
        deliveryId: "delivery-1",
        result: {
          output: "actual review",
          source: { kind: "generated", bindingId: "to" },
        },
      };
    return {};
  };
  const c = new NativeCoordinator(rpc);
  c.attach({
    bindingId: "from",
    token: "source-credential",
    sessionId: "dsh-1",
    adapter: {
      deliverGenerated: async (session, r) => {
        assert.equal(session, "dsh-1");
        assert.equal(r.deliveryId, "delivery-1");
        events.push({ method: "native-delivery" });
        return { received: true, deliveryId: r.deliveryId };
      },
    },
  });
  c.attach({
    bindingId: "to",
    token: "target-credential",
    sessionId: "codex-1",
    adapter: {
      runTurn: async (session, content, { onStart }) => {
        assert.equal(session, "codex-1");
        assert.equal(content, "plan");
        await onStart("turn-1");
        return { turnId: "turn-1", output: "actual review" };
      },
    },
  });
  const result = await c.delegate(
    "from",
    { sessionId: "dsh-1", callId: "kernel-call-1" },
    {
      targetBindingId: "to",
      kind: "review",
      content: "plan",
      requestId: "native-call-1",
    },
  );
  assert.equal(result.state, "queued");
  assert.equal(events.length, 1);
  await c.processOne("to");
  assert.ok(
    events.find((e) => e.method === "startTask" && e.p.turnId === "turn-1"),
  );
  assert.ok(
    events.find((e) => e.method === "completeTask" && e.p.turnId === "turn-1"),
  );
  assert.ok(
    events.findIndex((e) => e.method === "ackResult") >
      events.findIndex((e) => e.method === "native-delivery"),
  );
});

test("wrong native session cannot delegate using another binding", async () => {
  const c = new NativeCoordinator(async () => {
    throw new Error("RPC_SHOULD_NOT_RUN");
  });
  c.attach({
    bindingId: "from",
    token: "credential",
    sessionId: "dsh-1",
    adapter: {},
  });
  await assert.rejects(
    c.delegate("from", { sessionId: "dsh-other", callId: "call" }, {}),
    /ORIGIN_MISMATCH/,
  );
});

test("failed native delivery does not acknowledge or replay model execution", async () => {
  const calls = [];
  const c = new NativeCoordinator(async (_auth, method) => {
    calls.push(method);
    if (method === "takeTask")
      return { id: "t", source: "a", kind: "review", content: "plan" };
    if (method === "claimResult")
      return { deliveryId: "d", result: { output: "review" } };
    return {};
  });
  c.attach({
    bindingId: "a",
    token: "a-token",
    sessionId: "a-session",
    adapter: {
      deliverGenerated: async () => {
        throw new Error("NATIVE_DELIVERY_FAILED");
      },
    },
  });
  c.attach({
    bindingId: "b",
    token: "b-token",
    sessionId: "b-session",
    adapter: {
      runTurn: async (_s, _p, { onStart }) => {
        await onStart("turn");
        return { turnId: "turn", output: "review" };
      },
    },
  });
  await assert.rejects(c.processOne("b"), /NATIVE_DELIVERY_FAILED/);
  assert.equal(calls.filter((c) => c === "completeTask").length, 1);
  assert.equal(calls.includes("ackResult"), false);
});

test("a resolved delivery without a matching native receipt is not acknowledged", async () => {
  const methods = [];
  const c = new NativeCoordinator(async (_a, m) => {
    methods.push(m);
    return m === "claimResult"
      ? { deliveryId: "d1", result: { output: "data" } }
      : {};
  });
  c.attach({
    bindingId: "source",
    token: "token",
    sessionId: "native",
    adapter: {
      deliverGenerated: async () => ({ received: false, deliveryId: "d1" }),
    },
  });
  await assert.rejects(c.deliver("source", "task"), /DELIVERY_NOT_CONFIRMED/);
  assert.equal(methods.includes("ackResult"), false);
});

test("native receipt survives an ack failure without injecting twice", async () => {
  let injections = 0,
    acks = 0;
  const c = new NativeCoordinator(async (_a, m) => {
    if (m === "claimResult")
      return { deliveryId: "stable", result: { output: "review" } };
    if (m === "ackResult" && ++acks === 1) throw new Error("ACK_RESPONSE_LOST");
    return {};
  });
  c.attach({
    bindingId: "a",
    token: "a-token",
    sessionId: "a-session",
    adapter: {
      deliverGenerated: async () => {
        injections++;
        return { received: true, deliveryId: "stable" };
      },
    },
  });
  await assert.rejects(c.deliver("a", "task"), /ACK_RESPONSE_LOST/);
  await c.deliver("a", "task");
  assert.equal(injections, 1);
  assert.equal(acks, 2);
});

test("uncertain native injection is not automatically repeated", async () => {
  let injections = 0;
  const c = new NativeCoordinator(async () => ({
    deliveryId: "unknown",
    result: { output: "review" },
  }));
  c.attach({
    bindingId: "a",
    token: "token",
    sessionId: "session",
    adapter: {
      deliverGenerated: async () => {
        injections++;
        throw new Error("NATIVE_ACK_LOST");
      },
    },
  });
  await assert.rejects(c.deliver("a", "task"), /NATIVE_ACK_LOST/);
  await assert.rejects(c.deliver("a", "task"), /DELIVERY_OUTCOME_UNKNOWN/);
  assert.equal(injections, 1);
});
