import test from "node:test";
import assert from "node:assert/strict";
import {
  mkdtemp,
  writeFile,
  readFile,
  chmod,
  access,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

test("schema probe uses a temporary home and excludes inherited credentials", async () => {
  const directory = await mkdtemp(join(tmpdir(), "collab-fake-cli-"));
  try {
    const executable = join(directory, "fake-codex");
    const receipt = join(directory, "home-receipt.json");
    const fake = `#!${process.execPath}
const fs=require('node:fs');const path=require('node:path');
if(process.env.AGENT_COLLAB_TEST_SECRET||process.cwd()!==fs.realpathSync(process.env.CODEX_HOME))process.exit(4);
fs.writeFileSync(${JSON.stringify(receipt)},JSON.stringify({home:process.env.CODEX_HOME}));
if(process.argv[2]==='--version'){console.log('codex-cli 0.0.1');process.exit(0);}
if(process.argv[2]!=='app-server'||process.argv[3]!=='generate-json-schema')process.exit(5);
const out=process.argv[process.argv.indexOf('--out')+1];
fs.writeFileSync(path.join(out,'TurnStartParams.json'),JSON.stringify({properties:{toolOutput:{type:'object'}}}));
`;
    await writeFile(executable, fake);
    await chmod(executable, 0o700);
    const probe = fileURLToPath(
      new URL("../../probes/run.mjs", import.meta.url),
    );
    const result = spawnSync(
      process.execPath,
      [probe, "--codex-bin", executable],
      {
        encoding: "utf8",
        timeout: 5000,
        env: {
          ...process.env,
          AGENT_COLLAB_TEST_SECRET: "test-sentinel-do-not-inherit",
        },
      },
    );
    assert.equal(result.status, 0);
    const report = JSON.parse(result.stdout);
    assert.equal(report.checks[0].toolOutputDeclared, true);
    assert.equal(report.checks[0].runtimeVerified, false);
    assert.equal(report.delegationEnabled, false);
    assert.ok(!result.stdout.includes("test-sentinel-do-not-inherit"));
    const { home } = JSON.parse(await readFile(receipt, "utf8"));
    assert.notEqual(home, directory);
    await assert.rejects(access(home), { code: "ENOENT" });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
