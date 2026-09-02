# Mac App Store 元数据草案

> 适用平台：macOS。iOS 平台已有独立工程，其文案见 `IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md`。以下 macOS 内容仅应在 App Sandbox 授权流程、正式签名、正式 CloudKit Container/schema、同账号 Mac→iPhone 真机验证和审核演示数据完成后使用；不得把“代码链路已实现”写成“生产同步已上线”。字段限制以提交时 App Store Connect 为准。

## 全局信息

| 字段 | 建议值 |
| --- | --- |
| App 名称 | MAC版灵动岛--Agent运行监测 |
| 平台 | macOS |
| 正式 Bundle ID | `[正式Bundle ID]`（必须替换当前 `local.agentisland.desktop`） |
| SKU | `[SKU]` |
| 主语言 | 简体中文（可按实际市场调整） |
| 主类别 | Developer Tools |
| 次类别 | Productivity |
| 价格 | `[免费或具体价格档位]` |
| 版权 | `[年份] [版权所有者]` |
| 内容版权 | 不含需要额外授权的第三方内容；提交前复核 `THIRD_PARTY_NOTICES.md` |
| 隐私政策 URL | `[隐私政策URL]`（macOS 必填，必须公开可访问） |
| 支持 URL | `[支持URL]`（必须包含真实联系方式） |
| 营销 URL | `[营销URL，可选]` |
| 版本号 | `[实际提交版本，例如 1.0.0]` |
| 最低系统 | macOS 13.0（与当前 `Info.plist` 一致） |

## 简体中文（zh-Hans）

### 名称（最多 30 个字符）

MAC版灵动岛--Agent运行监测

### 副标题（最多 30 个字符）

本地 AI Agent 监控工作台

### 推广文本（最多 170 个字符）

在 Mac 顶部快速查看正在工作的 AI Agent、活跃会话、运行时长与本机可读 Token 用量，并随手使用网站快捷入口、备忘录和自配服务的翻译学习器。

### 描述（最多 4,000 个字符）

MAC版灵动岛--Agent运行监测 是一个位于 Mac 屏幕顶部的本地 AI Agent 观测与快捷工作台。鼠标悬停即可展开，移出后自动收回；需要持续操作时，也可以点击固定面板。

实时掌握正在发生的工作
• 查看本机发现的 Agent 工具、IDE 宿主与扩展
• 聚焦正在运行的 Agent 和活跃对话
• 展示任务标题、状态、模型、工作时长与可验证的 Token 用量
• 查询本机仍可读取的历史会话，并按工具或会话搜索

轻量工作台
• 保存并快速打开常用 HTTPS 网站
• 创建、搜索和整理本地备忘录
• 主动提交中英文文本，获得翻译、一句话定义和结构拆解
• 将有用的翻译结果保存到本地学习本

本地优先
Agent 日志解析、Token 聚合、网站清单、备忘录和学习条目均在当前 Mac 上处理和保存。本应用不包含广告、追踪或分析 SDK，也不会把 Agent prompt、回复正文或项目文件上传给开发者。翻译功能仅在你点击提交后，才会把当前文本发送到你在设置中确认的 OpenAI-compatible 服务。

可选的 iPhone 私有同步默认关闭。只有在你阅读离机字段说明并明确开启后，Mac 才会将 Agent/工具类别、状态、时长和 Token 精简快照写入你 Apple ID 的 CloudKit 私有数据库。对话标题默认不发送，需要单独确认；关闭同步会停止上传并删除云端 `latest` 快照。

Token 数字来自本机仍可读取的结构化日志，可能因工具、日志保留期限和数据质量而不完整，也不代表服务商账单。并非所有已安装工具都会提供会话或 Token 遥测。

需要 macOS 13.0 或更高版本。部分监控功能要求相关 AI 工具已经在本机生成受支持的日志，并需要你授权本应用读取相应目录。

### 关键词（不超过 100 字节；提交前在 App Store Connect 复核）

智能体,用量统计,开发工具,本地看板,效率工具,备忘录,翻译学习

### 此版本的新功能

• 优化网站快捷入口的自适应卡片排版
• 新增本机可读的历史 Token 汇总、工具分布和会话搜索
• 改进 Agent 会话标题、状态与来源展示
• 支持中英文界面及翻译学习工作流

## English (U.S.)

### Name (30 characters maximum)

MAC版灵动岛--Agent运行监测

### Subtitle (30 characters maximum)

