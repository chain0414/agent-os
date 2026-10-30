import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile, rm, access } from "node:fs/promises";
import { join } from "node:path";
import { execFileSync, execFile } from "node:child_process";
import { promisify } from "node:util";
import { pathToFileURL, fileURLToPath } from "node:url";
const packagePath = fileURLToPath(
  new URL("../../packages/service/", import.meta.url),
);
test("packed service installs and runs without the AA checkout or source TypeScript", async () => {
  const temp = await mkdtemp("/tmp/ac-pack-");
  let service;
  try {
    execFileSync(process.execPath, [join(packagePath, "scripts/build.mjs")], {
      stdio: "pipe",
    });
    const packed = JSON.parse(
      execFileSync(
        "npm",
        ["pack", "--ignore-scripts", "--json", "--pack-destination", temp],
        {
          cwd: packagePath,
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
        },
      ),
    );
    await writeFile(join(temp, "package.json"), '{"private":true}');
    execFileSync(
      "npm",
      [
        "install",
        "--offline",
        "--ignore-scripts",
        "--no-audit",
        "--no-fund",
        join(temp, packed[0].filename),
      ],
      { cwd: temp, stdio: "pipe" },
    );
    const installed = join(
      temp,
      "node_modules/@agents-anywhere/agent-collab-service",
    );
    await assert.rejects(access(join(installed, "src")));
    await access(join(installed, "lib/contracts/1.0/request.schema.json"));
    const { startService } = await import(
      pathToFileURL(join(installed, "lib/server.js")).href
    );
    const { request } = await import(
      pathToFileURL(join(installed, "lib/client.js")).href
    );
    service = await startService(join(temp, "state"));
    const token = await readFile(join(temp, "state/admin-token"), "utf8");
    const health = await request({
      socketPath: service.socketPath,
      token,
      method: "health",
    });
    assert.equal(health.status, "ok");
    assert.equal(health.nativeInteropVerified, false);
    const cliRun = await promisify(execFile)(process.execPath, [
      join(installed, "bin/agent-collab.mjs"),
      "health",
      "--data-dir",
      join(temp, "state"),
    ]);
    const cli = JSON.parse(cliRun.stdout);
    assert.equal(cli.status, "ok");
  } finally {
    await service?.close();
    await rm(temp, { recursive: true, force: true });
  }
});
