# iOS App Store 与 TestFlight 元数据（已保存值与待补字段）

> 状态：**尚不可提交审核**。iOS 与 macOS 已建立 Universal Purchase 记录并统一为 `0.6.1`。下文的双语名称、副标题、推广文本、描述、关键词、URL、TestFlight Beta App Description 与手动发布方式均已保存到 App Store Connect。尚未完成的范围只包括截图、法律/版权信息、联系人、DSA、价格/地区、Content Rights、年龄分级、Build、App Privacy 问卷和审核；不得把已保存元数据写成 Build 已上传、TestFlight 已发布或审核已提交。

## 1. App Store 全局信息

| 字段 | App Store Connect 当前值 |
| --- | --- |
| App 名称 | MAC版灵动岛--Agent运行监测 |
| 平台 | iOS |
| App Store 记录模式 | Universal Purchase（与 macOS 共用记录） |
| App Store Connect App ID | `6808917414` |
| iOS Bundle ID | `com.kiki.agentisland` |
| Widget Bundle ID | `com.kiki.agentisland.liveactivity` |
| Team ID | `AW4HMBZN7M` |
| SKU | `AGENTISLAND-UNIVERSAL` |
| 主语言 | 简体中文 |
| 主类别 | Developer Tools |
| 次类别 | Productivity |
| 年龄分级 | `[根据最终构建完成问卷并记录结果]` |
| 内容权利（Content Rights） | `[核实工具名、用户同步内容及商店素材权利后选择]` |
| 许可协议 | `[使用 Apple 标准 EULA，或提供最终自定义协议]` |
| DSA 交易者状态 | `[由 Account Holder 确认 trader / non-trader 及所需联系验证]` |
| 价格 | `[免费或具体价格档位]` |
| 上架国家/地区 | `[最终可用范围；另行完成中国大陆、韩国、越南等区域要求]` |
| 版本发布方式 | 审核通过后手动发布（Manual） |
| 版权 | `[年份] [版权所有者]` |
| 隐私政策 URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/` |
| 隐私选择 URL（简体中文） | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/#delete-data` |
| Privacy Choices URL（English U.S.） | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/#delete-data-en` |
| 支持 URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/` |
| 支持页公开联系方式 | `[可验证的邮箱、国际电话或法律联系地址]`；仅 GitHub Issues 不应作为最终联系资料 |
| 营销 URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/` |
| App Store 版本 | `0.6.1`；工程当前 Build `8`，尚未上传 |
| 最低系统 | iOS 17.0（当前工程配置） |
| 支持设备 | iPhone；是否开放 iPad 兼容安装须以最终 Target/QA 决定 |
| 登录/IAP | 当前无应用账号、订阅或 App 内购买 |
| 加密出口合规 | 代码当前声明 `ITSAppUsesNonExemptEncryption = false`；仍由提交者按最终构建与所在地要求确认 |
| CloudKit | `iCloud.com.kiki.agentisland`；Private / Production / `AgentIslandSnapshot` / `latest` / `payloadJSON` |

iOS 与 macOS 已放在 App Store Connect App ID `6808917414` 的同一个 Universal Purchase 记录中；平台名称、价格和 App Privacy 回答必须保持兼容，各平台版本仍需分别配置和提交审核。

Production schema 已部署。公共数据库的兜底权限仅 `_icloud` CREATE、`_creator` READ + WRITE，没有 `_world` READ；iOS App 仍固定读取用户私有数据库。iOS App Store 与 Widget App Store profiles 已生成并存放在 Git 忽略的本地发布目录，但尚未绑定最终 Archive 验证。

App Store Connect 的 Content Rights、年龄分级、DSA 状态和地区范围是账号/业务决策，不能从 Xcode 工程自动推导。上表任一方括号项未由有权提交者完成时，即使 IPA 已通过本地预检也仍不应进入 App Review。

## 2. 简体中文（zh-Hans）

