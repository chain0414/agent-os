import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
export function trustedCodexOrigin(params) {
  if (
    ![params?.threadId, params?.turnId, params?.callId].every(
      (x) => typeof x === "string" && x,
    )
  )
    throw new Error("ORIGIN_UNAVAILABLE");
  return {
    runtime: "codex",
    sessionId: params.threadId,
    turnId: params.turnId,
    callId: params.callId,
  };
}
export function generatedItems({ deliveryId, output }) {
  return [
    {
      type: "function_call",
      call_id: deliveryId,
      name: "agent_collab_result",
      arguments: "{}",
    },
    { type: "function_call_output", call_id: deliveryId, output },
  ];
}
export class CodexNativeClient {
  constructor({
    binary = "/Applications/Codex.app/Contents/Resources/codex",
    env = process.env,
  } = {}) {
    this.binary = binary;
    this.env = env;
    this.pending = new Map();
    this.sessions = new Map();
    this.turns = new Map();
    this.notifications = [];
    this.next = 0;
  }
  async start() {
    this.child = spawn(this.binary, ["app-server", "--stdio"], {
      env: this.env,
      stdio: ["pipe", "pipe", "ignore"],
    });
    this.child.stdin.on("error", () => {});
    const fail = () => this.rejectPending();
    this.child.on("error", fail);
    this.child.on("exit", fail);
    this.lines = createInterface({ input: this.child.stdout });
    this.lines.on("line", (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return;
      }
      this.handle(message).catch(() => {});
    });
    await this.request("initialize", {
      clientInfo: { name: "agent-collab-native", version: "0.1.0" },
      capabilities: { experimentalApi: true },
    });
    this.notify("initialized", {});
    return this;
  }
  rejectPending() {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error("CODEX_PROCESS_CLOSED"));
    }
    this.pending.clear();
    for (const state of this.turns.values()) {
      if (!state.done) state.reject?.(new Error("CODEX_PROCESS_CLOSED"));
    }
  }
  notify(method, params) {
    this.child.stdin.write(
      JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n",
    );
  }
  request(method, params, timeout = 120000) {
    return new Promise((resolve, reject) => {
      const id = ++this.next;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("CODEX_REQUEST_TIMEOUT"));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(
        JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n",
      );
    });
  }
  async handle(m) {
    if (Object.hasOwn(m, "id") && !m.method) {
      const p = this.pending.get(m.id);
      if (!p) return;
      this.pending.delete(m.id);
      clearTimeout(p.timer);
      if (m.error)
        p.reject(
          Object.assign(new Error("CODEX_PROTOCOL_REJECTED"), {
            code: m.error.code,
          }),
        );
      else p.resolve(m.result);
      return;
    }
    if (m.method === "item/tool/call") {
      let result;
      try {
        const origin = trustedCodexOrigin(m.params);
        const session = this.sessions.get(origin.sessionId);
        if (!session?.onTool) throw new Error("TOOL_UNAVAILABLE");
        const value = await session.onTool({
          origin,
          tool: m.params.tool,
          arguments: m.params.arguments,
        });
        result = {
          contentItems: [
            {
              type: "inputText",
              text: typeof value === "string" ? value : JSON.stringify(value),
            },
          ],
          success: true,
        };
      } catch {
        result = {
          contentItems: [{ type: "inputText", text: "COLLAB_TOOL_FAILED" }],
          success: false,
        };
      }
      this.child.stdin.write(
        JSON.stringify({ jsonrpc: "2.0", id: m.id, result }) + "\n",
      );
      return;
    }
    if (m.method && Object.hasOwn(m, "id")) {
      this.child.stdin.write(
        JSON.stringify({
          jsonrpc: "2.0",
          id: m.id,
          error: { code: -32601, message: "Unsupported client request" },
        }) + "\n",
      );
      return;
    }
    const p = m.params ?? {};
    this.notifications.push({
      method: m.method,
      threadId: p.threadId,
      turnId: p.turnId,
    });
    if (m.method === "item/completed" && p.item?.type === "agentMessage") {
      const key = p.turnId;
      const state = this.turns.get(key) ?? { messages: [] };
      state.messages.push(p.item.text);
      this.turns.set(key, state);
    }
    if (m.method === "turn/completed") {
      const turn = p.turn ?? {};
      const state = this.turns.get(turn.id) ?? { messages: [] };
      state.done = true;
      state.status = turn.status;
      state.error = turn.error;
      this.turns.set(turn.id, state);
      state.resolve?.();
    }
  }
  async createSession({
    cwd,
    mode = "review",
    tools = [],
    onTool,
    developerInstructions = "",
  } = {}) {
    const models = await this.request("model/list", {});
    const model = (models.data ?? []).find((m) => m.isDefault)?.model;
    const result = await this.request("thread/start", {
      cwd,
      model,
      ephemeral: true,
      sandbox: mode === "execute" ? "workspace-write" : "read-only",
      approvalPolicy: "never",
      dynamicTools: tools,
      developerInstructions,
    });
    const sessionId = result.thread.id;
    this.sessions.set(sessionId, { onTool, cwd });
    return { sessionId };
  }
  async runTurn(
    sessionId,
    content,
    { onStart, timeout = 120000, mode, requestId } = {},
  ) {
    if (!this.sessions.has(sessionId)) throw new Error("SESSION_UNBOUND");
    const result = await this.request("turn/start", {
      threadId: sessionId,
      input: content === null ? [] : [{ type: "text", text: content }],
      effort: "low",
      ...(requestId ? { clientUserMessageId: requestId } : {}),
      ...(mode
        ? {
            sandboxPolicy:
              mode === "execute"
                ? {
                    type: "workspaceWrite",
                    writableRoots: [this.sessions.get(sessionId).cwd],
                    networkAccess: false,
                    excludeTmpdirEnvVar: true,
                    excludeSlashTmp: true,
                  }
                : { type: "readOnly" },
          }
        : {}),
    });
    const turnId = result.turn.id;
    await onStart?.(turnId);
    const state = this.turns.get(turnId) ?? { messages: [] };
    this.turns.set(turnId, state);
    if (!state.done)
      await new Promise((resolve, reject) => {
        const cleanup = () => {
          clearTimeout(timer);
          state.resolve = undefined;
          state.reject = undefined;
        };
        const timer = setTimeout(() => {
          cleanup();
          reject(new Error("CODEX_TURN_TIMEOUT"));
        }, timeout);
        state.resolve = () => {
          cleanup();
          resolve();
        };
        state.reject = (error) => {
          cleanup();
          reject(error);
        };
      });
    if (state.status !== "completed") {
      const message = state.error?.message ?? "";
      const failureClass = /401|unauthorized|authentication|auth token/i.test(
        message,
      )
        ? "AUTHENTICATION"
        : /429|quota|rate.limit/i.test(message)
          ? "RATE_LIMIT"
          : /model.*(not|support|found)|not.*model/i.test(message)
            ? "MODEL_UNAVAILABLE"
            : /connect|network|request|stream|tls|dns/i.test(message)
              ? "NETWORK_OR_REQUEST"
              : "RUNTIME_FAILURE";
      throw Object.assign(new Error("CODEX_TURN_FAILED"), {
        failureClass,
        errorKeys: Object.keys(state.error ?? {}),
      });
    }
    return { turnId, output: state.messages.join("\n") };
  }
  async deliverGenerated(sessionId, result) {
    if (!this.sessions.has(sessionId)) throw new Error("SESSION_UNBOUND");
    await this.request("thread/inject_items", {
      threadId: sessionId,
      items: generatedItems(result),
    });
    const completed = await this.runTurn(sessionId, null, { mode: "review" });
    return {
      ...completed,
      received: true,
      deliveryId: result.deliveryId,
      sourceEvidence: {
        kind: "function_call_output",
        deliveryId: result.deliveryId,
        userInputAdded: false,
      },
    };
  }
  async close() {
    this.rejectPending();
    this.lines?.close();
    if (this.child?.exitCode === null) {
      this.child.stdin.end();
      this.child.kill("SIGTERM");
      await new Promise((resolve) => {
        const timer = setTimeout(() => {
          this.child.kill("SIGKILL");
          resolve();
        }, 2000);
        this.child.once("exit", () => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }
}
