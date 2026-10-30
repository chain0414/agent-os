# Agent Collab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 在同仓独立组件中实现可打包服务与原生接入探针，接入能力验证后完成双向委派。
**Architecture:** 单一本机broker拥有任务和写调度；两端插件提供可信来源与Runtime适配。AA仅作为可选消费者。
**Tech Stack:** Node 22.19+、TypeScript、Yarn、本机Unix socket、内置SQLite。
**Spec:** ../specs/2026-10-29-codex-dsh-bridge-design.md

## Global Constraints

- 不运行或依赖AA Server、Connector、PostgreSQL与Redis；不提交lockfile。
- 协作协议主源在agent-collab/contracts；不改变现有AA跨端契约。
- 来源身份与生成回传未经验证不能启用真实委派；对端文本不产生用户授权。
- 不读取或输出凭据；本机通信只用0600文件/进程内凭据。

## Review Focus

- 同目录并发来源不得串线，模型传入的session不能成为可信身份。
- 超时/重启不得重派未知执行或提前释放工作树执行权。
- 取消旧任务不得中断新轮次或清空其他输入。
- 生成结果不得伪装用户指令；只能在实际授权范围内执行。
- npm产物脱离源码checkout仍能运行；能力报告区分静态证据和真实验证。

### Task 1: 独立broker与发布边界

Files: agent-collab/package.json, packages/service/, contracts/, tests/installation/。
Interfaces: request({socketPath,token,method,params})；adapter注册可信binding，模型仅引用binding。
- [x] 写来源隔离、任务持久恢复、写工作树互斥与结果消费测试，观察失败。
- [x] 实现Unix socket认证服务、SQLite任务记录、本地排队取消、能力fail-closed。
- [x] 运行行为测试及npm pack隔离安装测试，观察通过。

### Task 2: 两端宿主入口和能力探针

Files: agent-collab/packages/dsh-plugin/, plugins/codex/, probes/, tests/probes/。
Interfaces: 宿主侧会话身份注册；读取adapter能力；未证实接口明确unsupported。
- [x] 写来源上下文、生成结果来源拒绝与能力分类测试，观察失败。
- [x] 实现DSH原生入口、Codex Skill/清单与只读探针，不运行真实模型。
- [x] 验证本机CLI/静态接口，记录版本与证据边界；禁止伪造端到端结果。

### Task 3: 仓库治理与集成

Files: AGENTS.md, docs/development.md, docs/versioning.md, .github/workflows/ci.yml。
- [x] 登记独立组件、版本适用范围与私有契约归属。
- [x] 增加路径CI作业，保持已有跨端触发逻辑；执行全部新组件相关检查。
- [x] 独立review、安全检查和发布产物安装；明确尚未验证的真实A1-A3。

### Task 4: 真实纵向协作

Files: packages/service/适配器、两端入口及tests/integration/。
- [x] A1双端原生来源与A2异步模型消费已真实验证；A3受限执行通过，安全运行中取消仍保持关闭。
- [x] 已记录接口版本、DSH模型role与来源差异、桌面UI及原生恢复边界，未用普通prompt伪装生成来源。
- [x] 真实DSH复核→回传→测试确认→Codex编码及反向双来源复核已通过。
- [ ] 后续产品化：桌面既有owner、真实原生断线恢复、并装与日常安装入口。

阶段完成以可复查证据为准；前三项的headless通过不代表第四项完成。

## 第一阶段证据

2026-10-30：统一检查26/26通过，服务源码strict TypeScript检查通过；脱离checkout的服务安装与DSH导入通过。真实原生双向协作尚未启用，详见[验证记录](../evidence/2026-10-30-agent-collab.md)。远程CI未执行，Task 4保持未完成。

## 原生阶段证据

2026-10-30：完整真实模型suite返回passed；代码与双向身份、异步回传、测试确认交接已验证。范围与模型原文见[验证摘要](../evidence/2026-10-30-agent-collab-native-summary.md)，不将测试驱动器确认写成人工审核。

最终本地检查：48/48无模型测试通过；独立复核的native测试18/18通过。真实模型suite单独执行成功，未将它纳入默认CI。
