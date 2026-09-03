# iOS App Review Notes 草案

> 当前状态：**不可提交**。Mac CloudKit producer 和按 iCloud 账号隔离的 iPhone receiver/离线缓存代码链路已实现，producer 的本地 CLI/回归已通过。但真实 Developer ID CloudKit entitlement/provisioning profile、正式 Container 与 Production schema、同一 iCloud 账号 Mac→iPhone 真机链路、完整 Xcode+iOS SDK 构建、真机 Live Activity 和 Archive 尚未验证。以下文本是这些发布门槛通过后的审核模板，不得把代码完成写成生产同步已可用。

## 1. 提交前必须准备

- `[审核联系人姓名、电话、邮箱]`
- `[最终、已检查冲突的 App Store 展示名]`；当前公开工作名为 `MAC版灵动岛--Agent运行监测`，
  但仍需完成商店与商标可用性核验。
- `[正式 iOS App Bundle ID]` 与 `[正式 Widget Bundle ID]`
- 当前设计使用用户私有 CloudKit；若最终改为其他传输，提交前重写全部相关说明。
- `[从 Mac 配对、授权并产生第一份摘要的逐步操作]`
- 内置审核演示模式已经实现；提交时保留下面的精确进入、退出和重置步骤。
- `[审核期间保持可用的支持 URL 与隐私政策 URL]`
- 一台支持 Dynamic Island 的设备不是审核前提；锁屏 Live Activity 必须在普通兼容 iPhone 上也能审核。

Apple 不应被要求自行安装 Codex/Claude、创建付费 AI API Key、运行终端脚本或提供个人 Mac 数据才能进入 App 核心功能。最稳妥方案是加入明确标记的离线审核数据集，且审核模式的行为与生产 UI 相同。

## 2. English submission draft

The iPhone companion for MAC版灵动岛--Agent运行监测 displays a privacy-minimized snapshot produced by the Mac app: relevant agents, running-agent count, active-conversation count, state, active time, token usage, tool names, and privacy-preserving conversation placeholders. The current Mac producer leaves the schema's `safeSummary` field empty; it does not derive a task summary from prompts or responses.

This iPhone app does not scan, mount, or browse the Mac filesystem. The sync schema has no fields for prompts, response bodies, API keys, process identifiers, Mac file paths, or workspace paths. Full conversation titles are optional, excluded by default at the Mac source, and hidden again every time the iPhone app starts. Live Activities never contain conversation titles.

There is no separate app account, purchase, subscription, advertising, analytics SDK, or tracking. The Mac and iPhone must use the same signed-in iCloud account because the summary is stored in that user's private CloudKit database. Private sync is off by default on the Mac and begins only after the user reviews the field scope and expressly opts in. Conversation-title sync is a separate opt-in and remains off by default.

The submitted Release build also contains an explicit, offline example mode for review. Its agents, conversations, durations, and token values are fictional, generic, non-sensitive bundle data. The dashboard, Lock Screen, and Dynamic Island visibly identify the sample. Example mode does not access CloudKit, does not write the synced cache, and does not prove that production sync has been exercised.

### Review setup

Use the built-in example path first; it requires no account, credential, Mac, paid AI service, or network access:

1. Launch the iPhone app.
2. Below the sync-status card, select **Explore with example data**.
3. Read the disclosure and select **Show example dashboard**.
4. Confirm that the sync header says **EXAMPLE DATA**, the orange card says **EXAMPLE MODE · SAMPLE DATA**, and the source line says **Built-in sample · Not synced**.
5. Review the summary and Agent cards. Every displayed name and conversation is generic sample content; full conversation titles are unavailable.
6. Select **Start Live Activity**. On the Lock Screen and Dynamic Island, verify the **SAMPLE** text, sample description, purple treatment, or test-tube symbol appropriate to the available presentation size.
7. Return to the app and select **Exit & reset example mode**. The Boolean preference is removed, the sample disappears, any sample Live Activity ends, and the app immediately resumes its normal CloudKit refresh path.

