# Agent Collab 本机服务（实验）

Node >=22.19.0，使用内置 SQLite、HTTP 和 Unix socket，无运行依赖。`npm pack` 前会将 TypeScript 源码构建为 JavaScript；安装包可直接执行 `agent-collab start --data-dir <私有目录>` 和 `agent-collab health --data-dir <私有目录>`。

本包提供持久任务 broker，不包含已验证的 Codex / DSH 原生执行适配器。管理 token 限受信宿主进程；模型入口只能持会话 token。没有可用能力则拒绝委派，模拟适配器成功不代表原生互通。

SQLite 由 Node 实验接口提供。服务的单实例保证限同一数据目录；多个安装必须显式共用同一数据目录，目前尚未实现自动全局发现。管理凭据仅存私有目录，不要输出 admin-token 内容。协议错误只返回固定错误码。

异常退出后发现残留进程锁会返回 `SERVICE_LOCK_STALE`，不自动删除或抢占；须先核对旧服务确已停止，再由维护流程处理锁。该限制避免并发恢复启动两份服务。unknown 任务与未知投递只能通过受信 adapter 核查原请求／投递回执后协调恢复，不会自动重派。
