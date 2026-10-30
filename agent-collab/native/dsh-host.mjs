import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
export const name = "agent-collab-native-driver";
export const inject = ["agents", "sessions", "tools"];
export {
  originOf,
  generatedMessage,
  nativeInput,
} from "../packages/dsh-plugin/src/native.mjs";
import {
  originOf,
  generatedMessage,
  nativeInput,
} from "../packages/dsh-plugin/src/native.mjs";
export function apply(ctx) {
  const records = new Map(),
    toolResults = new Map(),
    registered = new Set();
  ctx.on(
    "session/event",
    (session, event) => {
      if (event.type === "turn/start") {
        const rec = records.get(session.id);
        if (rec?.requestId)
          send({
            method: "turnStarted",
            params: {
              sessionId: session.id,
              turnId: String(event.data.turn),
              requestId: rec.requestId,
            },
          });
      }
    },
    { global: true },
  );
  const send = (value) =>
    process.stdout.write(
      JSON.stringify({ agentCollab: true, ...value }) + "\n",
    );
  const lines = createInterface({ input: process.stdin });
  const turnOf = (agent) =>
    String(
      agent.session.snapshotEvents().findLast((e) => e.type === "turn/start")
        ?.data?.turn ?? "unknown",
    );
  const outputOf = (agent) =>
    agent.session
      .snapshotEvents()
      .filter((e) => e.type === "assistant/message")
      .at(-1)
      ?.data.message.content.filter((b) => b.type === "text")
      .map((b) => b.text)
      .join("") ?? "";
  async function receive(message) {
    if (message.method === "toolResult") {
      toolResults.get(message.id)?.resolve(message.result);
      toolResults.delete(message.id);
      return;
    }
    const p = message.params ?? {};
    let result;
    try {
      if (message.method === "createSession") {
        const toolNames = [];
        for (const tool of p.tools ?? []) {
          toolNames.push(tool.name);
          if (registered.has(tool.name)) continue;
          registered.add(tool.name);
          ctx.effect(() =>
            ctx.tools.register({
              name: tool.name,
              description: tool.description ?? "",
              parameters: tool.inputSchema ?? {
                type: "object",
                properties: {},
              },
              output: {
                schema: { type: "object", additionalProperties: true },
                render: (_a, v) => [{ type: "text", text: JSON.stringify(v) }],
              },
              execute: async (args, exec) => {
                const origin = originOf(exec, turnOf(exec.agent));
                const input = records.get(exec.agent.id)?.activeInput;
                const nativeInput = exec.agent.session
                  .snapshotEvents()
                  .find(
                    (e) => e.type === "user/message" && e.data.id === input?.id,
                  );
                origin.inputSourceKind = nativeInput?.data?.source?.kind;
                origin.userMessageId =
                  nativeInput?.data?.source?.kind === "user"
                    ? nativeInput.data.id
                    : undefined;
                const id = randomUUID();
                const value = new Promise((resolve, reject) => {
                  const timer = setTimeout(() => {
                    toolResults.delete(id);
                    reject(new Error("TOOL_TIMEOUT"));
                  }, 120000);
                  toolResults.set(id, {
                    resolve: (v) => {
                      clearTimeout(timer);
                      resolve(v);
                    },
                  });
                });
                send({
                  method: "toolCall",
                  id,
                  params: { origin, tool: tool.name, arguments: args },
                });
                return value;
              },
            }),
          );
        }
        const sessionId = randomUUID();
        const handle = await ctx.agents.create({
          sessionId,
          meta: { cwd: p.cwd },
          agentOptions: {
            provider: "deepseek-official",
            model: "deepseek-flash",
            maxTokens: 2048,
          },
          setup: (agentCtx) => {
            agentCtx.tools.restrict({ allow: toolNames });
          },
        });
        records.set(sessionId, { handle });
        result = { sessionId, restrictedReview: true };
      } else if (
        message.method === "runTurn" ||
        message.method === "deliverGenerated"
      ) {
        const rec = records.get(p.sessionId);
        if (!rec) throw new Error("SESSION_NOT_OWNED");
        const agent = rec.handle.agent;
        if (agent.status === "running") throw new Error("SESSION_BUSY");
        const input =
          message.method === "deliverGenerated"
            ? generatedMessage(p.result)
            : nativeInput({ content: p.content, requestId: p.requestId });
        rec.requestId = message.id;
        rec.activeInput = input;
        agent.followup(input);
        await agent.whenIdle();
        await ctx.sessions.flush(agent.session);
        const events = agent.session.snapshotEvents();
        const failure = events.findLast((e) => e.type === "turn/end")?.data
          ?.reason;
        if (failure?.kind === "error") throw new Error("DSH_MODEL_TURN_FAILED");
        const persistedInput = events.find(
          (e) => e.type === "user/message" && e.data.id === input.id,
        )?.data;
        if (!persistedInput || persistedInput.source.kind !== input.source.kind)
          throw new Error("INPUT_RECEIPT_MISSING");
        result = {
          sessionId: p.sessionId,
          turnId: turnOf(agent),
          output: outputOf(agent),
          inputSource: persistedInput.source.kind,
          inputMessageId: persistedInput.id,
          userMessageId:
            persistedInput.source.kind === "user"
              ? persistedInput.id
              : undefined,
          received: true,
          deliveryId: p.result?.deliveryId,
        };
      } else if (message.method === "ping") result = { ready: true };
      else throw new Error("UNKNOWN_METHOD");
      send({ id: message.id, result });
    } catch (error) {
      send({
        id: message.id,
        error: {
          code: new Set([
            "SESSION_NOT_OWNED",
            "SESSION_BUSY",
            "DSH_MODEL_TURN_FAILED",
            "UNKNOWN_METHOD",
            "INPUT_RECEIPT_MISSING",
          ]).has(error?.message)
            ? error.message
            : "DSH_NATIVE_FAILED",
          errorName: ["Error", "TypeError", "RangeError"].includes(error?.name)
            ? error.name
            : "NativeError",
          flags: {
            scope: /scope|restrict/.test(error?.message ?? ""),
            unknownTool: /unknown|tool/.test(error?.message ?? ""),
            provider: /provider|model/.test(error?.message ?? ""),
            context: /context|undefined/.test(error?.message ?? ""),
          },
        },
      });
    }
  }
  lines.on("line", (line) => {
    try {
      const m = JSON.parse(line);
      if (m.agentCollab) void receive(m);
    } catch {}
  });
  ctx.effect(() => () => {
    lines.close();
    for (const rec of records.values()) rec.handle.dispose?.();
  });
  send({ method: "ready", params: { native: true } });
}
