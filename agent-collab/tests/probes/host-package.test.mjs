import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, mkdir, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

test("DSH published artifact imports outside the checkout without AA dependencies", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-collab-dsh-pack-"));
  try {
    const cwd = fileURLToPath(
      new URL("../../packages/dsh-plugin/", import.meta.url),
    );
    const pack = spawnSync(
      "npm",
      ["pack", "--ignore-scripts", "--json", "--pack-destination", dir],
      { cwd, encoding: "utf8", timeout: 30_000 },
    );
    assert.equal(pack.status, 0, "local npm pack failed");
    const tarball = (await readdir(dir)).find((name) => name.endsWith(".tgz"));
    assert.ok(tarball);
    const extraction = join(dir, "isolated");
    await mkdir(extraction);
    const unpack = spawnSync("tar", [
      "-xf",
      join(dir, tarball),
      "-C",
      extraction,
    ]);
    assert.equal(unpack.status, 0);
    const pkg = await import(
      pathToFileURL(join(extraction, "package/src/index.mjs")).href
    );
    assert.equal(
      pkg.hostCapabilities({ agent: { id: "s" }, callId: "c" })
        .delegationEnabled,
      false,
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
