import { spawn } from "node:child_process";
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  symlink,
  rm,
  chmod,
} from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { createInterface } from "node:readline";
export class DshClient {
  constructor(options = {}) {
    this.options = options;
    this.pending = new Map();
    this.sessions = new Map();
    this.next = 0;
  }
  async start() {
    this.root = await mkdtemp(join(tmpdir(), "ac-dsh-"));
    await chmod(this.root, 0o700);
    const profiles =
      this.options.profilesDir ?? join(homedir(), ".dsh/profiles");
    const profile = join(this.root, "profiles/headless");
    await mkdir(profile, { recursive: true });
    await symlink(
      join(profiles, "node_modules"),
      join(this.root, "profiles/node_modules"),
    );
    await writeFile(
      join(profile, "package.json"),
      JSON.stringify({
        name: "agent-collab-dsh-profile",
        private: true,
        dsh: {
          profile: {
            bundles: ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-headless"],
          },
        },
      }),
      { mode: 0o600 },
    );
    await writeFile(join(profile, "cordis.yml"), "[]", { mode: 0o600 });
    await writeFile(join(profile, "cordis.patch.yml"), "[]", { mode: 0o600 });
    const patch = join(this.root, "native.patch.yml");
    await writeFile(
      patch,
      JSON.stringify([
        { id: "headless-startup", disabled: true },
        { id: "headless-runner", disabled: true },
        { id: "tools", config: { mode: "native" } },
        {
          id: "llm-deepseek",
          config: {
            apiKeyEnv: "DEEPSEEK_API_KEY",
            thinking: "disabled",
            maxTokens: 2048,
            retryPolicy: { mode: "normal", maxRetries: 0 },
          },
        },
        {
          insert: [
            {
              id: "agent-collab-native-driver",
              name: fileURLToPath(new URL("./dsh-host.mjs", import.meta.url)),
            },
          ],
        },
      ]),
      { mode: 0o600 },
    );
    const require = createRequire(join(profiles, "package.json"));
    const yaml = require("yaml");
    let apiKey = this.options.apiKey ?? process.env.DEEPSEEK_API_KEY;
    if (!apiKey) {
      try {
        const d = yaml.parse(
          await readFile(join(homedir(), ".dsh/.credentials.yaml"), "utf8"),
        );
        apiKey = d?.refs?.DEEPSEEK_API_KEY;
      } catch {}
    }
    if (typeof apiKey !== "string" || !apiKey) {
      await this.close();
      throw new Error("DEEPSEEK_CREDENTIAL_UNAVAILABLE");
    }
    const bin =
      this.options.dshBin ??
      "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh";
    this.child = spawn(bin, ["--profile", "headless", "--patch", patch], {
      cwd: this.root,
      env: {
        PATH: process.env.PATH,
        HOME: homedir(),
        DSH_HOME: this.root,
        DSH_TOOLS_MODE: "native",
        DSH_TELEMETRY_DISABLED: "1",
        DEEPSEEK_API_KEY: apiKey,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.diagnostic = [];
    this.child.stderr.on("data", (chunk) => {
      this.diagnostic.push(chunk.toString());
      if (this.diagnostic.length > 80) this.diagnostic.shift();
    });
    this.child.stdin.on("error", () => {});
    this.lines = createInterface({ input: this.child.stdout });
    this.lines.on("line", (line) => {
      let m;
      try {
        m = JSON.parse(line);
      } catch {
        return;
      }
      if (!m.agentCollab) return;
      if (m.method === "ready") {
        this.ready?.();
        return;
      }
      if (m.method === "toolCall") {
        const p = m.params;
        const h = this.sessions.get(p.origin.sessionId)?.onTool;
        Promise.resolve()
          .then(() => h?.(p) ?? { error: "TOOL_HANDLER_UNAVAILABLE" })
          .then((result) =>
            this.child.stdin.write(
              JSON.stringify({
                agentCollab: true,
                method: "toolResult",
                id: m.id,
                result,
              }) + "\n",
            ),
          )
          .catch(() =>
            this.child.stdin.write(
              JSON.stringify({
                agentCollab: true,
                method: "toolResult",
                id: m.id,
                result: { error: "TOOL_HANDLER_FAILED" },
              }) + "\n",
            ),
          );
        return;
      }
      if (m.method === "turnStarted") {
        const e = this.pending.get(m.params.requestId);
        if (e)
          e.startPromise = Promise.resolve().then(() =>
            e.onStart?.(m.params.turnId),
          );
        e?.startPromise?.catch(e.reject);
        return;
      }
      const e = this.pending.get(m.id);
      if (e) {
        this.pending.delete(m.id);
        clearTimeout(e.timer);
        Promise.resolve(e.startPromise)
          .then(() =>
            m.error
              ? e.reject(
                  Object.assign(new Error(m.error.code), {
                    safeDetails: m.error,
                  }),
                )
              : e.resolve(m.result),
          )
          .catch(e.reject);
      }
    });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("DSH_START_TIMEOUT")),
        30000,
      );
      this.ready = () => {
        clearTimeout(timer);
        resolve();
      };
      this.child.once("exit", () => {
        clearTimeout(timer);
        reject(new Error("DSH_PROCESS_EXITED"));
      });
      this.child.once("error", () => {
        clearTimeout(timer);
        reject(new Error("DSH_PROCESS_UNAVAILABLE"));
      });
    });
    return this;
  }
  request(method, params, onStart) {
    return new Promise((resolve, reject) => {
      const id = ++this.next;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("DSH_REQUEST_TIMEOUT"));
      }, 120000);
      this.pending.set(id, { resolve, reject, timer, onStart });
      this.child.stdin.write(
        JSON.stringify({ agentCollab: true, id, method, params }) + "\n",
      );
    });
  }
  async createSession(options) {
    const r = await this.request("createSession", {
      cwd: options.cwd,
      tools: options.tools ?? [],
    });
    this.sessions.set(r.sessionId, { onTool: options.onTool });
    return r;
  }
  async runTurn(sessionId, content, options = {}) {
    if (options.mode === "execute")
      throw new Error("DSH_EXECUTION_UNSUPPORTED");
    return this.request(
      "runTurn",
      { sessionId, content, requestId: options.requestId },
      options.onStart,
    );
  }
  async deliverGenerated(sessionId, result) {
    return this.request("deliverGenerated", { sessionId, result });
  }
  async close() {
    for (const e of this.pending.values()) {
      clearTimeout(e.timer);
      e.reject(new Error("DSH_CLIENT_CLOSED"));
    }
    this.pending.clear();
    this.lines?.close();
    if (
      this.child &&
      this.child.exitCode === null &&
      this.child.signalCode === null
    ) {
      this.child.kill("SIGTERM");
      await new Promise((r) => {
        const timer = setTimeout(() => {
          this.child.kill("SIGKILL");
        }, 2000);
        this.child.once("exit", () => {
          clearTimeout(timer);
          r();
        });
      });
    }
    if (this.root) await rm(this.root, { recursive: true, force: true });
  }
}
