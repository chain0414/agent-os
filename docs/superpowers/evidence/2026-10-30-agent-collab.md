# Agent Collab 第一阶段实施与接入证据

日期：2026-10-30。实现分支 `feat/con+dsh/agent-collab`。目标是在本仓库内独立打包协作服务，并先证明真实宿主接入路径。当前尚不是可用于日常对话的双向委派插件。

## 已实现

`agent-collab/` 提供独立本机Unix socket broker、SQLite任务记录、私有凭据、来源隔离、单次编码授权与正文摘要绑定、请求幂等、工作树读写互斥、本地排队取消、未知执行与投递的可信核查结算。直接Runtime执行与回传尚未接入。

DSH原生入口当前只注册协作能力检查工具，从loop上下文读取来源，不接受模型填写来源ID。Codex入口当前是探针阶段Skill和安装描述。二者不能据静态schema自动启用委派。

根目录登记组件、独立版本适用范围、私有协议归属与按路径触发的CI作业。未修改现有AA API或Runtime契约，未启动Server或Connector。

## 真实本机探针

输入为无敏感信息的固定协议请求，未调用模型，也未读取或修改现有对话。生成schema和隔离协议实验使用随机临时CODEX_HOME、工作目录及白名单环境，结束后清理。

| 对象与输入 | 实际输出／观察 | 能证明什么 | 尚不能证明什么 |
| --- | --- | --- | --- |
| Codex.app bundled CLI生成experimental schema | 版本0.145.0-alpha.18；TurnStartParams没有toolOutput；存在thread/inject_items | 本机协议与所查官方文档存在字段差异 | 不能因缺少该字段断言所有回传不可能 |
| 隔离app-server：initialize→ephemeral只读thread/start→注入function_call_output | 三步均accepted；未发turn/start | 隔离进程接受这种原始输入 | 模型消费、异步唤醒、原生UI和桌面owner兼容性均未证明 |
| DSH本机checkout只读检查 | 源码0.2.1-rc.2声明调用Agent；普通prompt来源是user | 原生身份有接入点，普通消息不能冒充生成回传 | 不代表安装中的DSH已验证自定义回传、只读或定向取消 |

可重跑入口：`node probes/run.mjs --dsh-source <checkout>` 与 `node probes/inject-items.mjs`，在组件目录运行。它们只输出字段白名单，不输出原始宿主响应、凭据或聊天内容。

## 本地检查与局限

统一检查结果：26/26通过。执行命令：`cd agent-collab && node scripts/check.mjs`。行为测试使用合成的宿主注册、方案原文和临时SQLite状态，证明的是broker边界，不是模型复核质量或真实宿主权限。安装测试将tarball放到checkout外离线安装、启动真实本机服务、运行已安装CLI健康检查；DSH包也在checkout外导入。

已单独执行服务源码strict TypeScript检查，借用本机已有编译器及Node类型声明，未把该本机路径写入产品依赖或CI。CI YAML解析及git diff whitespace检查通过；尚未push，未声称远程CI绿灯。

## 下一步需要验证的接口

1. Codex原生当前对话调用如何可信关联session、turn和call，覆盖同目录并行与子Agent。
2. 候选inject_items路径的模型消费、异步唤醒、历史来源和原生owner行为。
3. DSH原生生成结果来源与唤醒、实际受限复核和按原轮次取消。

这些是技术验证工作，不要求Wayne重选内部编排。接口尚未证明前，真实委派保持关闭，不能把合成adapter的成功当成双向接入完成。
