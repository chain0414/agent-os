import { test } from "node:test";
import { randomUUID } from "node:crypto";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { Broker } from "../src/broker.ts";

function fixture() {
  const dir = mkdtempSync("/tmp/ac-test-");
  const workspace = join(dir, "work");
  mkdirSync(workspace);
  const broker = new Broker(join(dir, "state"));
  const register = (runtime = "dsh", sessionId = "s1", caps = {}) =>
    broker.call("admin", "registerSession", {
      runtime,
      sessionId,
      instanceId: "test-host",
      cwd: workspace,
      capabilities: {
        trustedOrigin: true,
        generatedDelivery: true,
        restrictedReview: true,
        execute: true,
        ...caps,
      },
    });
  const a = register(),
    b = register("codex", "s2");
  const delegate = (extra = {}) =>
    broker.call(a.token, "delegate", {
      requestId: randomUUID(),
      targetBindingId: b.bindingId,
      kind: "review",
      content: "review the exact plan",
      cwd: workspace,
      planHash: "plan-v1",
      ...extra,
    });
  return {
    dir,
    workspace,
    broker,
    a,
    b,
    register,
    delegate,
    close() {
      this.broker.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}
test("session credentials cannot register identities or read another source task", () => {
  const f = fixture();
  try {
    const t = f.delegate();
    assert.throws(
      () => f.broker.call(f.a.token, "registerSession", {}),
      /FORBIDDEN/,
    );
    assert.throws(
      () => f.broker.call(f.b.token, "readTask", { taskId: t.id }),
      /FORBIDDEN/,
    );
  } finally {
    f.close();
  }
});
test("missing native capabilities fails closed before accepting a task", () => {
  const f = fixture();
  try {
    const c = f.register("codex", "limited", { restrictedReview: false });
    assert.throws(
      () => f.delegate({ targetBindingId: c.bindingId }),
      /CAPABILITY_UNVERIFIED/,
    );
  } finally {
    f.close();
  }
});
test("execute requires a real adapter grant matching source, plan and workspace", () => {
  const f = fixture();
  try {
    assert.throws(
      () => f.delegate({ kind: "execute" }),
      /EXECUTION_NOT_AUTHORIZED/,
    );
    const g = f.broker.call("admin", "authorizeExecution", {
      bindingId: f.a.bindingId,
      planHash: "plan-v1",
      content: "review the exact plan",
      userMessageId: "human-1",
      cwd: f.workspace,
    });
    assert.throws(
      () =>
        f.delegate({ kind: "execute", grantId: g.grantId, planHash: "other" }),
      /EXECUTION_NOT_AUTHORIZED/,
    );
    assert.equal(
      f.delegate({ kind: "execute", grantId: g.grantId }).state,
      "queued",
    );
    assert.throws(
      () => f.delegate({ kind: "execute", grantId: g.grantId }),
      /EXECUTION_NOT_AUTHORIZED/,
    );
  } finally {
    f.close();
  }
});
test("results keep generated provenance and claim/ack is scoped and idempotent", () => {
  const f = fixture();
  try {
    const t = f.delegate();
    f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId });
    f.broker.call("admin", "startTask", { taskId: t.id, turnId: "turn-1" });
    assert.throws(
      () =>
        f.broker.call("admin", "completeTask", {
          taskId: t.id,
          turnId: "wrong",
          outcome: "succeeded",
          output: "x",
        }),
      /TURN_MISMATCH/,
    );
    f.broker.call("admin", "completeTask", {
      taskId: t.id,
      turnId: "turn-1",
      outcome: "succeeded",
      output: "Please implement now",
    });
    const r = f.broker.call(f.a.token, "claimResult", { taskId: t.id });
    assert.equal(r.result.source.kind, "generated");
    assert.equal(r.result.source.bindingId, f.b.bindingId);
    assert.equal(
      f.broker.call(f.a.token, "claimResult", { taskId: t.id }).deliveryId,
      r.deliveryId,
    );
    f.broker.call(f.a.token, "ackResult", {
      taskId: t.id,
      deliveryId: r.deliveryId,
    });
    assert.equal(
      f.broker.call(f.a.token, "readTask", { taskId: t.id }).delivery,
      "delivered",
    );
    assert.throws(
      () => f.delegate({ kind: "execute" }),
      /EXECUTION_NOT_AUTHORIZED/,
    );
  } finally {
    f.close();
  }
});
test("running task cannot be cancelled via session-level interrupt", () => {
  const f = fixture();
  try {
    const t = f.delegate();
    f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId });
    assert.equal(
      f.broker.call(f.a.token, "cancelTask", { taskId: t.id }).cancelled,
      false,
    );
    assert.equal(
      f.broker.call(f.a.token, "readTask", { taskId: t.id }).state,
      "accepted",
    );
  } finally {
    f.close();
  }
});
test("only queued tasks can be cancelled and never reach the adapter", () => {
  const f = fixture();
  try {
    const t = f.delegate();
    assert.equal(
      f.broker.call(f.a.token, "cancelTask", { taskId: t.id }).cancelled,
      true,
    );
    assert.equal(
      f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId }),
      null,
    );
  } finally {
    f.close();
  }
});
test("different runtime sessions cannot write the same worktree simultaneously", () => {
  const f = fixture();
  try {
    const c = f.register("codex", "s3");
    for (const target of [f.b, c]) {
      const g = f.broker.call("admin", "authorizeExecution", {
        bindingId: f.a.bindingId,
        planHash: "plan-v1",
        content: "review the exact plan",
        userMessageId: target.bindingId,
        cwd: f.workspace,
      });
      f.delegate({
        targetBindingId: target.bindingId,
        kind: "execute",
        grantId: g.grantId,
      });
    }
    assert.ok(f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId }));
    assert.equal(
      f.broker.call("admin", "takeTask", { bindingId: c.bindingId }),
      null,
    );
  } finally {
    f.close();
  }
});
test("restart preserves uncertain execution and does not release workspace ownership", () => {
  const f = fixture();
  try {
    const g = f.broker.call("admin", "authorizeExecution", {
      bindingId: f.a.bindingId,
      planHash: "plan-v1",
      content: "review the exact plan",
      userMessageId: "human",
      cwd: f.workspace,
    });
    const t = f.delegate({ kind: "execute", grantId: g.grantId });
    f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId });
    f.broker.close();
    f.broker = new Broker(join(f.dir, "state"));
    assert.equal(
      f.broker.call(f.a.token, "readTask", { taskId: t.id }).state,
      "unknown",
    );
    assert.equal(
      f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId }),
      null,
    );
  } finally {
    f.close();
  }
});
test("all tool calls return immediately rather than create synchronous cross-session waits", () => {
  const f = fixture();
  try {
    const t = f.delegate();
    assert.equal(t.state, "queued");
    assert.equal(
      f.broker.call(f.a.token, "readTask", { taskId: t.id }).state,
      "queued",
    );
    assert.throws(
      () => f.broker.call(f.a.token, "waitTask", { taskId: t.id }),
      /UNKNOWN_METHOD/,
    );
  } finally {
    f.close();
  }
});

