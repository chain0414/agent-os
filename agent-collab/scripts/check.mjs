import { readdir } from "node:fs/promises";
import { spawnSync } from "node:child_process";
const roots = ["packages/service/test", "tests/installation", "tests/probes", "tests/native"];
const tests = [];
for (const root of roots) {
  const before = tests.length;
  for (const name of await readdir(new URL(`../${root}/`, import.meta.url)))
    if (/\.test\.(?:ts|mjs)$/.test(name)) tests.push(`${root}/${name}`);
  if (tests.length === before) throw new Error(`No tests found in ${root}`);
}
if (!tests.length) throw new Error("No tests found");
const cwd = new URL("../", import.meta.url);
const result = spawnSync(
  process.execPath,
  ["--experimental-strip-types", "--test", ...tests.sort()],
  { cwd, stdio: "inherit" },
);
process.exitCode = result.status ?? 1;
