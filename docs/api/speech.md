# 语音输入凭证（2.2）

## POST /api/v2/speech/credentials

需要当前有效用户的 Bearer access token。请求体为空；客户端不能传入模型、地域、上游 URL 或永久凭据。

成功返回 HTTP 200，响应头必须包含 `Cache-Control: no-store`、`Pragma: no-cache`：

```json
{
  "provider": "aliyun",
  "model": "qwen-audio-3.0-asr-flash-streaming",
  "websocketUrl": "wss://<workspace>.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference",
  "token": "<short-lived-token>",
  "expiresAt": 1893456000,
  "languageHints": ["zh", "en"],
  "sampleRate": 16000,
  "maxRecordingSeconds": 300
}
```

`expiresAt` 是 UNIX 秒；凭据仅用于当前账户的语音识别，不得持久化、进入日志、Timeline 或附件。仅允许 HTTPS/WSS 的阿里云官方北京/新加坡接入点；永久 API Key 只在 Server 进程读取。临时凭据继承永久 Key 权限，部署时应限制该 Key 的模型权限。录音音频由客户端直接发送至阿里云，本服务不接收或保存音频。

错误仍使用现有 `detail: {code,message}`：未认证 401，账号禁用 403，频率超限 429 `speech_rate_limited`（含 Retry-After），未配置或不支持的配置 503 `speech_unavailable`，上游失败/响应异常 502 `speech_credentials_failed`。错误不得包含上游响应体、URL 查询秘密或任何 Key/Token。

部署配置：`AGENT_SERVER_ASR_API_KEY` 或显式指定 `AGENT_SERVER_ASR_CONFIG_FILE`（复用百炼 JSON 的 `api_key`、`base_url`、`workspace_id`，只读）；`AGENT_SERVER_ASR_BASE_URL`、`AGENT_SERVER_ASR_WORKSPACE_ID`、`AGENT_SERVER_ASR_MODEL` 可覆盖。默认模型如上、临时凭证 TTL 300 秒、单用户每分钟最多 10 次签发。未配置时仅语音输入不可用，其他服务正常。

客户端先取得凭证，再建立 WebSocket 并发送 `run-task`；收到 `task-started` 后发送单声道 16 kHz PCM16。按 `sentence_id` 替换中间/最终结果，忽略 heartbeat；结束发送 `finish-task` 并等待 `task-finished` 收齐最终文字。转写不自动发送到 Agent。

本次只有 iOS 增加入口，其他端保持现状。旧客户端兼容新 Server；旧 Server 返回 404 时，新 iOS 应提示服务尚未支持语音输入。
