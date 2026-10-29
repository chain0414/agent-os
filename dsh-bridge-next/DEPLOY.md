# 本机 DSH 插件更新

此配置仅覆盖 Wayne 本机的 DeepSeek Harness Dev、`desktop` Profile 与其已连接的本地 Connector，不用于 npm 发布、应用整包更新或远程环境。

- **Type**：`manual-cli`
- **Trigger**：用户授权本地插件更新。
- **目标**：`/Users/wayne/.dsh/profiles/desktop`；使用当前 Dev.app 随附的官方 `dsh` CLI。
- **状态保护**：沿用账号、Connector、原生会话和历史；备份旧插件及 Profile 的 `package.json`、`pnpm-lock.yaml`。凭据只校验摘要，不复制到产物或日志。

## 构建与验证

按照 [TECHNICAL.md](TECHNICAL.md) 的标准构建，不以单文件临时打包替代：

```bash
cd dsh-bridge-next
corepack yarn typecheck
corepack yarn build
corepack yarn check:build
corepack yarn exec tsx --test --test-concurrency=1 tests/unit/*.test.ts tests/integration/*.test.ts
```

最后一条使用与 `yarn test` 完全相同的测试集合；串行参数避免本机并发 Python 启动触发既有短超时。没有一次性测试数据库时，两个明确依赖 `AGENT_SERVER_TEST_DB_URL` 的集成用例会跳过；不能指向开发库或生产库。

本地包在忽略目录 staging，仅追加 `-local.<日期>.<源码摘要>` 版本后缀。使用 `npm pack --ignore-scripts` 打出已完成上述检查的标准 `lib/` 产物；不发布 npm。插件内置的 Connector 源码必须同步包含当前投影版本适配。当前独立运行的 Connector 也必须先加载接受投影版本 4／5 的适配；只更新插件内置副本不等于已经更新正在运行的进程。

## 应用到本机 Profile

实际命令为官方 CLI 的本地归档安装：

```bash
"/Users/wayne/Applications/DeepSeek Harness Dev.app/Contents/Resources/runtime/cli/bin/dsh" plugin --profile desktop add /absolute/path/to/reviewed-local-package.tgz --offline --ignore-scripts
```

归档保存在 `~/.agents-anywhere/local-packages/dsh-bridge-next/`，避免清理工作区后 Profile 的本地依赖来源失效。

若缺失的是 Profile 锁文件中既有的固定 Git 归档，可仅对锁定的完整 URL 使用官方 `store add` 补缓存，进程内设置 20 秒请求超时、零重试与禁用生命周期脚本；完成后确认 Profile 元数据未变，再重试离线安装。不能用新版本替代该固定提交。

PNPM 11 若尚未把新本地归档纳入 store，可先使用同一个官方 CLI 的 `plugin --profile desktop store add <同一归档>`，并仅给该进程设置 `npm_config_offline=true`。此步骤只导入归档，不启用插件、不运行其生命周期脚本；确认 Profile 没变后再执行上面的离线 `add`。


若纯离线返回 `ERR_PNPM_NO_OFFLINE_TARBALL` 且旧安装／Profile 尚未变化，可对同一个本地归档使用官方 `--prefer-offline --ignore-scripts`，仅获取缺失的锁定依赖；保持 Profile 已有的 `autoInstallPeers: false`，不升级宿主 SDK 或其它插件。网络请求使用 20 秒超时、零重试、并发 4；完成后核对 Profile 其它直接依赖与锁文件中的 SDK 版本没有变化。当前受控脚本用 `--apply --prefer-offline` 启用这一有界 fallback，原始失败回执保留。


若既有 Git 依赖网络阻塞，标准 AA 完整制品可在本机可逆替换到原独占发布目录，但必须先确保插件已停止或宿主已正常退出；不动其它依赖、不伪造 store 索引。最终 Profile 依赖和锁文件保持原字节，因此实际本地制品版本与 Profile 原 `2.1.0` 依赖不同；这不是 PNPM 安装成功，后续官方安装可能覆盖本地制品。

实际 rc.3 的 Profile watcher 只在 bundles 选择改变时进行协调，改依赖版本或无效 touch 不能保证重载。本次尝试仅移除／恢复 AA bundle 后，Runtime 桥仍可读取目标，但 Onboarding manager lease 未恢复；已回滚完整旧版目录和原 Profile。**不要把这条 HMR 尝试作为已经成功验证的安装流程重复执行。** 单一 manager lease 也不能替代 Runtime／真实历史回填验证。

可靠恢复路径是使用官方退出确认检查全部原生工作；只有确认无运行中、排队、后台或未知工作，才正常退出同一 Dev.app，完整替换 AA 制品后打开同一 App/Profile。未来定时任务在应用关闭期间暂停，重新打开后应验证原计划仍在。锁屏会阻断系统确认操作：必须等待用户解锁，不能绕过锁屏或强杀宿主。当前工作停在官方“应用关闭期间，定时任务不会运行”确认，旧 AA 目录及 Profile 已恢复，账号与原生日志未改。

本次工作区的受控入口为 `.local-dev/dsh-turn-timing/deployment/deploy-local.py --apply`（使用仓库 Server 虚拟环境运行）。它要求已经存在标准构建、同集合测试报告、本地归档报告和旧版回滚备份；只对精确目标执行权威历史同步，不发送消息或回应交互。

## 健康检查

- 实际 Runtime 桥可用且加载新制品；记录是否通过正常退出冷启动及新的主进程／Host PID，不以单一 manager lease 判定成功。
- Connector、平台会话与原生会话映射不变；账号／凭据摘要和原生日志既有前缀不变。
- 「周报日报质量优化建议」的两条原生 schedule 时间及正文 SHA-256 与 Server 中 `content.automation.kind=schedule` 一致。
- Server 两条原生任务均有完整正文且摘要吻合；iOS 至少定位并实际展开任务正文，具体看过几条须按实记录，助手结果和原有链接继续显示。

## 回滚

受控脚本保存旧插件完整发布文件与两个 Profile 元数据文件。执行同一脚本的 `--rollback` 恢复旧文件后，仍须验证 Runtime 实际加载；不能假定 Profile watcher 会恢复所有子服务，必要时按上述原生任务检查后正常退出／重开。回滚不清空数据，不操作其它插件或原生任务。

回滚、安装和验收回执仅保存在工作区忽略目录；日志只保存结构化状态及脱敏错误码。若热更新机制或本机安装方式改变，先重新核对实际宿主与官方 SDK 生命周期再更新本配置。
