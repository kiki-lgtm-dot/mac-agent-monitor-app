# Mac App Store 元数据（已保存值与待补字段）

> 适用平台：macOS。iOS 文案见 `IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md`。下文的名称、副标题、推广文本、描述、关键词、类别、URL、版本号与手动发布方式均已保存到 App Store Connect。尚未完成的范围只包括截图、法律/版权信息、联系人、DSA、价格/地区、Content Rights、年龄分级、Build、App Privacy 问卷和审核；不得把已保存元数据写成构建已上传或审核已提交。

## 全局信息

| 字段 | App Store Connect 当前值 |
| --- | --- |
| App 名称 | MAC版灵动岛--Agent运行监测 |
| 平台 | macOS |
| App Store 记录模式 | Universal Purchase（与 iOS 共用记录） |
| App Store Connect App ID | `6808917414` |
| 正式 Bundle ID | `com.kiki.agentisland` |
| Team ID | `AW4HMBZN7M` |
| SKU | `AGENTISLAND-UNIVERSAL` |
| 主语言 | 简体中文 |
| 主类别 | Developer Tools |
| 次类别 | Productivity |
| 价格 | `[免费或具体价格档位]` |
| 上架国家/地区 | `[最终可用范围]` |
| 版权 | `[年份] [版权所有者]` |
| 内容权利（Content Rights） | `[核实工具名、用户数据及商店素材权利后选择]` |
| DSA 交易者状态 | `[由 Account Holder 确认 trader / non-trader]` |
| 年龄分级 | `[根据最终构建完成问卷]` |
| 联系人 | `[支持与审核联系信息]` |
| App Privacy 问卷 | `[以最终 Build 和数据处理证据填写并发布]` |
| 隐私政策 URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/` |
| 隐私选择 URL（简体中文） | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/#delete-data` |
| Privacy Choices URL（English U.S.） | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/#delete-data-en` |
| 支持 URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/` |
| 营销 URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/` |
| 版本号 | App Store 版本 `0.6.1`；工程当前 Build `8`，尚未上传 |
| 版本发布方式 | 审核通过后手动发布（Manual） |
| 最低系统 | macOS 13.0（与当前 `Info.plist` 一致） |
| CloudKit | `iCloud.com.kiki.agentisland`；Private / Production / `AgentIslandSnapshot` / `latest` / `payloadJSON` |

Production schema 已部署。公共数据库的兜底权限仅 `_icloud` CREATE、`_creator` READ + WRITE，没有 `_world` READ；产品代码仍只应使用用户私有数据库。Mac App Store profile 已生成并存放于 Git 忽略的本地发布目录，但尚未绑定最终 Archive 验证。

## 简体中文（zh-Hans）

### 名称（最多 30 个字符）

MAC版灵动岛--Agent运行监测

### 副标题（最多 30 个字符）

Mac AI Agent 运行看板

### 推广文本（最多 170 个字符）

在 Mac 菜单栏和灵动岛风格面板中，查看本地 AI Agent 的运行状态、活跃对话、工作时长与可验证 Token 摘要。

### 描述（最多 4,000 个字符）

MAC版灵动岛--Agent运行监测是一款隐私优先的 macOS 本地工作看板。它展示相关 Agent、活跃对话、工作时长与来自可验证本地来源的 Token 摘要，并提供常用网站、备忘录和可选翻译学习工具。本地 Agent 数据不等于服务商账单，翻译内容只在用户明确发送时离开设备。

### 关键词（不超过 100 字节；提交前在 App Store Connect 复核）

智能体,Token,本地监测,灵动岛,工作看板,开发工具

## English (U.S.)

### Name (30 characters maximum)

MAC版灵动岛--Agent运行监测

### Subtitle (30 characters maximum)

AI Agent Monitor for Mac

### Promotional text (170 characters maximum)

See local AI-agent status, active conversations, working time, and verifiable token summaries in a focused Mac panel.

### Description (4,000 characters maximum)

MAC版灵动岛--Agent运行监测 is a privacy-first local workspace for macOS. It presents relevant agents, active conversations, working time, and token summaries from verifiable local sources, alongside bookmarks, notes, and an optional translation-learning tool. Local token totals are not provider billing totals. Translation text leaves the device only when the user explicitly sends it.

### Keywords (100 bytes maximum; recheck in App Store Connect)

AI agents,token usage,local monitor,productivity,developer tools

## 截图建议

截图必须来自最终签名的提交构建，不得使用竞品界面、竞品 Logo 或无法在应用内复现的数据。项目中现有截图可作为构图参考，但提交前应重新截取。可使用应用内置且全程明示“离线示例”的虚构 Agent 数据；若使用真实数据，必须移除个人路径、真实姓名、密钥、项目名或敏感会话标题。

建议顺序：

1. 实时监控：正在工作的 Agent、活跃对话、时长和 Token。
2. 用量历史：总量、分类、工具占比和可搜索记录。
3. 工具发现：已安装、宿主运行、会话活动与遥测可用性。
4. 工作台：网站快捷入口与备忘录。
5. 翻译学习：输入、翻译、一句话定义和拆解。
6. 隐私与数据源：本地优先说明、隐私遮罩和用户授权的数据源。

每张截图建议添加一句不遮挡 UI 的短文案，并同时制作中英文版本。Production schema 已部署，但在最终签名构建和同账号真机同步验收前，macOS 截图不要展示或宣称可用的云同步；iPhone 看板与灵动岛素材应单独用于 iOS 平台，并且只能来自通过生产配置验收的最终 iOS 构建。

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
- 只补齐尚未完成的截图、法律/版权信息、联系人、DSA、价格/地区、Content Rights、年龄分级、Build、App Privacy 问卷和审核；已保存的 URL、Bundle ID、SKU、版本和发布方式不得改回占位值。
