# 附件上传、下载与缩略图

本契约对应 agent-os Server 2.3；API namespace 仍为 `/api/v2`。本次接口增加缩略图，已有原图下载与附件发送流程继续兼容。

## 上传响应

`POST /api/v2/sessions/{session_id}/attachments` 接收既有 multipart 文件上传，返回 `attachments` 数组和 `serverTime`。使用本地文件存储时，Server 分块写入文件，不在业务处理层组装完整文件；现有大小、空文件和会话权限限制继续适用。未实现流式写入的其他存储后端沿用有大小限制的兼容实现，仍可能在内存中组装完整文件。

附件引用保留 `fileId`、`sessionId`、`name`、`mediaType`、`size`、`sha256`、`createdAt`、`downloadUrl`、`openUrl`，并新增：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `thumbnailUrl` | string | 支持生成缩略图的图片返回会话范围内的缩略图 URL；其他附件为空字符串。旧 Server 可以省略该字段，客户端按缺失或空值处理。 |

`thumbnailUrl` 只是入口，不保证原图一定能成功解码；使用失败时应继续提供原图入口。旧客户端可忽略新增字段。

## 缩略图

`GET /api/v2/sessions/{session_id}/attachments/{file_id}/thumb?w=512`

- 使用有效用户 Bearer token 鉴权，也支持既有 `token` 查询参数；只有可读取该会话附件的用户可访问。
- `w` 默认为 512；请求值归一到最近的 256、512、1024，非正数回退 512。
- 成功返回 `image/webp`；`X-Thumbnail-Width` 表示归一后的宽度档位，并非小图片实际像素宽度。图片不会放大。
- 不存在的附件、无权访问的附件，以及不支持或无法生成的缩略图返回 404；无效用户凭据返回 401。
- 支持 JPEG、PNG、WebP、GIF 和 BMP 解码；动画、超出解码上限或无效内容可没有缩略图。缩略图失败不使上传失败。
- 成功响应使用 `Cache-Control: private, max-age=31536000, immutable`；有原图 SHA-256 时，ETag 为 `"{sha256}-w{width}"`。`If-None-Match` 命中返回 304，鉴权与附件读取权限仍先校验。

## 原图与兼容性

使用本地文件存储时，原有 `openUrl` 对应的原图读取改为流式文件响应，支持 Range 与条件缓存；Connector 的附件内容拉取和公开分享原图路径也按文件流传输，继续使用各自既有访问控制。JSON 下载接口维持原有响应形状。非本地存储后端保留原图重定向或兼容读取路径，不承诺同样的内存行为与 Range 支持。

本次没有新增数据库迁移。Server 增加 Pillow 依赖，源码部署需重新同步 Server 依赖。四端上传 DTO 接受可选缩略图字段，现有界面仍使用原图入口，未新增缩略图浏览界面；新客户端连接旧 Server 时可省略该字段。
