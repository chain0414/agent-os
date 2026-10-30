# iOS 语音输入交付与验证记录

## 目标与实现

Wayne 要在 iPhone 上说出 Agent 指令，转成文字后检查再发送。本轮在独立分支 `feat/ios/voice-input` 实现新会话和已有会话共用的麦克风入口、结束/取消、实时草稿转写、发送保护及错误恢复，保留原目录中其他未提交的工作。

ASR 使用 Apple `SpeechAnalyzer`，优先设备端 `SpeechTranscriber`，同语言下可回退设备端 `DictationTranscriber`。无需第三方 API Key；模型首次下载可能联网，录音内容不上传或落盘。AA Server、Connector、Codex、DSH 收到的仍是用户确认的文字消息，未改变跨端协议。系统资源按进程协调，快速切换会话不会让旧会话释放新会话正在使用的模型预留。

## 已执行的检查（2026-10-29）

| 检查 | 输入与结果 | 能证明什么 |
| --- | --- | --- |
| SwiftPM | 263 项测试通过，其中 12 项新增语音状态测试使用假识别器 | 取消恢复、迟到回调、发送保护、Unicode 选区、无语音及收尾竞态等状态行为 |
| iOS 构建 | 完整 unsigned `generic/platform=iOS` Debug 构建通过，保留项目最低 iOS 26.5 | 当前 SDK 能编译完整客户端；不等于已签名安装 |
| 模拟器构建 | 完整客户端 generic simulator 编译通过；合成 probe 编译、安装运行通过 | 源码和模拟器界面可运行 |
| 本地化 | 935 个目录条目通过；223 个 Swift 文件的 808 个提取键均覆盖；36 项语音编译资源/麦克风用途检查通过；4 项共享文案测试通过 | 文案与权限说明在中英文构建资源中可用，不证明翻译或 ASR 语义准确 |
| 交互与渲染 | 真实输入框配合合成 ASR：空白新会话、录音、收尾、下载、错误、320 pt 窄屏及大字体；结束后发送计数为 0，手动点发送变为 1 | 控件可操作、取消保留原稿、不会自动发送；未访问真实 Agent |
| 音频转换 | 主机真实 AVAudioConverter、合成 440 Hz PCM：48k 双声道→16k、44.1k→16k、16k 直通均通过 | 缓冲复制、转换和时间戳连续；不代表手机麦克风或蓝牙输入已验证 |
| 资源协调 | 服务生命周期代码搭配受控的下载/释放替身，通过延迟清理、跨实例抢占、取消和预留释放顺序检查 | 被模拟时序下不会恢复已取消录音，释放/预留顺序正确；不是 Apple 服务的实测结果 |
| 静态检查与审查 | `git diff --check`、常见凭据格式扫描通过；独立代码审核已复查并关闭所发现的问题 | 未发现本轮确定的源码问题，不覆盖真机行为 |

## 环境限制与已有失败

本机 Xcode/SDK 与可用模拟器为 26.2，项目最低系统版本为 26.5。完整 iOS 构建保持 26.5，Xcode 因 SDK 较旧给出版本范围警告；模拟器编译/合成 probe 仅在验证命令中使用 26.2，未改工程配置。AppIntents 元数据提取仍有无依赖提示。

原有 `ios/Tests/LocalizationProbe.swift` 在 DSH 权限模式英文名称上失败：测试期望 `read-only`，现有源目录与实际产物为 `Read Only`。两者在本轮开始前已经不一致；本轮未修改该测试或权限文案。语音功能使用独立的 `VoiceInputLocalizationProbe.swift` 验证实际编译资源。构建提取同时发现已有「回复」缺少目录条目，本轮补齐该条目及新增的「打开设置」。

尚未验证真实 iPhone 麦克风权限流程、中文/英文混说准确率、首次模型下载及取消、蓝牙切换、离线识别、后台/来电中断和真实 Agent 消息投递；未签名安装、未上传 TestFlight、未发布。

## 复核材料

源码测试：`ios/Tests/ClientCoreTests/ComposerVoiceInputTests.swift`、`ios/Tests/VoiceInputProbe.swift`、`ios/Tests/VoiceInputLocalizationProbe.swift`；运行说明见 `ios/NATIVE_CHAT.md` 的「语音输入」。本地构建日志与临时探针位于 Git 忽略的 `ios/.build/voice-*`，音频/协调探针的重跑入口为 `ios/.build/voice-engine-probes/README.md`。这些路径属于本轮工作区，不随提交发布。

## 2026-10-30 真机安装更新

Wayne 授权将此分支安装到自己的 iPhone 测试。已同步 Debug/Release 签名团队为公司团队 `67JNSQB28X`，使用现有 Xcode/Keychain 中的 ying zhang 开发证书签名；未变更 Bundle ID、发布归属或执行 TestFlight/App Store 上传。

完整签名 Debug 构建通过，产物为 `com.agentsanywhere.app`，版本 `2.1.0`、构建 `11`；验证了签名有效、团队与 application identifier 一致、开发描述文件包含目标 iPhone、麦克风用途说明存在。通过 USB 更新安装到「Maze-13promax」（iOS 27.0.1），安装命令成功，随后启动成功。真实语音输入、中文准确率、首次模型下载及离线识别交由 Wayne 在该机体验，本次安装与启动成功不代表这些能力已经验收。