### 名称（最多 30 个字符）

MAC版灵动岛--Agent运行监测

### 副标题（最多 30 个字符）

Mac AI Agent 运行看板

### 推广文本（最多 170 个字符）

在 Mac 明确启用私有同步后，于 iPhone 刷新查看 AI Agent、活跃对话、时长与 Token 摘要，并把最近状态带到锁屏和灵动岛。

### 描述（最多 4,000 个字符）

MAC版灵动岛--Agent运行监测的 iPhone 伴侣版是一款隐私优先看板。在 Mac 与 iPhone 使用同一 iCloud 账户并明确启用私有同步后，可查看经过精简的 Agent 状态、活跃对话数、工作时长和 Token 摘要。它支持锁屏 Live Activity 与灵动岛，不直接浏览 Mac 文件，并在未配置同步时显示明确空状态。

### 关键词（不超过 100 字节；提交前复核）

智能体,令牌用量,开发工具,实时活动,效率工具,状态看板

## 3. English (U.S.)

### Name (30 characters maximum)

MAC版灵动岛--Agent运行监测

### Subtitle (30 characters maximum)

AI Agent Monitor for Mac

### Promotional text (170 characters maximum)

Enable private sync on Mac, then refresh iPhone to see agents, conversations, time, and tokens on the Lock Screen and Dynamic Island.

### Description (4,000 characters maximum)

The iPhone companion for MAC版灵动岛--Agent运行监测 is a privacy-first dashboard. After explicit private sync under the same iCloud account is enabled on both devices, it shows a minimized summary of agent status, active conversations, working time, and token usage. It supports Lock Screen Live Activities and Dynamic Island, never browses Mac files directly, and presents a clear empty state when sync is not configured.

### Keywords (100 bytes maximum; recheck before submission)

AI monitor,token usage,developer tools,Live Activity,Mac companion

## 4. TestFlight 信息

### 已保存 URL 与待补联系人

| 字段 | App Store Connect 当前值 |
| --- | --- |
| Marketing URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/` |
| Privacy Policy URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/` |
| Feedback Email | `[TestFlight反馈邮箱]` |
| Contact First Name | `[审核联系人名]` |
| Contact Last Name | `[审核联系人姓]` |
| Contact Phone | `[审核联系电话]` |
| Contact Email | `[审核联系邮箱]` |
| Sign-in required | 无独立应用账号；当前设计要求两台设备使用同一系统 iCloud 账户。按 TestFlight 当时字段口径如实填写 |
| Beta App Review Notes | 见 `IOS_APP_REVIEW_NOTES.md` |

Beta App Description 和两个 URL 已保存。联系人、Build 和 Beta App Review 仍未完成；首个外部测试 Build 可能需要 Beta App Review。

### Beta App Description — 简体中文

在 iPhone 查看 Mac 产生的隐私化 Agent 状态摘要，并验证锁屏 Live Activity 与灵动岛展示。

### Beta App Description — English

View privacy-minimized Mac agent status on iPhone and verify the Lock Screen Live Activity and Dynamic Island presentation.

### What to Test — 简体中文（待 Build 关联/审核时使用）

请重点测试：

1. 从同步卡片下进入示例模式，核对看板/锁屏/灵动岛的示例标识，再“退出并重置”；确认示例未被表示为真实同步。
2. Mac 与 iPhone 使用同一 iCloud 账户时的首次同步、禁用、恢复和账号切换。
3. Agent 数、活跃对话、时长和 Token 是否与同一时刻的 Mac 摘要一致。
4. 下拉刷新、离线缓存、陈旧数据、iCloud/网络不可用和账号切换。
5. 完整标题默认隐藏；选择显示后，离开前台或重启都会再次隐藏。
6. 开启/更新/停止 Live Activity，验证它只在 App 启动、回前台或手动刷新时获得新状态；强制结束并重启 App 时已存在活动的控制状态会恢复；两分钟无更新时明确显示过期，以及无活跃 Agent 和系统禁用时的提示。
7. 支持灵动岛和不支持灵动岛的 iPhone、深浅色、旋转、Dynamic Type、VoiceOver 与中英文。

