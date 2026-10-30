# Codex ↔ DSH 独立协作插件：设计复审

日期：2026-10-29。审查对象：[第一版设计 v1 快照](2026-10-29-codex-dsh-bridge-design-v1.md)。

## 结论与证据范围

产品目标保持：在当前 Codex / DSH 对话发起委派和复核，结果回到原对话；常用流程为 DSH 讨论方案、Codex 复核、DSH 确认方案后交给 Codex 编码。独立插件、本机服务和可选 AA 适配的方向可保留。

发现 5 个应修正的设计缺口，其中前三项影响核心能力，后两项影响任务取消和双向调度。原方案目前不宜直接作为实施定稿。上一轮“没有遗留的重要问题”只是可规划性检查，结论过于乐观；本轮补做接入证据与失败场景审查。

证据来自 AA 源码、本机固定 checkout 中的 DSH 源码和已打开的 OpenAI 官方文档。两个独立 reviewer 分别审查接入、生命周期，主 Agent 核查并整合。本文的失败步骤是依据接口推导的场景，不是实机复现；未调用模型、发消息、安装插件或修改运行配置。DSH checkout 不等于当前安装版本，版本兼容性仍需探针证明。

P1 表示在依赖该行为实施前必须解决；P2 表示必须明确并发和能力边界，不能留到产品运行时随机处理。它们是设计缺口，不是在宣称现有 AA 功能有同样的缺陷。

## 1. [P1] Codex 发起调用时，缺少可信的“当前对话”绑定

**原方案：** [第 53 行](2026-10-29-codex-dsh-bridge-design-v1.md:53) 为 Codex 配置 Skill / MCP；第 54 行要求 DSH 获取可靠 session ID；[第 91 行](2026-10-29-codex-dsh-bridge-design-v1.md:91) 的 Codex 探针验证创建目标会话、owner 路由和事件，没有验证来源 Codex 对话如何关联到这一次 MCP 调用。

**触发场景：** 在同一目录打开 Codex 对话 C1、C2，两边同时请求 DSH 复核。短等待已返回后，服务要将结果分别送回 C1、C2。工作目录、最近活动时间或 MCP 连接身份都不能未经验证就视为聊天身份。

**源码事实：** AA [control.py:173](/Users/wayne/mywork/dev/agents/Agents-Anywhere/connector/connector/runtimes/codex/ipc/control.py:173) 查找已知 thread 的跟随状态与 owner；[control.py:235](/Users/wayne/mywork/dev/agents/Agents-Anywhere/connector/connector/runtimes/codex/ipc/control.py:235) 发送请求时显式提供 `conversationId`。这证明能控制已知对话，不证明独立 MCP 服务天然知道调用来自哪个对话。DSH 原生工具的 [ToolExecutionInput.agent](/Users/wayne/mywork/dev/agents/dsh-desktop/deepseek-harness/packages/core/tools/src/index.ts:327) 则有 loop 提供的 Agent 上下文。

**影响：** DSH → Codex 演示可能成功，反向路径却无法可靠回传；用猜测匹配还可能串线或泄露到错误对话。

