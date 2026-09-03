# App Review Notes 草案

> 这份文件用于准备 Mac App Store 的 Review Notes。以英文版本为主要提交文本。内置离线监测示例与 App Sandbox 主目录授权路径已经实现；正式 Apple 身份、签名 Archive、CloudKit Production 配置、翻译审核凭据和真实构建验证仍未完成，因此暂不可原样提交。

## 上线前必须补齐的审核资源

- `[审核联系人姓名]`
- `[审核联系电话]`
- `[审核联系邮箱]`
- 翻译功能二选一：
  - `[审核专用 HTTPS 端点、模型和临时 API Key]`；或
  - 在提交构建中提供无需外部凭据、明确标记且不联网的演示模式。
- 确认提交构建中的系统选择器可授权当前用户主目录，并在该目录中只读扫描受支持工具的已知日志位置。

临时 API Key 只能填写在 App Store Connect 的私密 Review Information 中，不得写进仓库、应用包、截图或公开支持页面；审核结束后应撤销。

## English submission draft

MAC版灵动岛--Agent运行监测 is a menu-bar/accessory macOS app. It has no Dock icon. On the first GUI launch, it displays a native Local Agent Data Access notice before any Agent-log scan or periodic refresh starts. The reviewer may choose Allow Read-Only Monitoring to continue or Not Now to leave monitoring stopped. A compact panel appears centered at the top of the active display. Hover over the top camera/notch area for approximately 150 ms to expand it. Moving the pointer away collapses it; clicking the panel pins it for interaction. The status-bar menu can also show the panel, move it to the display under the pointer, review the data-access notice, check the configured HTTPS support/download page, refresh data, or quit the app.

No separate app account, purchase, or subscription is required. A separate iOS companion target and Live Activity extension exist in the repository and are not embedded in this macOS binary. The Mac app includes optional private CloudKit sync for that companion. Sync is off by default and requires an explicit disclosure and opt-in; the local monitoring and workspace features can be reviewed without enabling it. This Review Notes draft must be used only after the submitted Mac build has the actual CloudKit entitlement/profile and the matching production container/schema and same-iCloud-account device flow have been verified.

### Built-in offline example — no account, logs, permission, credential, or network required

1. Launch MAC版灵动岛--Agent运行监测. On the first Local Agent Data Access notice, choose **Not Now**. No Agent-log scan or refresh timer starts. Use the status-bar item → **Show Panel** if needed.
2. Open **Settings → Offline example mode**, select **Explore built-in example**, and confirm. The same action is also available in the status-bar menu. Private iCloud sync must be off and any prior read, translation, or cloud operation must have finished before entry.
3. Return to **Monitor**. A persistent purple banner says **Agent monitoring is an offline example · no local Agent logs, network, or iCloud**. The compact pill uses the same purple example state. Live, Usage history, tool, conversation, duration, and Token views show generic fictional bundle data; none of it represents the review Mac or an AI-provider account. Workspace notes, shortcuts, and study entries remain ordinary on-device user content and are not represented as sample data.
4. Relaunch the App if desired. Only one local Boolean keeps the explicit example state; the sample itself is rebuilt in memory and remains visibly labelled. While it is enabled, GUI-native gates reject Agent-log/source access, hide prior Home-folder/custom-source state, prevent the review notice from starting monitoring, serialize any operation already finishing before entry, and reject translation/external-link network and CloudKit account/upload/delete actions.
5. In Settings, select **Exit & reset example**. The Boolean and sample are removed. Local monitoring stays off and does not restart until the reviewer explicitly enables it.

### How to review real local monitoring and the remaining features

1. After exiting the example, open **Settings → Local Data Access**, review the notice, and enable read-only monitoring. In the Mac App Store build, use the system picker to authorize the current user's Home folder. The app scans only known supported log locations and explicitly connected sources inside that authorization.
2. Open Monitor. If supported local Agent logs are present, Live shows active sessions and Usage History shows locally readable session-lifetime Token totals. Stop monitoring and confirm periodic reads stop and the current snapshot clears; turn it back on explicitly to continue.
3. The tool cards distinguish installation, host-process activity, verified Agent-session activity, and Token telemetry. A running IDE is not represented as an active Agent unless session evidence exists.
4. Open Workspace to add a website shortcut and a note. Website links are opened by the default browser only after the user clicks Open. Workspace data remains on the Mac.
5. Open Translate & Learn. Configure the review endpoint and temporary credential supplied in Review Information, enter a short sentence, and select Translate only or Analyze for learning. No network request occurs until this button is selected. Before the first send to that destination, the App presents a separate off-device transfer dialog. The default DeepSeek destination receives a provider-specific disclosure and official-policy links; a custom review endpoint receives the generic third-party notice.
6. Open Settings to switch Chinese/English, enable the privacy mask, inspect data-source diagnostics, refresh, or quit.

