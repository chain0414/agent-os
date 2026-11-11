import { createHash } from "node:crypto"
import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"

function fail(message) {
  console.error(message)
  process.exit(1)
}

function prepare(bundleDir, sourceCommit) {
  const manifest = JSON.parse(readFileSync(resolve(bundleDir, "manifest.json"), "utf8"))
  if (
    manifest?.schemaVersion !== 1 || manifest.sourceCommit !== sourceCommit ||
    !Array.isArray(manifest.packages) || manifest.packages.length !== 2 ||
    manifest.verification?.isolatedInstall !== true || manifest.verification.nodeImports !== true ||
    manifest.verification.typescriptNodeNext !== true
  ) {
    fail("DevKit SDK manifest does not describe a verified bundle for the pinned commit.")
  }

  const version = `0.0.0-devkit.${sourceCommit}`
  const dependencies = Object.fromEntries(["contracts", "client"].map(packageName => {
    const name = `@devkit/${packageName}`
    const file = `devkit-${packageName}-${version}.tgz`
    const entry = manifest.packages.find(item => item?.name === name)
    if (entry?.version !== version || entry.file !== file) {
      fail("DevKit SDK package manifest does not match the pinned commit.")
    }
    const path = resolve(bundleDir, file)
    const digest = createHash("sha256").update(readFileSync(path)).digest("hex")
    if (entry.sha256 !== digest) fail("DevKit SDK tarball digest does not match the manifest.")
    return [name, `file:${path}`]
  }))

  const project = JSON.parse(readFileSync("package.json", "utf8"))
  project.dependencies = { ...project.dependencies, ...dependencies }
  // Yarn must resolve the client's exact contracts dependency from this bundle.
  project.resolutions = { ...project.resolutions, "@devkit/contracts": dependencies["@devkit/contracts"] }
  writeFileSync("package.json", `${JSON.stringify(project, null, 2)}\n`)
  copyFileSync(new URL("./devkit-browser-client.ts.in", import.meta.url), "src/features/auth/devkit-browser-client.ts")
}

const [bundleDir, sourceCommit, ...extra] = process.argv.slice(2)
if (!bundleDir || !/^[a-f0-9]{40}$/.test(sourceCommit ?? "") || extra.length) {
  fail("Supply a DevKit SDK bundle directory and its full Git commit.")
}
if (existsSync(".git") || existsSync("../.git")) {
  fail("Prepare the DevKit SDK in a disposable build directory.")
}
try {
  prepare(bundleDir, sourceCommit)
} catch {
  fail("Could not read the DevKit SDK manifest or tarballs, or prepare the Web build inputs.")
}