**修正建议：** 在第一阶段同时验证两端来源身份，来源地址由宿主 / 适配器绑定，不将模型输入的任意 ID 作为可信凭据。Codex 的 [Hooks 官方文档](https://learn.chatgpt.com/docs/hooks) 描述了 `session_id` 和部分事件的 `turn_id`，可调查是否能关联调用，但子 Agent 的 hook 使用父 session ID，不能直接把它当成完整路由方案。增加同目录多对话并发、重启后回传验收；无法可信关联的入口暂不启用。

## 2. [P1] 直接复用发送消息接口，会把对端结果标成用户输入

**原方案：** [第 64 行](2026-10-29-codex-dsh-bridge-design-v1.md:64) 在工具等待结束后异步通知原对话；第 67 行又明确要求对端结果不是新用户授权。两者之间缺少宿主实际如何记录、展示和解释该输入的契约。

**触发场景：** Codex 的复核结果晚于 DSH 原轮次结束返回，插件调用现有 AA DSH `startTurn` 继续原对话。结果中可能有“可以开始实施”的建议；它应是 Codex 的意见，不能成为 Wayne 本人的指令。

**源码事实：** AA [native.ts:316](/Users/wayne/mywork/dev/agents/Agents-Anywhere/dsh-bridge-next/src/host/dsh-runtime/native.ts:316) 调用 `sessionController.prompt`；本机 DSH [session-controller/index.ts:477](/Users/wayne/mywork/dev/agents/dsh-desktop/deepseek-harness/packages/api/session-controller/src/index.ts:477) 将其来源设为 `kind: 'user'`，再通过 [commands.ts:341](/Users/wayne/mywork/dev/agents/dsh-desktop/deepseek-harness/packages/api/session-controller/src/commands.ts:341) 创建用户消息并 followup。仅在正文写“来自 Codex”不会改变该来源事实。Codex 当前 [App Server 官方文档](https://learn.chatgpt.com/docs/app-server) 提供 `turn/start.toolOutput`，能以独立工具输出继续对话；但现有 AA 桌面 owner 的 `turn_start_request` 构造普通文本 `input`，尚无该字段的兼容证据。

**影响：** 原文可以送达，但聊天历史的来源、模型解释及后续授权判断可能错误。网络客户端认证解决“谁连接了服务”，不等于证明“人授权了这项操作”。

**修正建议：** 分别定义同步工具返回、异步任务结果的输入表示。Codex 调查工具输出通路及桌面 owner 兼容性；DSH 原生插件调查带稳定任务 ID、对端身份及生成来源的持久输入。DSH 源码有可扩展 `MessageSourceMap` 和原生 followup 能力，但源码存在不等于安装版本已支持所需组合，且自定义来源不自动保证模型层的角色隔离。生成结果必须作为待分析的数据，不能被提升为用户授权；编码任务应绑定实际用户指令与确定方案。增加“复核原文要求直接编码，但用户未授权”的验收。

## 3. [P1] 按会话排队，挡不住同一工作区被两个会话同时修改

**原方案：** [第 44 行](2026-10-29-codex-dsh-bridge-design-v1.md:44) 每个任务只有一个执行方；[第 65 行](2026-10-29-codex-dsh-bridge-design-v1.md:65) 繁忙的目标会话排队。这两个约束均没有覆盖不同会话共享一个工作树。

**触发场景：** DSH 两个对话分别绑定 Codex C1、C2，对同一目录提交编码任务。两个目标会话均空闲，任务同时开始，修改同一文件或运行时改动相同生成产物。

**影响：** 改动可能互相覆盖；一方的测试可能测试到另一方的半成品；某份方案的验收证据失去对应关系。方案原文的内容摘要也不能冻结它读取的工作区文件。

**修正建议：** 第一版对插件管理的写任务，按规范化工作树身份串行执行；需要并行时使用独立 worktree 并单列集成步骤。记录开始时的 Git 基线与已有未提交改动，执行前后检查外部修改；不要宣称一个插件锁能阻止用户在原生对话或编辑器里直接写文件。复核绑定被审查代码的快照或差异版本，工作树变更后结果明确标记过期。增加两个目标会话写同一仓库及外部修改的验收。

## 4. [P2] “取消本插件任务”没有落实到对应执行轮次和队列项

**原方案：** [第 57 行](2026-10-29-codex-dsh-bridge-design-v1.md:57) 只允许取消插件拥有的任务，但未规定底层取消必须核对哪个 Runtime 轮次，也未规定是否保留其他队列消息。

**触发场景：** 插件任务 T 已结束，但服务尚未收到完成事件；Wayne 在同一原生对话启动新轮次 U。此时取消仍显示运行中的 T，服务按会话 ID 取消，实际中断 U。即使 T 尚未结束，取消还可能误删 Wayne 已排队的后续消息。

**源码事实：** AA DSH [native.ts:345](/Users/wayne/mywork/dev/agents/Agents-Anywhere/dsh-bridge-next/src/host/dsh-runtime/native.ts:345) 按会话执行 `agent.cancel({kind:'user'})`；本机 DSH [agent.ts:175](/Users/wayne/mywork/dev/agents/dsh-desktop/deepseek-harness/packages/core/agent-loop/src/agent.ts:175) 默认清空 inbox，然后中止活动。Codex AA [control.py:364](/Users/wayne/mywork/dev/agents/Agents-Anywhere/connector/connector/runtimes/codex/ipc/control.py:364) 有 `expectedTurnId`，但设计还需确保它使用任务持有的轮次，而不是取消瞬间的新活动轮次。

**修正建议：** 任务保存接收消息 ID 和 Runtime turn / generation，由 owner 原子核对再取消，并明确只移除本任务队列项、保留其他输入。适配器不具备这种能力时，只支持安全取消尚未入队的本地任务；已进入 Runtime 的任务显示不能保证立即停止，不能直接调用会话级停止冒充任务级取消。验收取消与完成交错、用户新轮次、其他排队输入均不被影响。

## 5. [P2] 祖先任务禁环无法覆盖两个独立请求的互等

**原方案：** [第 63 行](2026-10-29-codex-dsh-bridge-design-v1.md:63) 支持短等待；第 65 行繁忙会话排队；[第 67 行](2026-10-29-codex-dsh-bridge-design-v1.md:67) 只禁止任务链回到等待中的祖先。

**触发场景：** 用户在 Codex C 和 DSH D 分别发起请求，C 请求 D 复核，D 同时请求 C 复核。两个请求属于独立根任务，没有共同祖先；双方目标忙，双方来源轮次又不断短等待 / 查询，导致目标都不能开始。单次等待超时不等于来源轮次已经释放。

**影响：** 没有任何真正复核，仍可能持续耗费调用与时间预算。短等待只有在退出协议明确时才避免长期占用。

**修正建议：** 明确目标返回 busy / queued 后来源不再循环等待，应结束当前轮次或继续不依赖该结果的工作；由异步结果恢复。调度器维护会话等待关系并检测跨根任务环，而不只检查父任务链。验收两个原生对话同时相互请求、都能退出等待并最终执行；设置任务总截止时间，不能只设置单次等待超时。

## 建议的设计修订与下一步

保留独立本机服务 + Codex Skill / MCP + DSH 原生插件的结构。先补一份很小的适配器能力契约：可信来源身份、生成结果输入与唤醒、受限复核、带轮次核对的取消、Runtime 入队及完成回执。能力未验证就不宣称支持，按具体入口禁用；不以模糊“支持 Codex / DSH”替代。

实施第一步收敛为四项接入验证：

1. 同目录两个 Codex 来源对话的调用与回传不串线，DSH 同样验证来源绑定。
2. 两端当前轮次结束后，异步结果仍能回原对话，并保留对端结果来源；不会变成人的新授权。
3. 同一个 Codex 协作会话能在受限复核和已授权编码间明确切换；现有 owner 路径继承会话权限，不能只靠“review”提示词降权。不能落实时用独立受限复核会话并显式交接完整方案。
4. 取消任务能核对轮次且保留其他队列输入；不能做到时准确缩减取消能力。

这些验证通过后，再实现持久任务队列与双向完整流程。工作区写任务互斥、跨根等待环和交接版本一致性可以先用假适配器验证，但不能用假适配器测试替代上述真实接入证据。

本轮仅新增审查报告，保留原设计供对照。没有要求 Wayne 决定内部调度方式，也没有改变已确认的产品目标。

## v2 修订跟进

Wayne 已要求更新方案，[当前设计](2026-10-29-codex-dsh-bridge-design.md) 自 v2 起已纳入这 5 项发现及对应验收场景；v3 进一步明确在本仓库同级 `agent-collab/` 子项目中维护、独立打包，以及可选 AA 集成边界。本报告保留对 v1 的原始判断，旧设计行号已固定到 v1 快照。当前状态是设计约束已补齐，真实来源绑定、异步回传、权限和取消能力仍需探针；不将文档修订记为运行问题已验证解决。
