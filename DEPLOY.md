# 已核实的本地部署入口

本仓库包含多个独立客户端与服务；目前此入口只授权描述 Wayne 本机 DSH 插件的受控更新。其它服务部署、公开发布和整包升级需要各自的明确配置与授权。

- **Type**：`manual-cli`
- **Trigger**：用户明确授权更新本地 DSH 插件。
- **Commands**：执行 [DSH 本机配置](dsh-bridge-next/DEPLOY.md) 的标准构建、验证、本地归档与官方 CLI 安装步骤。
- **Health check**：按同一配置核对实际 Runtime 加载版本、账号与原生历史保持、Connector 身份不变，以及真实日报两条定时任务已回填；如正常重开宿主，记录新的主进程／Host 并验证定时计划仍在。
- **Rollback**：使用同一受控更新脚本的 `--rollback` 恢复已备份的插件与 Profile 元数据，再验证 Runtime 实际加载；必要时检查无活动任务后正常重开宿主，不清空数据。
- **Environment**：本机 `desktop` Profile、Dev.app 随附 CLI、本地 Server 与原有 Connector。`DSH_HOME` 如需设置，应指向已核对的原生根目录；可选 `AGENT_SERVER_TEST_DB_URL` 仅允许一次性测试库。凭据继续由原有存储管理，不写入文档、命令参数或日志。

完整路径、核查条件、缓存恢复边界与本次脚本位置见子配置。本文件不提供 npm／App Store 发布或远程生产环境变更命令。
