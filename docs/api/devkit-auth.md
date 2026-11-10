# DevKit Project Auth 接入

Agent OS 可以把现有业务账号与指定 DevKit 项目的账号绑定。DevKit 负责认证和账号管理，Agent OS 仍按原业务用户 ID 判断角色、设备和会话权限。

## 接口

- `GET /api/v2/auth/config` 在启用后返回 `devkit.apiUrl` 和 `devkit.publishableKey`。客户端用这两个公开配置访问 DevKit 项目的 Auth API。
- `POST /api/v2/auth/devkit/link` 接收 `{"accessToken":"<DevKit access token>"}`，要求在 Authorization 中提供当前 Agent OS 用户的有效会话。成功返回 204。重复绑定同一对账号可重试。账号已绑定到其他身份时返回 409。
- `POST /api/v2/auth/devkit/login` 接收同样的请求体，无需现有 Agent OS 会话。返回常规 `AuthResponse`。只有已绑定的活跃用户可登录。

Agent OS 向 DevKit 的 `/api/runtime/v1/auth/session-metadata` 验证项目、环境、认证域、签发者、受众和会话状态。绑定使用认证域和稳定的主体 ID。DevKit 密码由客户端直接交给 DevKit。应用关闭接入或 DevKit 停用账号时，新的 DevKit 登录会被拒绝。已经签发的 Agent OS 会话沿用 Agent OS 的有效期和停用规则。

## 配置及上线验证

通过 Server 环境变量 `AGENT_SERVER_DEVKIT_AUTH` 配置 JSON，字段为 `apiUrl`、`appOrigin`、`publishableKey`、`projectId`、`environmentId`、`realmId`、`issuer`、`audience`。使用 `devkit identity config --project agent-os --json` 核对身份范围。将实际网页来源加入同一 DevKit 项目的允许来源。若使用邮箱注册，将该来源下的 `/auth/devkit/verify` 加入 DevKit 邮箱验证回跳白名单并确认邮件送达。启用前应用数据库迁移。

用原有方式登录 Agent OS 测试账号，在账户设置打开「DevKit 账号 → 绑定账号」。如果还没有该项目的账号，先注册并验证邮箱，再绑定。绑定后可从 Web 或 iOS 登录页用该邮箱选择「使用 DevKit 登录」。确认两个入口返回同一个 Agent OS 用户 ID，并核对原角色、设备和会话。验证另一个认证域的令牌以及未绑定的账号无法登录。要暂停新入口，可移除环境变量并重启 Server。

### Web 飞书试点

使用固定 DevKit 提交生成的浏览器 SDK 构建 Web。在 DevKit 运行 `pnpm sdk:bundle` 取得同一版本的 `@devkit/client` 和 `@devkit/contracts`，在 Web 构建时为 `web-next/src/features/auth/devkit-browser-client.ts` 提供 `createDevKitBrowserClient`。Factory 使用公开的 `apiUrl` 和 `publishableKey` 创建 `ProjectAuthClient`，并使用独立的内存 session store。默认构建提供邮箱入口，包含 SDK 的构建在项目发现 `feishu` 后显示飞书入口。

1. 在同一 DevKit 认证域启用飞书，并在飞书测试应用中登记 DevKit 提供的精确回调。确认试点站点的 Origin 已获允许。
2. 用原有方式登录 Agent OS。打开「DevKit 账号 → 绑定账号」，输入该项目已验证的 DevKit 邮箱和密码，选择「继续绑定飞书」。Agent OS 确认两个账号的绑定后，点击「绑定飞书」并在弹窗内授权。先在账户设置完成绑定，确保飞书加入当前 DevKit 用户。
3. 退出 Agent OS，选择「使用 DevKit 飞书登录」。分别通过邮箱与飞书登录，核对 DevKit 用户页的同一用户包含两种登录方式，并核对 Agent OS 用户 ID、角色、设备及一条既有会话。另一个认证域或未绑定的身份仍应被 Agent OS 拒绝。

联调 iOS 可在构建时把 `AGENT_OS_DEFAULT_SERVER_URL` 指向独立 HTTPS 测试实例，并使用单独的 Bundle ID。生产构建使用默认线上地址。
