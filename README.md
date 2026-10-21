# 声音记录仪（macOS 原生 MVP）

一款本地优先的 macOS 个人声音记录工具。它以菜单栏常驻方式运行；用户首次知情同意并授予权限后，应用按五分钟切片保存麦克风录音，异步转录，并提供按日回溯、关键词搜索、精确播放和片段导出。

## 已完成的技术验证与决策

| 议题 | 验证/结论 | MVP 决策 |
| --- | --- | --- |
| 开发环境 | 本机具备 Xcode 26.3、Swift 6.2、macOS 26.2 SDK，目标为 Apple Silicon。 | 使用 SwiftUI + AppKit + AVFoundation，最低支持 macOS 14。 |
| 麦克风与后台 | macOS 可通过 `AVCaptureDevice` 请求麦克风授权；关闭主窗口不会结束 Cocoa 应用，菜单栏项目可持续保活。 | `NSApplicationDelegate` 禁止“最后一个窗口关闭即退出”，并保留 `MenuBarExtra`。 |
| 睡眠唤醒 | `NSWorkspace` 提供 `didSleep`、`didWake` 通知。 | 系统睡眠前安全结束当前切片；唤醒时仅在非用户主动暂停、权限有效且空间充足时恢复。 |
| 长录音与容错 | `AVAudioRecorder` 原生支持 AAC/M4A；macOS 没有可直接用于 `AVAudioRecorder` 的原生 Opus 编码链路。 | 5 分钟 AAC/M4A 单声道、16 kHz、32 kbps 切片。完成写盘后原子改名并登记 SQLite；未完成的 `.partial.m4a` 不会冒充有效数据。 |
| 本地转录 | Apple Speech 可申请语音识别权限；可要求设备端识别，但本地语言包、机型与系统版本会决定可用性。 | 使用 `requiresOnDeviceRecognition = true`，按系统选择的中文或英文逐片异步转录。若不可用，录音仍保留，任务状态标记为可重试；不上传音频。 |
| 搜索 | SQLite 随 macOS 提供 FTS5；中文默认分词并不适合作为唯一检索策略。 | 同时保存 FTS5 索引和 Unicode `LIKE` 回退，以保证中文关键词的可用性。 |
| 开机启动 | macOS 13+ 的 `SMAppService.mainApp` 可请求“登录时打开”。 | 设置页提供开关并显示系统注册失败信息；首次使用时不会静默修改登录项。 |

> 真实设备验证仍是发布前的必要步骤：权限弹窗、长时间录音、睡眠唤醒、设备切换、磁盘耗尽、登录项和不同语言的设备端 Speech 语言包均须在目标 Mac 上测试。

## 架构

```text
SwiftUI / MenuBarExtra / Settings
              │
           AppModel
 ┌────────────┼───────────────────────────────────┐
 │            │                 │                 │
RecordingManager  PlaybackService       ExportService
 │            │                 │                 │
AudioRecorder  SleepWakeMonitor    AVQueuePlayer / AVComposition
 │
Segment (.partial.m4a → .m4a) ──► SQLite DatabaseManager ◄── TranscriptionService
                                      │                       (Apple Speech, 本地优先)
                                      └── FTS5 + 时间戳索引
```

录音引擎不依赖 UI、搜索或转录。切片先安全落盘，再登记数据库和入转录队列；因此识别失败、搜索故障或窗口关闭不会停止录音。

## 本地数据

应用数据仅存于：

```text
~/Library/Application Support/VoiceRecorder/
├── Audio/YYYY-MM-DD/*.m4a
├── Database/recordings.sqlite
├── Models/
└── Logs/
```

不会上传音频、文本或索引。录制他人谈话前，使用者应遵守所在地关于录音知情同意的法律。

## 构建与运行

```bash
cd VoiceRecorder
swift test
./Scripts/build-app.sh
open ../outputs/VoiceRecorder.app
```

也可以通过 Xcode 直接打开 `Package.swift`。首次使用时，应用显示本地存储与录音合规说明。用户点按“授权麦克风并开始记录”后，应用请求麦克风权限，并在授权成功后开始录音；语音识别权限随后单独请求。之后可通过主窗口或菜单栏暂停、继续录音。应用启动时不会自动开始录音。

## 分阶段实现状态

1. **录音引擎：已实现** — 权限引导、菜单栏状态、五分钟 M4A 切片、持久化用户暂停、睡眠唤醒和磁盘阈值检查。
2. **本地转录：已实现** — 设备端 Apple Speech 队列、时间戳、失败状态和重试入口；设备不支持语言包时保留原音频。
3. **核心界面：已实现** — 日期导航、转录时间线、24 小时时间轴和跨切片队列播放。
4. **检索与导出：已实现** — 本地 FTS5/中文回退搜索、跳转播放、时间段 M4A 合成导出和 TXT 导出。
5. **稳定性：已实现代码保护，待真实机验证** — 异常切片恢复、空间警告、登录项开关与数据库测试；72 小时稳定性测试需要在安装后的实际 Mac 上执行。
