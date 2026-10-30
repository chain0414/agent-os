import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { startService } from "../src/server.ts";
import { request } from "../src/client.ts";
test("Unix socket uses real credentials and refuses literal administrator role", async () => {
  const dir = mkdtempSync("/tmp/ac-http-");
  const service = await startService(dir);
  try {
    const token = readFileSync(join(dir, "admin-token"), "utf8");
    const health = await request({
      socketPath: service.socketPath,
      token,
      method: "health",
    });
    assert.equal(health.status, "ok");
    await assert.rejects(
      request({
        socketPath: service.socketPath,
        token: "admin",
        method: "registerSession",
        params: {},
      }),
      /UNAUTHORIZED/,
    );
    await assert.rejects(startService(dir), /SERVICE_ALREADY_RUNNING/);
    const binding = await request({
      socketPath: service.socketPath,
      token,
      method: "registerSession",
      params: {
        runtime: "dsh",
        instanceId: "host",
        sessionId: "s",
        cwd: dir,
        capabilities: { trustedOrigin: false },
      },
    });
    await assert.rejects(
      request({
        socketPath: service.socketPath,
        token: binding.token,
        method: "authorizeExecution",
        params: {},
      }),
      /FORBIDDEN/,
    );
  } finally {
    await service.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
test("stopping the service releases its process lock and permits clean restart", async () => {
  const dir = mkdtempSync("/tmp/ac-http-");
  try {
    const one = await startService(dir);
    await one.close();
    const two = await startService(dir);
    await two.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("stale process lock is refused without racing a competing recovery", async () => {
  const dir = mkdtempSync("/tmp/ac-http-");
  try {
    writeFileSync(join(dir, "service.lock"), "2147483647");
    await assert.rejects(startService(dir), /SERVICE_LOCK_STALE/);
    assert.equal(readFileSync(join(dir, "service.lock"), "utf8"), "2147483647");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("client settles when connection breaks during response body", async () => {
  const { createServer } = await import("node:http");
  const dir = mkdtempSync("/tmp/ac-cut-");
  const socketPath = join(dir, "cut.sock");
  const server = createServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.write('{"ok":');
    setImmediate(() => res.destroy());
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  try {
    const outcome = await Promise.race([
      request({ socketPath, token: "test-token", method: "health" }).then(
        () => "resolved",
        () => "rejected",
      ),
      new Promise((resolve) => setTimeout(() => resolve("hung"), 300)),
    ]);
    assert.equal(outcome, "rejected");
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
});
