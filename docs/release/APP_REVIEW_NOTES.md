# App Review Notes 草案

> 这份文件用于准备 Mac App Store 的 Review Notes。以英文版本为主要提交文本。当前未完成 App Sandbox 数据源授权和审核演示数据，因此暂不可原样提交。

## 上线前必须补齐的审核资源

- `[审核联系人姓名]`
- `[审核联系电话]`
- `[审核联系邮箱]`
- `[无敏感信息的自定义 JSONL 测试文件或审核附件说明]`
- 翻译功能二选一：
  - `[审核专用 HTTPS 端点、模型和临时 API Key]`；或
  - 在提交构建中提供无需外部凭据、明确标记且不联网的演示模式。
- `[沙盒版中选择并授权日志目录的准确操作步骤]`

临时 API Key 只能填写在 App Store Connect 的私密 Review Information 中，不得写进仓库、应用包、截图或公开支持页面；审核结束后应撤销。

## English submission draft

MAC版灵动岛--Agent运行监测 is a menu-bar/accessory macOS app. It has no Dock icon. On the first GUI launch, it displays a native Local Agent Data Access notice before any Agent-log scan or periodic refresh starts. The reviewer may choose Allow Read-Only Monitoring to continue or Not Now to leave monitoring stopped. A compact panel appears centered at the top of the active display. Hover over the top camera/notch area for approximately 150 ms to expand it. Moving the pointer away collapses it; clicking the panel pins it for interaction. The status-bar menu can also show the panel, move it to the display under the pointer, review the data-access notice, check the configured HTTPS support/download page, refresh data, or quit the app.

No separate app account, purchase, or subscription is required. A separate iOS companion target and Live Activity extension exist in the repository and are not embedded in this macOS binary. The Mac app includes optional private CloudKit sync for that companion. Sync is off by default and requires an explicit disclosure and opt-in; the local monitoring and workspace features can be reviewed without enabling it. This Review Notes draft must be used only after the submitted Mac build has the actual CloudKit entitlement/profile and the matching production container/schema and same-iCloud-account device flow have been verified.

### How to review the core features

1. Launch MAC版灵动岛--Agent运行监测. Review the native data-access notice, then choose “Allow Read-Only Monitoring.” No Agent-log scan or refresh timer starts before this confirmation. Use the status-bar icon to choose “Show Panel” if the panel is not already visible.
2. Open Monitor. If supported local agent logs are present in an authorized folder, the Live view shows active sessions and the Usage History view shows locally readable session-lifetime token totals. In Settings → Local Data Access, stop monitoring and confirm that periodic reads stop and the current monitoring snapshot clears; turn it back on to continue. The notice remains available from Settings and the status-bar menu.
3. To review without existing Codex or Claude Code data, open Data Sources, select the custom JSONL option, and choose the review fixture described here: `[exact fixture attachment and steps]`.
4. The Tools view distinguishes installation, host-process activity, verified agent-session activity, and token telemetry. A running IDE is not represented as an active agent unless session evidence exists.
5. Open Workspace to add a website shortcut and a note. Website links are opened by the default browser only after the user clicks Open. Workspace data remains on the Mac.
6. Open Translate & Learn. Configure the review endpoint and temporary credential supplied in Review Information, enter a short sentence, and select Translate only or Analyze for learning. No network request occurs until this button is selected. Before the first send to that destination, the App presents a separate off-device transfer dialog. The default DeepSeek destination receives a provider-specific disclosure and official-policy links; a custom review endpoint receives the generic third-party notice.
7. Open Settings to switch Chinese/English, enable the privacy mask, inspect data-source diagnostics, refresh, or quit.

### Local data access

The monitoring feature reads supported local AI-agent logs and metadata only after the first-run notice is accepted. Access is read-only. It extracts state, duration, Token counts, and titles explicitly supplied by a source; it does not extract, display, or store prompt or response bodies, and those bodies are excluded from iPhone/iCloud sync. The app does not modify or delete third-party logs. Custom sources can be removed, and all monitoring can be stopped, from Settings. The app does not request Camera, Microphone, Screen Recording, or Accessibility access. The Mac App Store build additionally requires the user to select and authorize each external log directory through App Sandbox. `[Replace the sandbox sentence if the final implementation differs.]`

Supported source formats currently include local Codex SQLite/JSONL, local Claude Code JSONL, and user-selected custom JSONL. Token values are reported only when a source supplies verifiable usage. Historical figures are session-lifetime totals from logs still readable on the Mac, not provider billing totals or fabricated daily usage.

### Network and privacy

Periodic monitoring and workspace storage are local. The app has no analytics, advertising, tracking, crash-reporting SDK, developer backend, or separate account system. With private sync off—the default—monitoring data is not sent to CloudKit.

If the user enables private sync after reviewing the confirmation, the Mac writes one reduced snapshot to the signed-in user's private CloudKit database. It includes agent/tool category, state, duration, and token totals. It excludes prompts, task summaries, project/file paths, model names, API keys, notes, and translation content. Conversation titles are excluded by default and require a second explicit confirmation. Normal refresh uploads are throttled; the user may select “Sync now.” Turning sync off stops uploads and requests deletion of the fixed `latest` cloud record. There is no developer-operated sync server.

The optional translator makes one user-initiated request to the OpenAI-compatible endpoint visible in Settings. It sends the submitted text, language/mode fields, selected model, structured-output instructions, and the API key for that endpoint. API keys are stored in macOS Keychain. The ephemeral session uses no cookies or URL cache, allows only same-origin redirects, and limits response size. The developer does not receive these requests. Before the first send to each destination, the user must accept a separate disclosure. If the default DeepSeek endpoint is retained, that dialog explains the publicly documented processing/storage in China, possible model training or service improvement, and the lack of a published fixed API-request retention period or no-training commitment, with links to DeepSeek's official policy and Open Platform terms.

