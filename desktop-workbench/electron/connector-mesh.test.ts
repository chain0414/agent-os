import assert from "node:assert/strict";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { createConnectorMesh } from "./connector-mesh";
import { ControlServiceClient } from "./generated/connector-control";

test("a blocked Connector control write reports its deadline without an unhandled rejection", async () => {
  const mesh = await createConnectorMesh({ unixPath: "/nonexistent/aa-test.sock" }, "mk_test", "test");
  Object.assign(mesh.client, {
    connectWithin: async () => undefined,
    send: async (frame: { kind: string }) => {
      if (frame.kind === "call.open") await delay(100);
    },
    localBudgetMs: () => 20,
  });
  try {
    await assert.rejects(new ControlServiceClient(mesh).getState({ timeoutMs: 20 }), {
      code: "deadline_exceeded",
    });
  } finally {
    await mesh.close();
  }
});