To separately inspect the real same-iCloud production path after the production signing/schema checklist has passed:

1. Install the attached/referenced compatible Mac build: `[location and version]`.
2. Use a review Mac and iPhone signed into the same system iCloud account. The app does not request or receive the Apple Account password; do not include Apple Account credentials in Review Information.
3. In the Mac app, open Settings → “iPhone · Private iCloud sync,” turn on “Enable private sync,” review and confirm the exact off-device fields, then select “Sync now.” Do not enable conversation-title sync unless the review case specifically tests the separate sensitive-field consent.
4. Start the provided non-sensitive sample agent session: `[exact method that does not require the reviewer to buy a service]`.
5. Pull to refresh on iPhone. The sync header should change from “Mac sync not configured” to the final connected/cached state.

### Core feature review

1. On the dashboard, verify the summary cards for relevant agents, running agents, active conversations, and tokens. The iPhone preserves every tool deliberately included by the Mac producer, including a tool with no current conversation or measured usage; such a tool retains its true idle/completed state and is not counted as working.
2. Scroll to an Agent card to see state, tool name, active time, token usage, and up to three privacy-preserving conversation entries.
3. Full titles are absent from the built-in example. In the production CloudKit path they remain unavailable unless the source Mac explicitly opted in. If a production review dataset includes titles, select the eye button to reveal them, terminate and relaunch the app, and verify that they are hidden again.
4. With at least one working agent in the synced snapshot, select “Start Live Activity.” The button is intentionally disabled when there is no active agent.
5. View the Lock Screen Live Activity. On a supported device, also inspect compact, minimal, and expanded Dynamic Island presentations.
6. In example mode, select **Exit & reset example mode** and verify that its Live Activity ends immediately. In the production path, refresh after the real source Agent stops; the activity updates from the new validated snapshot and ends when no active agent remains.
7. For the production path, turn private sync off on the Mac and confirm deletion. On the next iPhone refresh, the missing `latest` record clears only the current iCloud account's cached snapshot and returns the dashboard to its empty state.

### Live Activity update behavior

This build starts, updates, and ends the Live Activity from the host iPhone app. ActivityKit receives new state only when the app launches, returns to the foreground, or the user manually refreshes. It does not use APNs push-to-start or remote Live Activity updates and is not continuous background monitoring. `[Replace only if the final build adds a reviewed APNs path.]`

If a Live Activity already exists when the app relaunches, the dashboard restores its running control state by reading ActivityKit. Activity content uses a two-minute `staleDate`; after that, the Lock Screen and Dynamic Island show the localized stale label and orange treatment until the host app updates or ends it.

The Live Activity includes running-agent count, active-conversation count, longest active duration, active-agent token total, status, and last-update time. It uses the generic source label “Mac” and contains no conversation title or personal computer name.

### Local cache and validation

The iPhone app stores only the latest validated production summary in an account-specific sandbox directory keyed by an irreversible SHA-256 digest of the current CloudKit user record identifier. The cache is written atomically with iOS file protection. Incoming payloads are capped at 2 MB and validated for agent/conversation counts, text lengths, timestamps, and token consistency before storage. A missing cloud record clears only that account's cache. Sign-out or account changes never fall back to another account's snapshot; a temporary fetch failure may use only the last valid cache for the same re-verified account and labels it offline. The bundled example is returned directly in memory and never enters CloudKit or this cache. Only its on/off Boolean is stored in UserDefaults. The Widget Extension does not fetch Mac data itself; the host app supplies title-free ActivityKit state.

### No-data behavior

If sync is not configured and example mode is off, the app deliberately displays an empty state and zero metrics. It never silently substitutes sample agents for a production fetch. App Review can deliberately enter the clearly labelled example mode using the visible control above; contact `[review contact email]` if that control is unavailable.

### Privacy and support

Privacy Policy: `[Privacy Policy URL]`
Support: `[Support URL]`

