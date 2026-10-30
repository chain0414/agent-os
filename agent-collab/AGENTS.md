# Agent Collab

独立本机协作扩展，按自身 SemVer 演进。根目录没有统一构建；在此运行 `node scripts/check.mjs`，Node >=22.19.0。依赖与运行不得导入相邻 AA 子项目源码。协议先更新 `contracts/1.0/` 再修改消费者。服务包由 Node 内置 TypeScript strip API 构建为 JS，发布包只依赖 Node。不得提交 lockfile、运行凭据、SQLite 数据或日志。

本机 broker 当前不等于可用的双向宿主插件。真实适配器在来源身份和异步生成回传未验证时必须 fail closed；模拟测试不得写成原生互通验收。管理凭据只供受信宿主进程，模型工具仅持有来源绑定凭据。
