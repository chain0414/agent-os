# DevKit Project Auth 接入

DevKit 托管的 Agent OS 实例由指定的 DevKit 项目负责认证和账号管理。Agent OS 按原业务用户 ID 判断角色、设备和会话权限。自托管实例也可使用混合模式。

## 接口

- `GET /api/v2/auth/config` 在启用后返回 `devkit.apiUrl` 和 `devkit.publishableKey`。客户端用这两个公开配置访问 DevKit 项目的 Auth API。
- `POST /api/v2/auth/devkit/link` 接收 `{"accessToken":"<DevKit access token>"}`，要求在 Authorization 中提供当前 Agent OS 用户的有效会话。成功返回 204。重复绑定同一对账号可重试。账号已绑定到其他身份时返回 409。
- `POST /api/v2/auth/devkit/login` 接收同样的请求体，无需现有 Agent OS 会话。返回常规 `AuthResponse`。只有已绑定的活跃用户可登录。

Agent OS 向 DevKit 的 `/api/runtime/v1/auth/session-metadata` 验证项目、环境、认证域、签发者、受众和会话状态。绑定使用认证域和稳定的主体 ID。DevKit 密码由客户端直接交给 DevKit。应用关闭接入或 DevKit 停用账号时，新的 DevKit 登录会被拒绝。已经签发的 Agent OS 会话沿用 Agent OS 的有效期和停用规则。

## DevKit 托管模式

在 `AGENT_SERVER_DEVKIT_AUTH` 中设置 `"managedOnly": true`，由 DevKit 提供邮箱和飞书登录及用户管理。`GET /api/v2/auth/config` 在 `devkit.managedOnly` 返回该标志。启用前由运营方导入现有用户身份，并将 DevKit 主体对应到原业务用户 ID。启用后应用登录页使用 DevKit，停用 Agent OS 的本地登录、注册、密码恢复、身份绑定、用户管理和用户统计接口。应用继续按原业务用户 ID 授权已有设备和会话。原生应用的浏览器授权和扫码登录继续使用已有交换接口。配置无法解析时，登录配置与本地身份入口返回 503。移除配置变量可恢复独立运行模式。

### 托管实例的密码恢复

Web 登录页的「忘记密码」和账户设置的「修改密码」进入同一个邮箱确认流程。浏览器从 DevKit 的项目 Auth 接口申请重置链接，并将邮件链接中的一次性令牌和新密码直接交给 DevKit。Agent OS 不接收或保存新密码。本地认证的验证码和密码接口仍只用于非托管实例。

发布前，将实际 Web 来源下的 `/auth/devkit/reset-password` 登记为该项目的精确回跳 URL，保留现有的邮箱验证回跳。例如，`agent-os` 的生产回跳是：

```sh
devkit identity redirect add https://os.begrow.ai/auth/devkit/reset-password --project agent-os --yes --json
```

验收使用带可收邮件地址的已绑定测试身份：分别从登录页和账户设置发起请求；确认收到邮件、链接能打开重置表单；确认旧密码失败、新密码可登录到同一 Agent OS 用户，原角色、设备和会话仍可访问。重置完成不提前结束已经签发的 Agent OS 会话。对不符合重置条件的邮箱，页面同样提示检查邮件，以免暴露账号是否存在。

## 自托管混合接入配置及验证

通过 Server 环境变量 `AGENT_SERVER_DEVKIT_AUTH` 配置 JSON，字段为 `apiUrl`、`appOrigin`、`publishableKey`、`projectId`、`environmentId`、`realmId`、`issuer`、`audience`。使用 `devkit identity config --project agent-os --json` 核对身份范围。将实际网页来源加入同一 DevKit 项目的允许来源。若使用邮箱注册，将该来源下的 `/auth/devkit/verify` 加入 DevKit 邮箱验证回跳白名单并确认邮件送达。启用前应用数据库迁移。

用原有方式登录 Agent OS 测试账号，在账户设置打开「DevKit 账号 → 绑定账号」。如果还没有该项目的账号，先注册并验证邮箱，再绑定。绑定后可从 Web 或 iOS 登录页用该邮箱选择「使用 DevKit 登录」。确认两个入口返回同一个 Agent OS 用户 ID，并核对原角色、设备和会话。验证另一个认证域的令牌以及未绑定的账号无法登录。要暂停新入口，可移除环境变量并重启 Server。

### Web 飞书试点

在可信的 DevKit checkout 固定完整 Git SHA，运行 `corepack pnpm@10.13.1 sdk:bundle`。将生成的 `manifest.json` 和同批 `@devkit/client`、`@devkit/contracts` 两个 tarball 作为私有构建输入。将 `devkit_sdk_dir` 指向该产物目录，`devkit_sdk_commit` 设为预期的完整 Git SHA，再从 Agent OS 仓库根目录构建镜像。

```sh
docker buildx build --load -f docker/Dockerfile --target server-devkit \
  --build-context "devkit-sdk=$devkit_sdk_dir" \
  --build-arg "DEVKIT_SDK_SOURCE_COMMIT=$devkit_sdk_commit" \
  -t agents-anywhere-server:devkit .
```

构建会校验 manifest、完整提交和两个 tarball 的 SHA-256，再在构建阶段接入 SDK。浏览器用公开的 `apiUrl` 和 `publishableKey` 创建 `ProjectAuthClient`，每个实例的 session 单独保存在内存中。默认 `server` 镜像和普通 Web 构建无需 SDK。启用 SDK 后，项目发现 `feishu` 才显示飞书入口。

1. 在同一 DevKit 认证域启用飞书，并在飞书测试应用中登记 DevKit 提供的精确回调。确认试点站点的 Origin 已获允许。
2. 用原有方式登录 Agent OS。打开「DevKit 账号 → 绑定账号」，输入该项目已验证的 DevKit 邮箱和密码，选择「继续绑定飞书」。Agent OS 确认两个账号的绑定后，点击「绑定飞书」并在弹窗内授权。先在账户设置完成绑定，确保飞书加入当前 DevKit 用户。
3. 退出 Agent OS，选择「使用 DevKit 飞书登录」。分别通过邮箱与飞书登录，核对 DevKit 用户页的同一用户包含两种登录方式，并核对 Agent OS 用户 ID、角色、设备及一条既有会话。另一个认证域或未绑定的身份仍应被 Agent OS 拒绝。

联调 iOS 可在构建时把 `AGENT_OS_DEFAULT_SERVER_URL` 指向独立 HTTPS 测试实例，并使用单独的 Bundle ID。生产构建使用默认线上地址。
