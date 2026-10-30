# DSH 原生身份与异步回传：独立接口验收

日期：2026-10-30。本文仅记录真实 DeepSeek Harness 模型与本机宿主接口的独立测试，不将模拟队列回执或人工构造结果声称为 Codex 的输出。完整跨模型流程另由主 agent 验收。

## 环境与隔离

使用本机安装的 `DeepSeek Harness.app` 提供的 `dsh --profile headless`，创建随机私有 `DSH_HOME`、新会话和临时工作区；通过插件overlay禁用默认一次性runner并安装协作driver。未启动GUI，未操作现有对话。凭据仅在进程内解析已有凭据存储的指定 `DEEPSEEK_API_KEY` 引用并传给子进程环境，未复制秘密到文件或日志。测试结束后停止进程并删除临时目录。

原生Agent只允许为会话注册的协作工具，使用真实 `agent.ctx.tools.restrict` 限制，未开放shell或文件写工具。测试允许指定工作区输入，不授予部署、发布或修改原有工作区的权限。

## 测试一：原生模型轮次

实际输入原文：

> Reply DSH_READY. Do not use tools.

真实模型输出全文：

> DSH_READY

观察：Agent创建、模型执行与原生输入收据成功；输入来源为 `user`。这只证明该隔离原生会话能调用模型，不证明跨模型通信。

## 测试二：真实工具身份与异步生成输入

实际输入原文：

> Call agent_collab_delegate with content "Review finite number validation" once, then reply WAITING. This is an isolated tool identity test.

模型实际调用原生协作工具。测试宿主返回预设合成队列回执 `{accepted:true, taskId:"synthetic-queue-receipt"}`，未在此独立测试中启动Codex。真实DSH模型输出全文：

> WAITING

宿主记录实际工具执行上下文中的 `exec.agent.id`、`exec.callId`，来源会话与被测试会话匹配；原生 `turn/start` 事件与runTurn结果轮次匹配。模型参数不参与选择来源。

原轮次结束后，测试驱动器异步投递以下**人工构造的外部结果**：

> Review result: missing finite-number validation. Reply REVIEW_RECEIVED without calling tools.

DSH原生Inbox接收该输入，使用自定义来源 `agent-collab-generated`，并唤醒同一会话。真实DSH模型输出全文：

> REVIEW_RECEIVED

限制：DSH原生followup契约使用 `role:user`；本实现没有调用会强制标为人输入的普通SDK prompt。消息source由插件设为生成来源，正文明确为外部证据；权限限制和宿主授权核查仍需共同发挥作用，不能仅凭来源标签就声称模型层已有独立低权限角色。这是原生同会话消费人工构造结果的证明，不是Codex实际review结果的证明，也没有验证桌面UI展示。

## 测试三：真实用户输入收据绑定

工具执行时Harness可能已插入 `runtime-context` 输入，因此不能将最后一个user-role事件直接当成人的授权。本实现绑定本次宿主创建的输入ID，再从原生Session事件中找到该ID，只有实际 `source.kind=user` 时才提供 `userMessageId`；生成回传期间不提供人授权收据。

修正后实际输入原文：

> Call agent_collab_delegate with content "identity verification" once. Then reply DONE.

真实DSH模型输出全文：

> DONE

观察：工具实际来源会话匹配；存在原生 `userMessageId`；来源是 `user`；工具携带收据与runTurn返回收据相同。生成结果输入使用不同来源，不能沿用上一条人指令作新编码授权。

## 产物

- `agent-collab/native/dsh-client.mjs`：隔离原生profile客户端，提供createSession、runTurn、deliverGenerated。
- `agent-collab/native/dsh-host.mjs`：在真正DSH宿主进程内驱动原生Agent、工具和持久事件。
- `agent-collab/packages/dsh-plugin/src/native.mjs`：可随DSH插件发布的来源与生成输入辅助函数。
- `agent-collab/tests/probes/dsh-native.test.mjs`：不调用模型的来源与消息构造回归测试。

这些接口验收没有替代完整流程中真实Codex输出、确认前不编码、确认后文件生成、反向委派和最终业务测试的证据。
