# Agent Collab（实验基础）

本仓库内独立构建、独立安装的 Codex / DSH 协作组件。当前交付是可运行的本机 broker 与宿主能力探针，不是已可用于日常对话的双向插件；来源识别、异步生成结果回传和真实权限仍需验证。

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
