# Agent Collab 本机协议 1.0（实验）

此协议属于独立协作组件，不是 AA `/api/v2` 或 Runtime 协议。单一服务提供 HTTP over Unix socket 的 `POST /rpc`；请求 `{method, params}`，响应 `{ok:true,result}` 或 `{ok:false,error:{code}}`。单请求最大 1.1MB。只有 adapter 进程持有私有目录 `admin-token`；session 令牌不得调用管理方法。令牌不应进入模型输入或日志。

## 可信宿主方法

- `registerSession({runtime,instanceId,sessionId,cwd,capabilities})` 返回 `{bindingId,token}`。身份及能力由真实宿主探针验证后提供；注册本身不能证明原生能力已验证。重复身份拒绝，避免创建两个不知彼此的绑定。
- `authorizeExecution({bindingId,planHash,content,userMessageId,cwd})` 返回单次 `grantId`，重复同一来源的 `userMessageId` 返回原授权，正文／方案冲突则拒绝。adapter 必须从真实用户事件取得授权；服务计算正文摘要，禁止保留同一方案标签后替换正文。
- `takeTask({bindingId})` 返回待接收任务或 null；接收立即持有会话与工作树执行权。
- `startTask({taskId,turnId})` 记录原生轮次；`completeTask({taskId,turnId,outcome,output})` 需匹配原轮次，outcome 为 succeeded / failed。开始 ACK 不是完成。

- `reconcileTask({taskId,receiptId,turnId?,outcome,output?})` 仅恢复 unknown 任务；adapter 必须核查原 Runtime requestId（等于 task ID），不能以当前最新轮次替代。outcome 为 notAccepted / running / succeeded / failed；notAccepted 是终态，不自动重派或恢复授权。
- `reconcileDelivery({taskId,deliveryId,received})` 仅恢复未知投递。adapter 核查原 deliveryId 已收到则标 delivered，确认未收到才恢复 pending，不能盲目重投。

## 来源会话方法

- `delegate({requestId,targetBindingId,kind,content,cwd,planHash,grantId?,deadlineMs?})` 返回 queued 任务；kind 为 review / execute。同一来源的 `requestId` 幂等：同输入返回原任务，不重复消费授权；同 ID 不同输入拒绝。来源由认证令牌决定，不能填写任意来源对话。execute 必须提供匹配来源、方案标签、正文、工作树的未使用 grant。deadline 默认一小时，最大一天。
- `readTask({taskId})` 只读取来源拥有的任务，不消费结果。没有循环等待接口，busy 任务立即返回，由宿主退出等待。
- `claimResult({taskId})` 返回 `{deliveryId,result:{output,outcome,planHash,source:{kind:'generated',bindingId}}}`；claim 不等于宿主已接收，宿主确认后调用 `ackResult({taskId,deliveryId})`。重复读取允许，不代表重复注入。重启时未确认投递变为 unknown，需人工/原生回执核查，不自动重投。
- `cancelTask({taskId})` 只取消尚未交给 Runtime 的本地 queued 任务。其他状态返回 `cancelled:false`，绝不调用会话级 interrupt。

health 返回版本与 `nativeInteropVerified:false`。本轮仅实现 broker；模型调用、来源识别与生成结果注入由未来真实适配器接入。测试 host 是模拟，不构成原生能力验证。
