import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const prepare = fileURLToPath(new URL("../scripts/prepare-devkit-sdk.mjs", import.meta.url))
const commit = "a".repeat(40)
const version = `0.0.0-devkit.${commit}`

function buildFixture(t) {
  const scratch = mkdtempSync(join(tmpdir(), "agent-os-devkit-build-test-"))
  t.after(() => rmSync(scratch, { recursive: true, force: true }))
  const bundle = join(scratch, "bundle")
  const project = join(scratch, "web-next")
  const manifestPath = join(bundle, "manifest.json")
  const packagePath = join(project, "package.json")
  const adapterPath = join(project, "src/features/auth/devkit-browser-client.ts")
  mkdirSync(bundle)
  mkdirSync(join(project, "src/features/auth"), { recursive: true })
  const manifest = {
    schemaVersion: 1,
    sourceCommit: commit,
    packages: ["contracts", "client"].map(name => {
      const file = `devkit-${name}-${version}.tgz`
      const payload = `synthetic ${name} archive`
      writeFileSync(join(bundle, file), payload)
      return { name: `@devkit/${name}`, version, file, sha256: createHash("sha256").update(payload).digest("hex") }
    }),
    verification: { isolatedInstall: true, nodeImports: true, typescriptNodeNext: true, liveApi: false },
  }
  const packageJson = JSON.stringify({ name: "web-fixture", dependencies: { next: "16.2.9" } })
  writeFileSync(packagePath, packageJson)
  writeFileSync(adapterPath, "default browser factory")
  function run(pin = commit) {
    writeFileSync(manifestPath, JSON.stringify(manifest))
    return spawnSync(process.execPath, [prepare, bundle, pin], { cwd: project, encoding: "utf8" })
  }
  return { adapterPath, bundle, manifest, packageJson, packagePath, project, run }
}

test("the build stage installs the pinned SDK pair and uses the SDK browser factory", t => {
  const { adapterPath, bundle, manifest, packagePath, run } = buildFixture(t)
  const result = run()
  assert.equal(result.status, 0, result.stderr)
  const prepared = JSON.parse(readFileSync(packagePath, "utf8"))
  const [contracts, client] = manifest.packages.map(({ file }) => `file:${join(bundle, file)}`)
  assert.deepEqual(prepared.dependencies, { next: "16.2.9", "@devkit/contracts": contracts, "@devkit/client": client })
  assert.equal(prepared.resolutions["@devkit/contracts"], contracts)
  assert.match(readFileSync(adapterPath, "utf8"), /new ProjectAuthClient/)
})

test("a mismatched SDK revision or modified tarball leaves the build inputs untouched", t => {
  const { adapterPath, bundle, manifest, packageJson, packagePath, run } = buildFixture(t)
  const mismatch = run("b".repeat(40))
  assert.equal(mismatch.status, 1)
  assert.match(mismatch.stderr, /manifest/)

  writeFileSync(join(bundle, manifest.packages[1].file), "changed archive")
  const corrupt = run()
  assert.equal(corrupt.status, 1)
  assert.match(corrupt.stderr, /digest/)
  assert.equal(readFileSync(packagePath, "utf8"), packageJson)
  assert.equal(readFileSync(adapterPath, "utf8"), "default browser factory")
})
