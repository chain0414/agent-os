# Agent Collab（原生链路验证阶段）

本仓库内独立构建、独立安装的 Codex / DSH 协作组件。已跑通隔离原生 Harness 中的 DSH→Codex 复核、异步回传、测试确认后编码及 Codex→DSH 反向委派；它仍不是安装后即可加入任意桌面现有对话的插件。原生适配器与验证驱动器位于 `native/`，默认安装入口的真实委派仍未自动启用。

需要 Node >=22.19.0。不需要 AA Server、Connector、账号、PostgreSQL 或 Redis。

```sh
node scripts/check.mjs
node packages/service/scripts/build.mjs
node packages/service/bin/agent-collab.mjs start --data-dir /tmp/agent-collab-local
node packages/service/bin/agent-collab.mjs health --data-dir /tmp/agent-collab-local
```

数据目录必须私有，socket 路径须不超过100字节；开发临时目录仅用于测试，实际使用选择用户私有持久目录。停止使用 Ctrl-C。服务对该目录加进程锁，并以 SQLite 保存任务；运行状态不确定的任务在重启后保留执行权，不能自动重发。当前取消只支持本地排队任务。

服务与两端入口通过本机协议协作；生成结果始终保留来源，不产生新用户授权。协议详见 `contracts/1.0/README.md`。独立打包检查在隔离目录仅安装 tarball 后启动真实服务，测试适配器不调用真实模型。

当前尚未提供自动全局服务发现；多个入口必须配置同一数据目录。异常退出后的陈旧进程锁不会自动抢占，先核对进程及未完成任务再恢复。详见服务 README 与协议的 reconcile 方法。

## 真实原生流程验证

显式运行以下命令会调用真实模型，使用本机 Codex 登录和 DSH 凭据，不会创建或修改你已有的对话：

```sh
node --experimental-strip-types native/live-flow.mjs --real-models --report live-flow-report.md
```

需要本机安装 Codex.app 与 DeepSeek Harness.app，以及 DSH 的 headless profile 依赖；CLI 与profiles位置可在对应adapter构造参数覆盖。凭据只在进程内使用，不写入报告。测试在临时工程中讨论 `clamp` 方案，真实调用对方、结束来源轮次、异步回传；确认输入由测试驱动器投递，随后检查实际代码与原有测试文件摘要，再运行两个同目录Codex来源的反向委派。结束后删除测试工程和服务凭据，保留脱敏输入与模型原文报告。

Codex 回传通过适配器合成 function-call/output 配对并以空用户输入开始只读轮次。DSH followup 的模型角色仍是 user，但原生来源是 `agent-collab-generated`；它不会获得人输入收据，且只有受限协作工具，宿主另核对编码确认。协议与权限验证通过不代表模型review语义必然正确。

已验证的版本组合、实际输入输出与限制见[真实验证摘要](../docs/superpowers/evidence/2026-10-30-agent-collab-native-summary.md)。桌面UI、既有owner接入、运行中定向取消和跨进程原生恢复尚未验收。