反馈时请注明 iPhone 型号、iOS 版本、Mac 版本、是否使用缓存，以及问题发生前的操作。不要在反馈截图中包含真实项目名、会话标题或密钥。

### What to Test — English (for Build association/review)

Please focus on:

1. Enter example mode below the sync card, verify the sample labels on the dashboard, Lock Screen, and Dynamic Island, then Exit & reset; confirm that it is never represented as real sync.
2. First sync, disabling/re-enabling sync, and account changes under the same iCloud account on Mac and iPhone.
3. Whether agent count, active conversations, time, and tokens match the same privacy-minimized Mac snapshot.
4. Pull to refresh, offline cache, stale data, unavailable iCloud/network, and account changes.
5. Full titles being hidden by default and hidden again after the app leaves the foreground or relaunches.
6. Starting, updating, and stopping Live Activities; verify that new state arrives only on app launch, foreground return, or manual refresh, that relaunch restores the control state of an existing activity, that two minutes without a host-app update is visibly stale, and that no-active-agent/system-disabled states are handled.
7. Devices with and without Dynamic Island, light/dark appearance, rotation, Dynamic Type, VoiceOver, English, and Simplified Chinese.

Include the iPhone model, iOS version, Mac app version, cache status, and steps before the issue. Do not include real project names, conversation titles, or credentials in feedback screenshots.

## 5. 年龄分级与 App Privacy 提醒

- 当前功能无广告、公开用户内容、社交发布、购买、赌博、医疗或位置功能；仍须按提交当日完整问卷作答。
- App 不内嵌网页浏览或翻译模型；iOS 只展示同步摘要和 Live Activity。
- iOS App Target 的 Privacy Manifest 已同时声明与用户关联的 Other Usage Data 和 Other User Content，用于 App Functionality、不用于追踪，且无 tracking domains；后者覆盖当前候选版中默认关闭、需单独同意的完整标题同步。它还为应用自身的示例模式布尔开关声明 UserDefaults `CA92.1` 理由。Widget Extension 有独立清单，collected data/accessed API/tracking domains 均为空，tracking 为 false。最终签名构建仍必须通过 Xcode Privacy Report 复核，并在 App Store Connect 采用相同口径；加入 APNs 或其他网络路径时再次更新。
- 若 iOS 与 macOS 共用同一 App Store Connect 记录，App Privacy 回答应覆盖该记录中所有平台的最全面实际行为。
- 不把同步 Token 描述为账单、每日趋势或跨工具绝对精确值。

## 6. 提交前删除/替换

- 补齐年龄分级、Content Rights、DSA、价格/地区、版权、支持联系方式与审核联系人等人工字段；正式 Bundle ID、Widget ID、SKU、版本和 App Store Connect App ID 不得改回占位值。
- 在真正可提交时更新顶部状态，不得只删除“尚不可提交审核”提示而跳过门禁。
- 只有生产同步、配对、缓存和错误恢复都可审核时，才保留“连接 Mac 后查看”的产品描述。
- 最终 Build 若不支持横屏或 iPad，应让元数据与实际一致；当前 Live Activity 明确不支持 APNs 远程更新，元数据、截图和审核说明不得暗示后台实时监控。
- 可以展示最终构建中带持续“示例/非真实数据”标识的内置示例 UI，但不得裁掉标识，也不得将示例或 Preview 数据写成真实同步已完成；若截图声称跨设备同步，必须来自已验收的真实生产链路。

## 7. Apple 官方参考

- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Required, localizable, and editable properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [Overview of Accessibility Nutrition Labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels)
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
- [Provide TestFlight test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)
- [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
