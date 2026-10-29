# iOS Voice Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** iPhone 点按录音、设备端转写成草稿，用户确认后手动发送。

**Architecture:** 可测试的 ComposerVoiceInput 管理草稿快照、录音状态和回调寿命，ComposerSpeechRecognizing 隔离 Apple 音频与 SpeechAnalyzer。共享 ChatComposer 集成原生入口，维持原有发送链路。

**Tech Stack:** Swift、SwiftUI、Observation、AVAudioEngine、SpeechAnalyzer、Swift Testing。

**Spec:** `docs/superpowers/specs/2026-10-29-ios-voice-input.md`

## Global Constraints

- 仅修改当前 iOS 客户端及必要文档；无协议或版本号变更。
- 音频不上传、不落盘，无第三方 API Key。
- 转写从不自动发送；开始前保留草稿和附件。
- 保持公司签名团队 `67JNSQB28X`。

## Review Focus

- 取消后迟到的权限、下载和识别结果不能恢复录音或修改草稿。
- 暂定结果、修订结果和最终结果不能重复、错序或覆盖其他时间段。
- 中文候选、emoji 与选区使用 UTF-16 安全插入，不损坏原有文字。
- 新会话、切换会话、后台与错误必须停止麦克风，保留可确认文字。
- 窄屏、大字体、指令按钮与录音结束/取消入口不能重叠。

### Task 1: 草稿与录音状态

**Files:** `Models/Chat/ComposerVoiceInput.swift`、`Models/Chat/ComposerDraft.swift`、`Tests/ClientCoreTests/ComposerVoiceInputTests.swift`。

**Interfaces:** `ComposerSpeechRecognizing.start(locale:onEvent:) async throws`、`finish() async throws`、`cancel()`；事件含下载、录音、带时间范围的文字与失败。

- [x] 先编写取消、发送保护、部分结果修订、失效/替换草稿与迟到回调测试并观察缺实现失败。
- [x] 实现状态、范围合并、选区插入与失败恢复，使测试通过。

### Task 2: Apple 设备端识别

**Files:** `Services/ComposerSpeechRecognizer.swift`、`Info.plist`。

- [x] 实现语言与设备检测、模型安装、麦克风权限、PCM 格式转换、SpeechAnalyzer 输入及结果消费。
- [x] 处理取消、最终结果排空、输入格式变更和音频中断；验证 SDK 编译。

### Task 3: 共享输入框与交付验证

**Files:** `ChatComposer.swift`、`NativeComposerEditor.swift`、本地化目录、`CHANGELOG.md`、`ios/NATIVE_CHAT.md`、合成 UI probe。

- [x] 增加麦克风、状态、取消与收尾保护；保证 Command-Return 也不能绕过。
- [x] 补齐中英文本地化与麦克风用途说明，记录用户可感知行为。
- [x] 跑 SwiftPM、本地化、unsigned 构建；查看合成 UI 渲染并进行独立代码审核。
- [x] 记录真机验证的未覆盖范围，交付工作区与使用说明。
