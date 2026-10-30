#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import {
  mkdtemp,
  readFile,
  readdir,
  rm,
  access,
  mkdir,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inspectDshSource, inspectSchema } from "./capabilities.mjs";

const args = process.argv.slice(2),
  options = {};
for (let i = 0; i < args.length; i += 2) {
  if (!["--codex-bin", "--dsh-source"].includes(args[i]) || !args[i + 1]) {
    process.stderr.write(
      "Usage: node probes/run.mjs [--codex-bin PATH] [--dsh-source PATH]\n",
    );
    process.exit(2);
  }
  options[args[i]] = args[i + 1];
}
function invoke(bin, argv, home) {
  const r = spawnSync(bin, argv, {
    cwd: home,
    env: { PATH: process.env.PATH, CODEX_HOME: home },
    encoding: "utf8",
    timeout: 20_000,
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return r.status === 0 ? r.stdout : null;
}
async function inspectCli() {
  const bundled = "/Applications/Codex.app/Contents/Resources/codex";
  let bin = options["--codex-bin"];
  let distribution = bin ? "explicit" : "path";
  if (!bin) {
    try {
      await access(bundled);
      bin = bundled;
      distribution = "app-bundled";
    } catch {
      bin = "codex";
    }
  }
  const temp = await mkdtemp(join(tmpdir(), "agent-collab-schema-"));
  let version = null;
  try {
    const versionText = invoke(bin, ["--version"], temp);
    version =
      versionText?.match(
        /^codex-cli ([0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?)/,
      )?.[1] ?? null;
    if (!version)
      return {
        runtime: "codex",
        distribution,
        status: "unavailable",
        runtimeVerified: false,
      };
    const schemaDirectory = join(temp, "schema");
    await mkdir(schemaDirectory);
    const generated = invoke(
      bin,
      [
        "app-server",
        "generate-json-schema",
        "--experimental",
        "--out",
        schemaDirectory,
      ],
      temp,
    );
    if (generated === null)
      return {
        runtime: "codex",
        distribution,
        version,
        status: "schema-unavailable",
        runtimeVerified: false,
      };
    let toolOutputDeclared = false,
      turnStartSchemaFound = false,
      injectItemsDeclared = false,
      injectItemsUnconstrained = false;
    async function scan(dir) {
      for (const entry of await readdir(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) await scan(path);
        else if (entry.name === "TurnStartParams.json") {
          turnStartSchemaFound = true;
          toolOutputDeclared = inspectSchema(
            JSON.parse(await readFile(path, "utf8")),
          ).toolOutputDeclared;
        } else if (entry.name === "ThreadInjectItemsParams.json") {
          const schema = JSON.parse(await readFile(path, "utf8"));
          injectItemsDeclared = true;
          injectItemsUnconstrained = schema.properties?.items?.items === true;
        }
      }
    }
    await scan(schemaDirectory);
    return {
      runtime: "codex",
      distribution,
      version,
      evidence: "local-cli-schema",
      status: "inspected",
      experimentalSchema: true,
      turnStartSchemaFound,
      toolOutputDeclared,
      injectItemsDeclared,
      injectItemsUnconstrained,
      functionCallOutputAcceptedVerified: false,
      callerIdentityVerified: false,
      generatedDeliveryVerified: false,
      runtimeVerified: false,
    };
  } catch {
    return {
      runtime: "codex",
      distribution,
      version,
      status: "inspection-failed",
      runtimeVerified: false,
    };
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
}
async function inspectDsh() {
  if (!options["--dsh-source"])
    return {
      runtime: "dsh",
      status: "source-not-supplied",
      runtimeVerified: false,
    };
  const source = resolve(options["--dsh-source"]);
  try {
    const tools = await readFile(
      join(source, "packages/core/tools/src/index.ts"),
      "utf8",
    );
    const controller = await readFile(
      join(source, "packages/api/session-controller/src/index.ts"),
      "utf8",
    );
    const pkg = JSON.parse(
      await readFile(join(source, "packages/core/tools/package.json"), "utf8"),
    );
    const version =
      typeof pkg.version === "string" &&
      /^[0-9A-Za-z.+-]{1,80}$/.test(pkg.version)
        ? pkg.version
        : null;
    return {
      runtime: "dsh",
      version,
      evidence: "source-checkout",
      status: "inspected",
      ...inspectDshSource({ tools, controller }),
      generatedDeliveryVerified: false,
      safeRunningCancellationVerified: false,
    };
  } catch {
    return {
      runtime: "dsh",
      status: "inspection-unavailable",
      runtimeVerified: false,
    };
  }
}
// No raw CLI output, config values, transcript contents or exception objects are emitted.
const report = {
  schemaVersion: 1,
  mode: "read-only-static",
  delegationEnabled: false,
  checks: await Promise.all([inspectCli(), inspectDsh()]),
};
process.stdout.write(JSON.stringify(report, null, 2) + "\n");