### Local data access

The monitoring feature reads supported local AI-agent logs and metadata only after the first-run notice is accepted. Access is read-only. It extracts state, duration, Token counts, and titles explicitly supplied by a source; it does not extract, display, or store prompt or response bodies, and those bodies are excluded from iPhone/iCloud sync. The app does not modify or delete third-party logs. Custom sources can be removed, and all monitoring can be stopped, from Settings. The app does not request Camera, Microphone, Screen Recording, or Accessibility access. The Mac App Store build requires the user to select and authorize the current user's Home folder through the system picker; it then scans only supported tools' known log locations and explicitly connected custom sources inside that folder.

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

1. 首次启动看到“本机 Agent 数据访问”说明时选择“暂不开始”；此时不会扫描日志或启动刷新定时器。必要时从状态栏菜单选择“显示面板”。
2. 打开“设置 → 离线示例模式”，点击“查看内置示例”并确认；状态栏菜单也有同一入口。进入前需关闭私有同步并等待已有读取、翻译或云端操作结束。
3. 回到“监控”。紫色常驻横幅和紧凑胶囊都会明确显示“Agent 监测为离线示例”；实时、历史、工具、对话、时长和 Token 都来自 App 内置的通用虚构数据，不代表审核电脑或任何账号。工作台中的备忘录、网站和学习条目仍是普通的本机用户内容，不属于示例数据。
4. 可退出并重启验证：本机只保存一个明确的示例模式布尔值，示例本身每次在内存重建且持续标记。示例开启时，GUI 原生层拒绝 Agent 日志/数据源，隐藏既有主目录/自定义源状态，不允许“重新查看说明”启动真实监测，并拒绝翻译/外链网络和 CloudKit 账号/上传/删除操作。
5. 在设置中点击“退出并重置示例”。示例值和数据会被移除，本机监测保持关闭，只有再次明确开启后才恢复。
6. 如要审核真实监测，退出示例后在“设置 → 本机数据访问”确认说明并开启；Mac App Store 版通过系统选择器授权当前用户主目录。若存在受支持日志，“实时”显示活跃会话，“用量历史”显示本机可读的会话生命周期累计 Token。
7. “工具”卡片分别展示安装、宿主运行、可验证会话活动和 Token 遥测，不会仅凭 IDE 运行就声称 Agent 正在工作。“工作台”可测试网站快捷入口和备忘录。
8. “翻译学习”需填写 Review Information 中提供的审核端点和临时密钥；只有点击“仅翻译”或“学习解析”后才联网，首次发送前显示独立离机传输同意框。
9. “设置”可切换中英文、隐私遮罩、查看数据源诊断、刷新或退出。

Mac App Store 构建启用 App Sandbox，并让用户通过系统选择器明确授权当前用户主目录；应用随后只扫描受支持工具的已知日志位置和该授权范围内由用户显式连接的自定义来源。读取为只读，不修改或删除第三方日志。

本机监测在用户首次确认后才开始，可在设置中停止/恢复，并可移除自定义数据源。应用会在本机处理工具是否安装或运行、会话标题、Agent/工具/服务名称、模型名、项目路径、状态、时间戳、工作时长、Token 计数和来源归因信息；不提取、展示或保存 prompt/响应正文，也不请求摄像头、麦克风、屏幕录制或辅助功能权限。周期性监控和工作台存储在本机进行。应用没有分析、广告、追踪、崩溃报告 SDK、开发者后端或独立账号系统。私有同步默认关闭；用户明确开启后，Mac 才把 Agent/工具类别、状态、时长和 Token 精简快照写入其 iCloud 私有数据库。Prompt、任务摘要、项目/文件路径、模型、API Key、备忘录和翻译内容不会上传；对话标题默认不发送，需二次明确确认。关闭同步会停止上传并请求删除云端 `latest` 记录。可选翻译器仅向设置中显示的 OpenAI-compatible 端点发送用户主动提交的内容，API Key 保存在 macOS Keychain，开发者不会收到请求。首次向每个目的地发送前必须接受独立说明；如保留默认 DeepSeek，说明会列明其公开政策中的中国处理/存储、可能训练/优化、固定 API 保留期与不训练承诺未公开，并链接官方政策。

## 提交前删除的内容

- 删除本节及所有编写提示。
- 替换全部方括号占位符。
- 如果未完成沙盒授权，不得声称已经启用 App Sandbox，也不得提交当前 ad-hoc 二进制。
- 内置示例只覆盖监测看板；如果保留联网翻译功能，仍须提供可用的审核端点和临时凭据，或另加不联网的翻译示例，不能要求审核人员购买 API 额度。
- 确保 Review Notes、隐私政策、App Privacy 标签和最终构建的实际网络行为完全一致。