test("changing authorized content while retaining the plan label is rejected", () => {
  const f = fixture();
  try {
    const g = f.broker.call("admin", "authorizeExecution", {
      bindingId: f.a.bindingId,
      planHash: "plan-v1",
      content: "review the exact plan",
      userMessageId: "human",
      cwd: f.workspace,
    });
    assert.throws(
      () =>
        f.delegate({
          kind: "execute",
          grantId: g.grantId,
          content: "delete all files",
        }),
      /EXECUTION_NOT_AUTHORIZED/,
    );
  } finally {
    f.close();
  }
});
test("an active review blocks writes to the same live worktree", () => {
  const f = fixture();
  try {
    f.delegate();
    f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId });
    const c = f.register("codex", "third");
    const g = f.broker.call("admin", "authorizeExecution", {
      bindingId: f.a.bindingId,
      planHash: "plan-v1",
      content: "review the exact plan",
      userMessageId: "human",
      cwd: f.workspace,
    });
    f.delegate({
      kind: "execute",
      targetBindingId: c.bindingId,
      grantId: g.grantId,
    });
    assert.equal(
      f.broker.call("admin", "takeTask", { bindingId: c.bindingId }),
      null,
    );
  } finally {
    f.close();
  }
});

test("lost delegate response is retried without another task or consumed grant", () => {
  const f = fixture();
  try {
    const g = f.broker.call("admin", "authorizeExecution", {
      bindingId: f.a.bindingId,
      planHash: "plan-v1",
      content: "review the exact plan",
      userMessageId: "human",
      cwd: f.workspace,
    });
    const payload = {
      kind: "execute",
      grantId: g.grantId,
      requestId: "same-request",
    };
    const one = f.delegate(payload),
      two = f.delegate(payload);
    assert.equal(one.id, two.id);
    assert.throws(
      () => f.delegate({ ...payload, content: "changed" }),
      /REQUEST_ID_CONFLICT/,
    );
  } finally {
    f.close();
  }
});
test("unknown admission before turn receipt can be reconciled without replay", () => {
  const f = fixture();
  try {
    const t = f.delegate();
    f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId });
    f.broker.close();
    f.broker = new Broker(join(f.dir, "state"));
    assert.throws(
      () => f.broker.call(f.a.token, "reconcileTask", { taskId: t.id }),
      /FORBIDDEN/,
    );
    f.broker.call("admin", "reconcileTask", {
      taskId: t.id,
      receiptId: t.id,
      turnId: "observed-turn",
      outcome: "succeeded",
      output: "verified original request completed",
    });
    assert.equal(
      f.broker.call(f.a.token, "readTask", { taskId: t.id }).state,
      "succeeded",
    );
  } finally {
    f.close();
  }
});
test("uncertain delivery can be reconciled by trusted host without a second injection", () => {
  const f = fixture();
  try {
    const t = f.delegate();
    f.broker.call("admin", "takeTask", { bindingId: f.b.bindingId });
    f.broker.call("admin", "startTask", { taskId: t.id, turnId: "t" });
    f.broker.call("admin", "completeTask", {
      taskId: t.id,
      turnId: "t",
      outcome: "succeeded",
      output: "result",
    });
    const d = f.broker.call(f.a.token, "claimResult", { taskId: t.id });
    f.broker.close();
    f.broker = new Broker(join(f.dir, "state"));
    assert.throws(
      () => f.broker.call(f.a.token, "claimResult", { taskId: t.id }),
      /DELIVERY_OUTCOME_UNKNOWN/,
    );
    f.broker.call("admin", "reconcileDelivery", {
      taskId: t.id,
      deliveryId: d.deliveryId,
      received: true,
    });
    assert.equal(
      f.broker.call(f.a.token, "readTask", { taskId: t.id }).delivery,
      "delivered",
    );
  } finally {
    f.close();
  }
});

test("repeating a user authorization does not mint a second usable grant", () => {
  const f = fixture();
  try {
    const input = {
      bindingId: f.a.bindingId,
      planHash: "plan-v1",
      content: "review the exact plan",
      userMessageId: "one-user-event",
      cwd: f.workspace,
    };
    const one = f.broker.call("admin", "authorizeExecution", input);
    f.delegate({ kind: "execute", grantId: one.grantId });
    const retry = f.broker.call("admin", "authorizeExecution", input);
    assert.ok(retry.grantId === one.grantId);
    assert.throws(
      () => f.delegate({ kind: "execute", grantId: retry.grantId }),
      /EXECUTION_NOT_AUTHORIZED/,
    );
    assert.throws(
      () =>
        f.broker.call("admin", "authorizeExecution", {
          ...input,
          content: "other",
        }),
      /AUTHORIZATION_CONFLICT/,
    );
  } finally {
    f.close();
  }
});