The App target's `Config/PrivacyInfo.xcprivacy` declares linked Other Usage Data and conditional Other User Content (the separately opted-in conversation-title field) for App Functionality, no tracking, and no tracking domains. It declares `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1` for the app-owned example-mode Boolean. The Widget Extension has its own `WidgetExtension/PrivacyInfo.xcprivacy`, declaring no collected data, no accessed API categories, no tracking, and no tracking domains; it has no iCloud entitlement. The final App Privacy answers in App Store Connect must match both declared data categories while optional full-title sync remains in the submitted build. This build has no APNs remote Live Activity update path.

### Independence

This is an independent product and is not affiliated with or endorsed by Apple or any AI/IDE provider. Token values are synchronized from locally available source records on the user's Mac and are not provider billing totals.

## 3. 中文对照稿

“MAC版灵动岛--Agent运行监测”的 iPhone 版是 Mac 应用的伴侣看板，展示由 Mac 生成的隐私化摘要：相关/运行中 Agent 数、活跃对话数、状态、工作时长、Token、工具名和隐私化对话占位。当前 Mac producer 会将 schema 的 `safeSummary` 留空，不会从 prompt 或回复推导任务摘要。

iPhone 不扫描、挂载或浏览 Mac 文件系统。同步模型没有 prompt、回复正文、API Key、进程 ID、Mac 文件路径或工作区路径字段。完整对话标题默认在 Mac 端排除；即使用户明确选择同步，iPhone 每次启动也会重新隐藏。Live Activity 永不包含对话标题。

应用没有独立应用账号、购买、订阅、广告、分析 SDK 或追踪。Mac 与 iPhone 必须登录同一 iCloud 账户，因为摘要存放在该用户的私有 CloudKit 数据库。Mac 私有同步默认关闭，只有用户阅读离机字段并明确开启后才上传；完整对话标题另需单独明确同意。

提交的 Release 构建同时提供明确、离线的审核示例模式。其中 Agent、对话、时长与 Token 都是随包提供的通用虚构数据，不含敏感信息；看板、锁屏和灵动岛都会显示示例标识。示例模式不访问 CloudKit、不写入同步缓存，也不能作为生产同步已验收的证据。

先使用无需账号、凭据、Mac、付费 AI 服务或网络的内置示例路径：

1. 启动 iPhone App。
2. 在同步状态卡片下方点击“使用示例数据体验”。
3. 阅读说明后点击“查看示例看板”。
4. 确认顶部显示“示例数据”，橙色卡片显示“示例模式 · 非真实数据”，来源行显示“内置样例 · 未同步”。
5. 检查看板和 Agent 卡片；所有名称和对话都是通用示例，完整对话标题不可用。
6. 点击“开启实时活动”，在锁屏与灵动岛确认对应尺寸出现“示例”文字、示例说明、紫色处理或试管图标。
7. 返回 App 点击“退出并重置示例模式”；应用会删除该布尔偏好、清除示例、结束示例实时活动，并立即恢复原有 CloudKit 刷新路径。

若还需单独审核真实同 iCloud 生产链路，请在签名/schema 清单通过后执行下列步骤：

核心审核步骤：

1. 在 Mac 的“设置 → iPhone · iCloud 私有同步”中开启私有同步，确认离机字段后点击“立即同步”；然后在 iPhone 下拉刷新，顶部状态应从“尚未配置 Mac 同步”变为最终连接/缓存状态。除非专门审核敏感字段同意，不开启标题同步。
2. 检查相关 Agent、运行中、活跃对话和 Token 汇总卡片。iPhone 保留 Mac producer 主动筛选纳入的全部工具；当前无会话/无用量的工具保留真实空闲或完成状态，不会被计为运行中。
3. 查看 Agent 卡片中的状态、工具、时长、Token 和最多三条隐私化对话条目。
4. 内置示例不含完整标题。真实 CloudKit 数据只有在 Mac 用户单独明确允许时才可包含标题；此时点击眼睛按钮显示，杀掉并重启 App 后应再次隐藏。
5. 有工作中 Agent 时点击“开启实时活动”；没有活跃 Agent 时按钮按设计禁用。
6. 查看锁屏 Live Activity；支持灵动岛的设备再检查紧凑、最小和展开形态。
7. 在示例模式点击“退出并重置示例模式”后，示例实时活动应立即结束；真实同步路径中，停止来源 Agent 并刷新后，活动应随新快照更新，并在没有活跃 Agent 时结束。
8. 在 Mac 关闭私有同步并确认删除；iPhone 下次刷新发现 `latest` 记录不存在时，应只清除当前 iCloud 账号缓存并回到空状态。