Local AI Agent Dashboard

### Promotional text (170 characters maximum)

See active AI agents, conversations, runtime, and locally available token usage from the top of your Mac, with notes, quick links, and translation tools.

### Description (4,000 characters maximum)

MAC版灵动岛--Agent运行监测 is a local AI-agent dashboard and compact workspace at the top of your Mac. Hover to reveal the panel and move away to collapse it, or click to keep it open for interaction.

See what is working now
• Discover supported AI tools, IDE hosts, and extensions on your Mac
• Focus on running agents and active conversations
• View task titles, status, model, active time, and verifiable token usage
• Search locally available usage history by tool or conversation

A compact workspace
• Save and open frequently used HTTPS websites
• Create, search, and organize local notes
• Submit Chinese or English text for translation, a one-sentence definition, and a learning breakdown
• Save useful translation results to an on-device study list

Local first
Agent log parsing, token aggregation, website shortcuts, notes, and study entries are processed and stored on the current Mac. The app contains no ads, tracking, or analytics SDK and does not upload agent prompts, response bodies, or project files to the developer. Translation text is sent only after you submit it to the OpenAI-compatible service confirmed in Settings.

Optional private iPhone sync is off by default. Only after you review the off-device fields and expressly enable it does the Mac write a reduced snapshot—agent/tool category, state, duration, and token totals—to your Apple ID's private CloudKit database. Conversation titles are excluded by default and require separate confirmation. Turning sync off stops uploads and deletes the cloud `latest` snapshot.

Token figures come from structured logs still available on the Mac. They may be incomplete because of tool support, log retention, or source quality, and they are not provider billing totals. An installed tool does not necessarily expose conversation or token telemetry.

Requires macOS 13.0 or later. Some monitoring features require supported logs produced by the relevant AI tool and your authorization for the app to read their locations.

### Keywords (100 bytes maximum; recheck in App Store Connect)

AI agent,token usage,developer tools,local dashboard,productivity,notes,translator

### What's New

• Refined the responsive layout for website shortcuts
• Added locally available historical token totals, tool breakdowns, and conversation search
• Improved agent task titles, status, and source attribution
• Added Chinese and English UI support and a translation-learning workflow

## 截图建议

截图必须来自最终签名的提交构建，不得使用竞品界面、竞品 Logo 或无法在应用内复现的数据。项目中现有截图可作为构图参考，但提交前应重新截取无个人路径、真实姓名、密钥、项目名或敏感会话标题的商店图。

建议顺序：

1. 实时监控：正在工作的 Agent、活跃对话、时长和 Token。
2. 用量历史：总量、分类、工具占比和可搜索记录。
3. 工具发现：已安装、宿主运行、会话活动与遥测可用性。
4. 工作台：网站快捷入口与备忘录。
5. 翻译学习：输入、翻译、一句话定义和拆解。
6. 隐私与数据源：本地优先说明、隐私遮罩和用户授权的数据源。

每张截图建议添加一句不遮挡 UI 的短文案，并同时制作中英文版本。在完成正式签名、Production schema 和同账号真机验证前，macOS 截图不要展示或宣称可用的云同步；iPhone 看板与灵动岛素材应单独用于 iOS 平台，并且只能来自通过生产配置验收的最终 iOS 构建。

## 年龄分级与其他问卷建议

以下只是对当前功能的初步判断，必须按 App Store Connect 当时的完整问卷逐项作答：

- 非 Made for Kids。
- 无广告、赌博、购买、社交发布、用户公开内容或健康医疗功能。
- 网站快捷入口交给系统默认浏览器，应用本身不提供内嵌无限制网页浏览；根据当时问卷措辞确认 “Unrestricted Web Access”。
- 翻译结果由用户选择的模型服务生成，不在应用内公开分享。若 Apple 问卷单列 AI 生成内容或内容控制，应如实选择并说明。
- 无账号、无登录、无订阅、无 App 内购买。

## 提交前文案检查

- 不使用“官方”“精确账单”“支持所有 Agent”等无法证明的描述。
- 不把会话生命周期累计值描述为每日消耗。
- 不暗示与 Apple、OpenAI、Anthropic、DeepSeek、Microsoft 或其他工具厂商存在隶属或背书关系。
- 商店文案与提交构建的权限、数据源、默认翻译端点及隐私标签保持一致。
- 删除所有方括号占位符，并确认中英文链接均有效。
