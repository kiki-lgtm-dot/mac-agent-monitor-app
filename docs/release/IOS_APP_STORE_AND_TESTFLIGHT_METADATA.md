# iOS App Store 与 TestFlight 元数据草案

> 状态：**不可提交**。当前 iOS 工程版本为 0.1.0（Build 1），SwiftUI 看板、Widget/Live Activity Extension、按 iCloud 账号隔离的私有 CloudKit receiver、离线缓存、双语资源和图标已经存在；Mac producer 也已实现并通过本地 CLI/回归。但 Bundle/Container ID 与 Team 仍为占位配置，真实 Developer ID CloudKit entitlement/profile、Production schema、同一 iCloud 账号 Mac→iPhone 真机链路以及完整 Xcode+iOS SDK 编译、真机 Live Activity 和 Archive 验证均未完成。以下产品文案只可在这些发布门槛通过后使用。

## 1. App Store 全局信息

| 字段 | 建议值 |
| --- | --- |
| App 名称 | MAC版灵动岛--Agent运行监测 |
| 平台 | iOS |
| iOS Bundle ID | `[正式iOS Bundle ID]`（替换 `com.example.agentisland`） |
| Widget Bundle ID | `[正式iOS Widget Bundle ID]`（建议为 App ID + `.liveactivity`） |
| Team ID | `[10位Team ID]` |
| SKU | `[iOS SKU]` |
| 主语言 | 简体中文（可按实际市场调整） |
| 主类别 | Developer Tools |
| 次类别 | Productivity |
| 价格 | `[免费或具体价格档位]` |
| 版权 | `[年份] [版权所有者]` |
| 隐私政策 URL | `[隐私政策URL]` |
| 支持 URL | `[支持URL]` |
| 营销 URL | `[营销URL，可选]` |
| 实际提交版本 | `[例如 1.0.0]`；不要直接沿用开发骨架 0.1.0 |
| 最低系统 | iOS 17.0（当前工程配置） |
| 支持设备 | iPhone；是否开放 iPad 兼容安装须以最终 Target/QA 决定 |
| 登录/IAP | 当前无应用账号、订阅或 App 内购买 |

如果 iOS 与 macOS 放在同一个 App Store Connect App 记录中，应确认平台名称、价格、隐私标签和通用购买策略一致；各平台版本仍需分别提交审核。

## 2. 简体中文（zh-Hans）

### 名称（最多 30 个字符）

MAC版灵动岛--Agent运行监测

### 副标题（最多 30 个字符）

Mac AI Agent 随身看板

### 推广文本（最多 170 个字符）

在 Mac 明确启用私有同步后，于 iPhone 刷新查看 AI Agent、活跃对话、时长与 Token 摘要，并把最近刷新的状态带到锁屏和灵动岛。

### 描述（最多 4,000 个字符）

“MAC版灵动岛--Agent运行监测”的 iPhone 伴侣版是一款隐私优先看板。在 Mac 与 iPhone 使用同一 iCloud 账户并启用同步后，无需回到电脑前，也能查看经过精简的 AI Agent 工作摘要。

刷新查看运行状态
• 查看相关 Agent、正在运行数量和活跃对话数量
• 保留 Mac producer 主动筛选纳入的全部工具，即使它当前无会话或无可验证 Token，也会用真实空闲/完成状态显示
• 查看每个 Agent 的状态、工具、工作时长与同步 Token 摘要
• 按工作状态和更新时间优先展示真正相关的 Agent
• 下拉刷新并查看数据更新时间与缓存状态

锁屏与灵动岛
• 主动开启或停止 Live Activity
• 在锁屏查看运行状态、工作时长和 Token
• 在支持的 iPhone 灵动岛查看 Agent 数、活跃对话和 Token
• Live Activity 不显示完整对话标题
• 状态仅在 App 启动、回到前台或手动刷新时更新，不是 APNs 后台实时监控
• App 重启后会恢复已存在 Live Activity 的控制状态；两分钟无主 App 更新时会明确标记为过期

隐私优先
iPhone 不会直接读取或浏览 Mac 文件。Mac 私有同步默认关闭，只有用户阅读字段范围并明确开启后，才会向其 iCloud 私有数据库写入为手机设计的状态摘要。数据模型不包含 prompt、任务摘要、回复、模型名、API Key、进程 ID、备忘录、翻译内容、Mac 文件路径或工作区路径。完整对话标题默认不发送，需要单独明确同意；即使用户选择同步标题，iPhone 每次启动也会重新隐藏。用户在 Mac 关闭同步时，应用会停止上传并删除云端 `latest` 快照。

Token 来自 Mac 端可验证的本地数据源摘要，可能受工具支持、日志保留和来源质量影响，不代表服务商账单。

