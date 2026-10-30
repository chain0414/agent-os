#!/usr/bin/env node
// Explicit opt-in real model test. No existing user thread is modified.
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  rm,
  access,
} from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import assert from "node:assert/strict";
import { startService } from "../packages/service/src/server.ts";
import { request } from "../packages/service/src/client.ts";
import { NativeCoordinator } from "./coordinator.mjs";
import { CodexNativeClient } from "./codex-client.mjs";
import { DshClient } from "./dsh-client.mjs";
import { plan, fixtureTests, confirmation } from "./scenario.mjs";
import { parseLiveOptions } from "./live-options.mjs";

const { report: destination } = parseLiveOptions(process.argv.slice(2));
const root = await mkdtemp("/tmp/ac-live-");
const cwd = join(root, "workspace");
await mkdir(cwd);
await writeFile(join(cwd, "clamp.test.mjs"), fixtureTests);
const testsHash = createHash("sha256").update(fixtureTests).digest("hex");
const records = [];
const secrets = [];
let service,
  dsh,
  codex,
  phase = "starting";
const step = (value) => {
  phase = value;
  console.log(JSON.stringify({ step: value }));
};
const clean = (value) => {
  let text = String(value);
  for (const secret of secrets)
    if (secret) text = text.split(secret).join("[redacted]");
  return text.replace(
    /(?:sk-[A-Za-z0-9_-]{16,}|mk_[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)/g,
    "[redacted]",
  );
};
let outcome = "failed",
  failure = "";
try {
  service = await startService(join(root, "state"));
  const admin = await readFile(join(root, "state/admin-token"), "utf8");
  secrets.push(admin);
  const rpc = (auth, method, params) =>
    request({
      socketPath: service.socketPath,
      token: auth === "admin" ? admin : auth,
      method,
      params,
    });
  const coordinator = new NativeCoordinator(rpc);
  dsh = await new DshClient().start();
  codex = await new CodexNativeClient().start();
  const bind = async (runtime, sessionId, adapter) => {
    const binding = await rpc("admin", "registerSession", {
      runtime,
      sessionId,
      instanceId: "isolated-native-suite",
      cwd,
      capabilities: {
        trustedOrigin: true,
        generatedDelivery: true,
        restrictedReview: true,
        execute: runtime === "codex",
      },
    });
    secrets.push(binding.token);
    coordinator.attach({ ...binding, sessionId, adapter });
    return binding;
  };
  const tools = [
    {
      name: "agent_collab_delegate",
      description:
        "Delegate exactly one review or explicitly user-confirmed coding task to the other agent. Returns queued immediately; end your turn and await generated results.",
      inputSchema: {
        type: "object",
        properties: {
          kind: { type: "string", enum: ["review", "execute"] },
          content: { type: "string" },
        },
        required: ["kind", "content"],
        additionalProperties: false,
      },
    },
  ];
  const { sessionId: codexTarget } = await codex.createSession({
    cwd,
    mode: "review",
    developerInstructions:
      "Work only in the supplied temporary workspace. Review requests are read-only. For an authorized implementation request modify only clamp.mjs, preserve clamp.test.mjs, and run its tests. Do not read unrelated user files.",
  });
  const codexBinding = await bind("codex", codexTarget, codex);
  let dshBinding;
  const submitted = [];
  const { sessionId: dshSource } = await dsh.createSession({
    cwd,
    tools,
    onTool: async ({ origin, arguments: args }) => {
      assert.equal(origin.sessionId, dshSource);
      if (
        !["dsh-calls-codex-review", "confirmed-coding"].includes(phase) ||
        origin.inputSourceKind !== "user" ||
        !origin.userMessageId
      )
        throw new Error("NO_FRESH_USER_AUTHORIZATION");
      if (args.kind === "execute" && phase !== "confirmed-coding")
        throw new Error("NO_FRESH_USER_AUTHORIZATION");
      const input = {
        targetBindingId: codexBinding.bindingId,
        kind: args.kind,
        content: args.content,
        cwd,
        planHash: createHash("sha256").update(args.content).digest("hex"),
      };
      if (args.kind === "execute") {
        assert.equal(origin.inputSourceKind, "user");
        assert.ok(origin.userMessageId);
        const grant = await rpc("admin", "authorizeExecution", {
          bindingId: dshBinding.bindingId,
          planHash: input.planHash,
          content: input.content,
          userMessageId: origin.userMessageId,
          cwd,
        });
        input.grantId = grant.grantId;
      }
      const task = await coordinator.delegate(
        dshBinding.bindingId,
        origin,
        input,
      );
      submitted.push({ task, origin });
      return { taskId: task.id, state: task.state };
    },
  });
  dshBinding = await bind("dsh", dshSource, dsh);
  step("dsh-calls-codex-review");
  const initial =
    "请使用 agent_collab_delegate 工具且仅调用一次，kind=review，将以下原始要求与方案完整交给 Codex review。收到 queued 后结束本轮，等待异步结果，不轮询，不写代码。\n" +
    plan;
  records.push({ label: "DSH 测试输入", text: initial });
  const initialTurn = await dsh.runTurn(dshSource, initial);
  records.push({ label: "DSH 原生首轮输出", text: initialTurn.output });
  assert.equal(submitted.length, 1);
  assert.equal(submitted[0].task.kind, "review");
  const review = await coordinator.processOne(codexBinding.bindingId);
  records.push({ label: "Codex 实际复核原文", text: review.output });
  records.push({
    label: "原 DSH 会话收到异步结果后的实际回复",
    text: review.delivery?.output,
  });
  const sourceAfter = await rpc(dshBinding.token, "readTask", {
    taskId: review.taskId,
  });
  assert.equal(sourceAfter.delivery, "delivered");
  await assert.rejects(access(join(cwd, "clamp.mjs")));
  assert.equal(submitted.length, 1);
  records.push({
    label: "确认前验证",
    text: "原生首轮已经结束；review由异步生成结果回到原DSH会话；broker收到对应delivery回执；编码文件仍不存在。",
  });
  step("confirmed-coding");
  const confirmed =
    confirmation(review.output) +
    "\n请使用 agent_collab_delegate，kind=execute，只调用一次。收到queued后结束本轮。";
  records.push({
    label: "测试驱动器投递的确认输入（非Wayne现场审阅）",
    text: confirmed,
  });
  const confirmedTurn = await dsh.runTurn(dshSource, confirmed);
  records.push({ label: "DSH 编码交接输出", text: confirmedTurn.output });
  assert.equal(submitted.length, 2);
  assert.equal(submitted[1].task.kind, "execute");
  assert.notEqual(
    submitted[0].origin.userMessageId,
    submitted[1].origin.userMessageId,
  );
  const implemented = await coordinator.processOne(codexBinding.bindingId);
  records.push({ label: "Codex 实际编码输出", text: implemented.output });
  records.push({
    label: "原 DSH 会话收到编码结果后的实际回复",
    text: implemented.delivery?.output,
  });
  assert.equal(
    createHash("sha256")
      .update(await readFile(join(cwd, "clamp.test.mjs")))
      .digest("hex"),
    testsHash,
  );
  const result = await promisify(execFile)(
    process.execPath,
    ["--test", "clamp.test.mjs"],
    { cwd, timeout: 30000 },
  );
  records.push({ label: "独立重新运行测试", text: result.stdout });
  records.push({
    label: "实际 clamp.mjs",
    text: await readFile(join(cwd, "clamp.mjs"), "utf8"),
  });
  step("reverse-two-codex-sources");
  const { sessionId: dshReview } = await dsh.createSession({ cwd, tools: [] });
  const dshReviewer = await bind("dsh", dshReview, dsh);
  const reverse = [];
  for (let index = 0; index < 2; index++) {
    let binding;
    const item = { index };
    const { sessionId } = await codex.createSession({
      cwd,
      mode: "review",
      tools,
      developerInstructions:
        "For the next user request, use agent_collab_delegate exactly once with kind review. Return after queued. On generated results summarize evidence without further delegation. Read no unrelated files.",
      onTool: async ({ origin, arguments: args }) => {
        assert.equal(origin.sessionId, item.sessionId);
        assert.equal(args.kind, "review");
        if (item.task) throw new Error("DUPLICATE_DELEGATION");
        const task = await coordinator.delegate(binding.bindingId, origin, {
          targetBindingId: dshReviewer.bindingId,
          kind: "review",
          content: args.content,
          cwd,
          planHash: createHash("sha256").update(args.content).digest("hex"),
        });
        item.task = task;
        item.origin = origin;
        return { taskId: task.id, state: "queued" };
      },
    });
    item.sessionId = sessionId;
    binding = await bind("codex", sessionId, codex);
    item.binding = binding;
    reverse.push(item);
  }
  await Promise.all(
    reverse.map(async (item) => {
      const prompt =
        "Use agent_collab_delegate exactly once to ask DSH to review this plan. Include marker SOURCE_" +
        item.index +
        ". Request read-only reasoning only, do not delegate again. Plan: " +
        plan;
      records.push({ label: "反向测试输入 " + item.index, text: prompt });
      item.initial = await codex.runTurn(item.sessionId, prompt);
      assert.ok(item.task);
    }),
  );
  assert.notEqual(reverse[0].origin.sessionId, reverse[1].origin.sessionId);
  assert.notEqual(reverse[0].task.source, reverse[1].task.source);
  for (const item of reverse) {
    const response = await coordinator.processOne(dshReviewer.bindingId);
    assert.equal(response.taskId, item.task.id);
    records.push({
      label: "DSH 反向真实复核 " + item.index,
      text: response.output,
    });
    records.push({
      label: "原 Codex 会话收到反向结果后的实际回复 " + item.index,
      text: response.delivery?.output,
    });
    assert.equal(
      (await rpc(item.binding.token, "readTask", { taskId: item.task.id }))
        .delivery,
      "delivered",
    );
  }
  outcome = "passed";
  step("passed");
  records.push({
    label: "验证范围",
    text: "DSH与Codex隔离原生Harness双向真实模型流程；同目录两个Codex来源身份分别匹配。Codex回传使用适配器合成工具调用/结果配对+空input新轮；DSH原生user-role输入保留generated source并由受限工具和真实用户事件校验编码授权。未验证桌面UI或现有窗口owner接入。",
  });
} catch (error) {
  failure = /^[A-Z0-9_]+$/.test(error?.message ?? "")
    ? error.message
    : "SCENARIO_FAILED";
  records.push({ label: "失败阶段", text: phase + " / " + failure });
  console.log(JSON.stringify({ status: "failed", step: phase, code: failure }));
} finally {
  await codex?.close().catch(() => {});
  await dsh?.close().catch(() => {});
  await service?.close().catch(() => {});
  const report =
    "# Agent Collab 真实原生流程验证\n\n日期：2026-10-30。结果：" +
    outcome +
    "。确认输入由测试驱动器投递，非Wayne现场审阅。测试目录与运行凭据在结束后删除。\n\n" +
    records
      .map(
        (r) =>
          "## " + r.label + "\n\n" + "~~~~text\n" + clean(r.text) + "\n~~~~\n",
      )
      .join("\n");
  await writeFile(destination, report, { mode: 0o600 });
  await rm(root, { recursive: true, force: true });
  console.log(JSON.stringify({ status: outcome, report: destination }));
}
if (outcome !== "passed") process.exitCode = 1;
