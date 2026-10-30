# DSH 协作接入探针

这是第一阶段原生工具入口，目前只注册 `agent_collab_capabilities`。它从工具执行上下文读取 Agent 身份，不接受模型指定来源会话。所有真实委派、生成结果回传、受限复核和运行中取消能力保持关闭。

该包可独立打包，在已有 Cordis / DSH Tools 的宿主中加载 `apply(ctx)`。尚未验证已安装 DSH 的完整加载、对话回传或两个插件并装，因此不能宣称它已经提供 Codex ↔ DSH 协作。不会启动第二个 DSH runtime，也不依赖 AA Server、Connector 或账号。