需要 iOS 17.0 或更高版本，并需要安装兼容的 Mac 版应用，在两台设备使用同一 iCloud 账户并启用同步。没有同步时，iPhone 会显示明确的未配置状态，不会生成或猜测 Agent 数据。

### 关键词（不超过 100 字节；提交前复核）

智能体,令牌用量,开发工具,实时活动,效率工具,状态看板

### 首版“此版本的新功能”

• 在 iPhone 查看 Mac 上的 Agent 状态摘要
• 展示运行中 Agent、活跃对话、工作时长和 Token
• 支持锁屏 Live Activity 与灵动岛状态
• 默认隐藏完整对话标题并排除 prompt、回复和 Mac 路径
• 支持简体中文与 English

## 3. English (U.S.)

### Name (30 characters maximum)

MAC版灵动岛--Agent运行监测

### Subtitle (30 characters maximum)

AI Agent Monitor for Mac

### Promotional text (170 characters maximum)

Enable private sync on Mac, then refresh iPhone to see agents, conversations, time, and tokens on the Lock Screen and Dynamic Island.

### Description (4,000 characters maximum)

The iPhone companion for MAC版灵动岛--Agent运行监测 is a privacy-first dashboard. After enabling sync under the same iCloud account on both devices, it lets you check a minimized summary of AI-agent activity without returning to your computer.

See current activity
• View relevant agents, running-agent count, and active-conversation count
• Preserve every tool deliberately included by the Mac producer, even when it currently has no conversation or verified token usage, while showing its true idle/completed state
• See each agent's state, tool, active time, and synced token summary
• Keep working agents and recently updated activity in focus
• Pull to refresh and see when data was generated or loaded from cache

Lock Screen and Dynamic Island
• Start or stop a Live Activity explicitly
• See status, active time, and tokens on the Lock Screen
• See agent count, active conversations, and tokens on supported Dynamic Island devices
• Live Activities never display full conversation titles
• Status updates only when the app launches, returns to the foreground, or is manually refreshed; this build has no APNs background real-time updates
• Relaunching the app restores the control state of an existing Live Activity; two minutes without a host-app update is visibly marked stale

Privacy first
The iPhone app never browses or reads files on your Mac. Private sync is off by default on the Mac and starts only after the user reviews the field scope and expressly opts in. The Mac then writes a mobile-specific status summary to the user's private iCloud database. The schema has no fields for prompts, task summaries, responses, model names, API keys, process identifiers, notes, translation content, Mac file paths, or workspace paths. Full conversation titles are excluded by default and require a separate opt-in. Even then, the iPhone hides them again on every launch. Turning sync off on the Mac stops uploads and deletes the cloud `latest` snapshot.

Token values come from verifiable local-source summaries on the Mac. They may be incomplete because of tool support, log retention, or source quality and are not provider billing totals.

Requires iOS 17.0 or later, the compatible Mac app, and sync enabled under the same iCloud account on both devices. When sync is not configured, the iPhone shows a clear empty state and never invents agent data.

### Keywords (100 bytes maximum; recheck before submission)

AI monitor,token usage,developer tools,Live Activity,Mac companion,productivity

### Initial What's New

• View privacy-minimized Mac agent status on iPhone
• See running agents, active conversations, active time, and tokens
• Use a Lock Screen Live Activity and Dynamic Island status
• Keep full conversation titles hidden by default and exclude prompts, responses, and Mac paths
• Use the app in English or Simplified Chinese

## 4. TestFlight 信息

### 必填公共字段

| 字段 | 草案 |
| --- | --- |
| Feedback Email | `[TestFlight反馈邮箱]` |
| Contact First Name | `[审核联系人名]` |
| Contact Last Name | `[审核联系人姓]` |
| Contact Phone | `[审核联系电话]` |
| Contact Email | `[审核联系邮箱]` |
| Sign-in required | 无独立应用账号；当前设计要求两台设备使用同一系统 iCloud 账户。按 TestFlight 当时字段口径如实填写 |
| Beta App Review Notes | 见 `IOS_APP_REVIEW_NOTES.md` |

外部测试前这些字段和 Beta App Description 必须填写。首个外部测试 Build 可能需要 Beta App Review。当前代码链路已实现，但在正式签名、Production schema、同账号真机和 Archive 验证通过前，仍只适合内部开发，不应邀请外部测试者。

### Beta App Description — 简体中文