当前设计由 iPhone 主 App 启动、刷新和结束 Live Activity，ActivityKit 仅在 App 启动、回到前台或用户手动刷新时获得新状态，不使用 APNs 远程启动/更新。因此它不是持续后台监控。`[若最终加入 APNs，请按真实实现替换。]`

App 重启时会从 ActivityKit 读取系统中已存在的活动，恢复按钮的运行状态。活动内容设置两分钟 `staleDate`；超时后，锁屏和灵动岛使用本地化“过期”标签和橙色状态，直到主 App 更新或结束活动。

iPhone 只把最新的已验证生产摘要保存在按当前 iCloud 账号隔离的自身沙盒目录；目录键是 CloudKit 用户记录标识符的不可逆 SHA-256 摘要。负载最大 2 MB，并校验 Agent/对话数量、文本长度、时间戳和 Token 一致性。退出/切换账号不会回退到其他账号缓存；固定云记录缺失时仅清除当前账号缓存。内置示例只在内存中返回，不进入 CloudKit 或该缓存；本地只用 UserDefaults 保存一个示例模式开关。Widget Extension 不自行拉取 Mac 数据，由主 App 更新不含标题的 ActivityKit 状态。

未配置同步且示例模式关闭时，App 只显示空状态和零数据，不会暗中用示例替换生产刷新。审核人员可用顶部可见入口主动进入带明确标识的示例模式；若入口不可用，请联系 `[审核联系邮箱]`。

隐私政策：`[隐私政策URL]`
支持页面：`[支持URL]`

App 目标的 `Config/PrivacyInfo.xcprivacy` 已申报用于 App 功能的“其他使用数据”和条件性“其他用户内容”（单独选择同步的对话标题），两者均与用户关联、不用于追踪；并为应用自身的示例模式布尔开关申报 `NSPrivacyAccessedAPICategoryUserDefaults` 的 `CA92.1` 理由。App Store Connect 的 App Privacy 回答必须与这两类数据申报一致。Widget Extension 单独声明不收集数据、不使用必需原因 API、不追踪，且没有 iCloud entitlement。

## 4. TestFlight Beta App Review 补充

首个外部测试 Build 可能需要 Beta App Review。除上述信息外还应提供：

- Beta App Description 和 What to Test：见 `IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md`。
- Feedback Email：`[TestFlight反馈邮箱]`。
- 明确测试 Build 的同步后端/CloudKit 环境与生产环境是否不同。
- 如果服务有地区、账号或配额限制，给审核人员提供不会失效的路径。
- 如果只允许内部测试，说明尚未完成外部 Beta Review，不要创建公开链接。

## 5. 提交前清理

- 删除本节、顶部“不可提交”提示和所有方括号占位符。
- 按最终 UI 改写每一个菜单名和操作步骤，不允许审核员猜测。
- 正式签名/Production schema/同账号真机链路未验收时，不得把明确标识的内置示例或手工注入缓存冒充生产同步；示例模式只用于审核 UI 与交互。
- 用真实 Developer ID entitlement/profile、Production schema 和同账号 Mac→iPhone 真机链路完成从零验证，再把本模板写成最终 Review Notes；若再加入 HTTPS、APNs、后台任务、账号或崩溃报告，同样更新。
- 在同一审核 Build 上从零验证全部步骤，并在无 Dynamic Island 的设备验证锁屏形态。

## 6. Apple 官方参考

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)
- [Provide TestFlight test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)
- [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