The Privacy Policy is available at `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/`. Support is available at `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/`.

### Non-obvious UI behavior

- MAC版灵动岛--Agent运行监测 uses accessory-app behavior (`LSUIElement`) and intentionally has no Dock icon.
- The first GUI launch remains in a no-scan state until the reviewer accepts the Local Agent Data Access notice. Declining is a supported state; the notice can be reopened later.
- Hover temporarily expands without stealing focus; click pins the panel so text fields and buttons can be used.
- The app refreshes local data periodically only while monitoring is enabled. This is read-only and does not continue as a separate process after the user stops monitoring or quits.
- “Check for Updates” opens only the release-configured HTTPS support/download page in the default browser. This build has no background downloader or automatic installer; a missing URL produces a visible explanation.
- Some tools can be discovered as installed or running but show no session or token data because those tools do not expose supported telemetry.

### Third-party attribution

The app is an independent implementation. It is not affiliated with or endorsed by Apple or any AI/IDE provider. Required open-source attribution is included in `THIRD_PARTY_NOTICES.md` inside the app bundle.

## 中文对照稿

MAC版灵动岛--Agent运行监测 是状态栏/辅助型 macOS 应用，不显示 Dock 图标。首次 GUI 启动会在任何 Agent 日志扫描或刷新定时器开始前显示原生“本机 Agent 数据访问”说明；选择“暂不开始”会保持停止。面板位于当前显示器顶部中央。将鼠标悬停在摄像头/刘海区域约 150 毫秒会展开，移出后收回；点击可固定以便交互。也可通过状态栏菜单显示面板、移动到鼠标所在显示器、重新查看数据访问说明、打开 HTTPS 支持/下载页、刷新或退出。

此 macOS 提交无需独立应用账号、购买或订阅。仓库另有独立 iOS 伴侣 Target 和 Live Activity Extension，它们不会嵌入此 macOS 二进制。Mac 应用包含为伴侣端提供的可选 CloudKit 私有同步：默认关闭，经离机字段说明和明确同意后才开启，本机监控和工作台无需开启同步即可审核。只有提交构建的真实 CloudKit entitlement/profile、匹配的生产 Container/schema 和同 iCloud 账号真机链路全部验证后，才可使用本审核稿。

审核步骤：

1. 启动后先查看原生数据访问说明，选择“允许只读监测”。确认前不会扫描 Agent 日志或启动周期刷新。如未看到面板，从状态栏菜单选择“显示面板”。
2. 打开“监控”。若获授权的目录中存在受支持日志，“实时”显示活跃会话，“用量历史”显示本机可读的会话生命周期累计 Token。
3. 如审核机器没有 Codex 或 Claude Code 数据，在“数据源”中选择自定义 JSONL，并打开审核附件：`[准确的测试文件和操作步骤]`。
4. “工具”页分别展示安装、宿主运行、可验证会话活动和 Token 遥测，不会仅凭 IDE 运行就声称 Agent 正在工作。
5. “工作台”可测试网站快捷入口和备忘录；网站只在点击后交给默认浏览器，本地内容留在 Mac。
6. “翻译学习”需填写 Review Information 中提供的审核端点和临时密钥；只有点击“仅翻译”或“学习解析”后才联网。首次向该目的地发送前会显示独立离机传输同意框；默认 DeepSeek 使用供应商专项说明和官方政策链接，自定义审核端点显示通用第三方风险说明。
7. “设置”可切换中英文、隐私遮罩、查看数据源诊断、刷新或退出。

Mac App Store 构建必须启用 App Sandbox，并让用户明确选择和授权每个外部日志目录。读取为只读，不修改或删除第三方日志。`[若最终实现不同，请改写本段。]`

本机监测在用户首次确认后才开始，可在设置中停止/恢复，并可移除自定义数据源。应用会在本机处理工具是否安装或运行、会话标题、Agent/工具/服务名称、模型名、项目路径、状态、时间戳、工作时长、Token 计数和来源归因信息；不提取、展示或保存 prompt/响应正文，也不请求摄像头、麦克风、屏幕录制或辅助功能权限。周期性监控和工作台存储在本机进行。应用没有分析、广告、追踪、崩溃报告 SDK、开发者后端或独立账号系统。私有同步默认关闭；用户明确开启后，Mac 才把 Agent/工具类别、状态、时长和 Token 精简快照写入其 iCloud 私有数据库。Prompt、任务摘要、项目/文件路径、模型、API Key、备忘录和翻译内容不会上传；对话标题默认不发送，需二次明确确认。关闭同步会停止上传并请求删除云端 `latest` 记录。可选翻译器仅向设置中显示的 OpenAI-compatible 端点发送用户主动提交的内容，API Key 保存在 macOS Keychain，开发者不会收到请求。首次向每个目的地发送前必须接受独立说明；如保留默认 DeepSeek，说明会列明其公开政策中的中国处理/存储、可能训练/优化、固定 API 保留期与不训练承诺未公开，并链接官方政策。

## 提交前删除的内容

- 删除本节及所有编写提示。
- 替换全部方括号占位符。
- 如果未完成沙盒授权，不得声称已经启用 App Sandbox，也不得提交当前 ad-hoc 二进制。
- 如果未提供测试 JSONL 或翻译审核凭据，应先加入可审核的演示路径，不能让审核人员自行安装第三方开发工具或购买 API 额度。
- 确保 Review Notes、隐私政策、App Privacy 标签和最终构建的实际网络行为完全一致。