MAC版灵动岛--Agent运行监测 iPhone Beta 是 Mac Agent 状态的隐私化伴侣看板。在 Mac 与 iPhone 使用同一 iCloud 账户，并在 Mac 上阅读范围后明确开启私有同步，可查看运行中 Agent、活跃对话、工作时长和 Token 摘要，并测试锁屏 Live Activity 与灵动岛。同步摘要不包含 prompt、任务摘要、回复、模型名、API Key、备忘录、翻译内容或 Mac 路径，完整对话标题默认不发送且每次启动重新隐藏。Live Activity 仅在 App 启动、回前台或手动刷新时更新。

### Beta App Description — English

MAC版灵动岛--Agent运行监测 for iPhone Beta is a privacy-minimized companion for Mac agent status. After reviewing the scope and expressly enabling private sync on a Mac that uses the same iCloud account, it shows running agents, active conversations, active time, and token summaries and lets testers exercise the Lock Screen Live Activity and Dynamic Island. Synced summaries exclude prompts, task summaries, responses, model names, API keys, notes, translation content, and Mac paths. Full titles are excluded by default and hidden again on every launch. Live Activity updates occur only on app launch, foreground return, or manual refresh.

### What to Test — 简体中文

请重点测试：

1. Mac 与 iPhone 使用同一 iCloud 账户时的首次同步、禁用、恢复和账号切换。
2. Agent 数、活跃对话、时长和 Token 是否与同一时刻的 Mac 摘要一致。
3. 下拉刷新、离线缓存、陈旧数据、iCloud/网络不可用和账号切换。
4. 完整标题默认隐藏、选择显示后重启再次隐藏。
5. 开启/更新/停止 Live Activity，验证它只在 App 启动、回前台或手动刷新时获得新状态；强制结束并重启 App 时已存在活动的控制状态会恢复；两分钟无更新时明确显示过期，以及无活跃 Agent 和系统禁用时的提示。
6. 支持灵动岛和不支持灵动岛的 iPhone、深浅色、旋转、Dynamic Type、VoiceOver 与中英文。

反馈时请注明 iPhone 型号、iOS 版本、Mac 版本、是否使用缓存，以及问题发生前的操作。不要在反馈截图中包含真实项目名、会话标题或密钥。

### What to Test — English

Please focus on:

1. First sync, disabling/re-enabling sync, and account changes under the same iCloud account on Mac and iPhone.
2. Whether agent count, active conversations, time, and tokens match the same privacy-minimized Mac snapshot.
3. Pull to refresh, offline cache, stale data, unavailable iCloud/network, and account changes.
4. Full titles being hidden by default and hidden again after relaunch.
5. Starting, updating, and stopping Live Activities; verify that new state arrives only on app launch, foreground return, or manual refresh, that relaunch restores the control state of an existing activity, that two minutes without a host-app update is visibly stale, and that no-active-agent/system-disabled states are handled.
6. Devices with and without Dynamic Island, light/dark appearance, rotation, Dynamic Type, VoiceOver, English, and Simplified Chinese.

Include the iPhone model, iOS version, Mac app version, cache status, and steps before the issue. Do not include real project names, conversation titles, or credentials in feedback screenshots.

## 5. 年龄分级与 App Privacy 提醒

- 当前功能无广告、公开用户内容、社交发布、购买、赌博、医疗或位置功能；仍须按提交当日完整问卷作答。
- App 不内嵌网页浏览或翻译模型；iOS 只展示同步摘要和 Live Activity。
- iOS App Target 的 Privacy Manifest 已同时声明与用户关联的 Other Usage Data 和 Other User Content，用于 App Functionality、不用于追踪，且无 tracking domains；后者覆盖当前候选版中默认关闭、需单独同意的完整标题同步。Widget Extension 有独立清单，collected data/accessed API/tracking domains 均为空，tracking 为 false。正式签名/Container/schema 验收后必须通过 Xcode Privacy Report 复核，并在 App Store Connect 采用相同口径；加入 APNs 或其他网络路径时再次更新。
- 若 iOS 与 macOS 共用同一 App Store Connect 记录，App Privacy 回答应覆盖该记录中所有平台的最全面实际行为。
- 不把同步 Token 描述为账单、每日趋势或跨工具绝对精确值。

## 6. 提交前删除/替换

- 替换所有方括号占位符和开发 Bundle ID。
- 删除“不可提交”“草案”等内部提示。
- 只有生产同步、配对、缓存和错误恢复都可审核时，才保留“连接 Mac 后查看”的产品描述。
- 最终 Build 若不支持横屏或 iPad，应让元数据与实际一致；当前 Live Activity 明确不支持 APNs 远程更新，元数据、截图和审核说明不得暗示后台实时监控。
- 不使用 Preview 数据制作声称真实同步已完成的商店截图。

## 7. Apple 官方参考

- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
- [Provide TestFlight test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)
- [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
