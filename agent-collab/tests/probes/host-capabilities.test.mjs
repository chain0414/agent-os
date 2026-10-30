import test from "node:test";
import assert from "node:assert/strict";
import {
  currentDshOrigin,
  hostCapabilities,
  apply,
} from "../../packages/dsh-plugin/src/index.mjs";
import { inspectSchema, inspectDshSource } from "../../probes/capabilities.mjs";

test("DSH origin comes from loop agent, never model session arguments", () => {
  assert.deepEqual(
    currentDshOrigin(
      { agent: { id: "actual" }, callId: "call-1" },
      { sessionId: "forged" },
    ),
    { runtime: "dsh", sessionId: "actual", callId: "call-1" },
  );
  assert.throws(
    () => currentDshOrigin({ callId: "call-1" }, { sessionId: "forged" }),
    /HOST_ORIGIN_UNAVAILABLE/,
  );
});
test("static source availability never enables runtime delegation", () => {
  const r = inspectDshSource({
    tools: "readonly agent?: Agent",
    controller: "const source = {kind: 'user'}",
  });
  assert.equal(r.callerContextDeclared, true);
  assert.equal(r.promptCreatesUserInput, true);
  assert.equal(r.runtimeVerified, false);
  assert.equal(
    hostCapabilities({ agent: { id: "real" }, callId: "1" }).delegationEnabled,
    false,
  );
});
test("schemas prove field presence only, not runtime output delivery", () => {
  assert.deepEqual(
    inspectSchema({ properties: { toolOutput: { type: "object" } } }),
    { toolOutputDeclared: true, runtimeVerified: false },
  );
  assert.equal(
    inspectSchema({
      definitions: { TurnStartParams: { properties: { input: {} } } },
    }).toolOutputDeclared,
    false,
  );
});
test("plugin registers only capability inspection and disposes its contribution", async () => {
  let registered,
    removed = 0;
  const ctx = {
    tools: {
      register(d) {
        registered = d;
        return () => removed++;
      },
    },
    effect(f) {
      this.dispose = f();
    },
  };
  apply(ctx);
  assert.equal(registered.name, "agent_collab_capabilities");
  const result = await registered.execute(
    {},
    { agent: { id: "actual" }, callId: "c" },
  );
  assert.equal(result.delegationEnabled, false);
  ctx.dispose();
  assert.equal(removed, 1);
});
