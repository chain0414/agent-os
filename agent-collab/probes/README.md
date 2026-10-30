# 本机能力探针

执行 `node probes/run.mjs` 检查本机 Codex CLI 版本及临时生成的 `TurnStartParams` schema。默认优先检查已安装 Codex.app 的内置 CLI；可用 `--codex-bin /absolute/path/to/codex` 检查指定分发。`--dsh-source /absolute/path/to/deepseek-harness` 可选检查 DSH 源码声明。

仅调用 `--version` 和 schema 生成工具，不启动对话、模型轮次或 GUI，不连接现有 owner，不读取配置、凭据或聊天记录。schema 生成在随机临时目录运行并可靠清理。输出仅含字段白名单，失败不输出原响应或异常。

`toolOutputDeclared` 只说明本机 CLI 的类型定义存在该字段；`callerContextDeclared` 只说明所给 DSH checkout 声明了 Agent 上下文。它们均不证明已安装桌面支持可靠身份绑定、异步唤醒、受限复核或取消。探针固定报告 `runtimeVerified: false`，不会把静态发现升级为可用委派能力。

## 隔离协议接受探针

`node probes/inject-items.mjs` 使用已安装 Codex.app 的内置 CLI，在随机临时 `CODEX_HOME` 和工作目录创建 ephemeral、read-only 会话，仅执行 initialize、thread/start 和 thread/inject_items。也可将明确的 CLI 路径作为唯一参数。不继承认证环境变量，不发 turn/start、不调用模型、不修改现有聊天；结束后停止进程并删除临时目录。

`injectFunctionCallOutput: accepted` 只证明隔离 app-server 接收该原始输入，不能证明异步唤醒、模型消费、原生 UI 展示或桌面 owner 兼容。`runtimeDeliveryVerified` 仍为 false。
