# 数据处理清单与 App Privacy 标签建议

> 审计基线：MAC版灵动岛--Agent运行监测 0.6.1（Build 8），2026-09-01。此文件是工程与提交准备材料，不是法律意见。最终答案必须以实际提交构建、最终翻译端点条款和 App Store Connect 当时的问卷为准。

## 1. 当前数据流总览

```text
本机应用/进程/扩展元数据 ─┐
Codex / Claude 本地日志 ───┼─[首次 GUI 启动明确同意]─> 本机只读解析 ─> 内存快照 ─> WKWebView 看板
用户选择的自定义 JSONL ───┘                          └─[可随时停止]

网站、备忘录、学习条目 ─────> 本机 workspace.json
语言、端点、模型、用量汇总 ──> 本机偏好设置
翻译 API Key ──────────────> macOS Keychain

用户输入文本 ──[仅点击提交]──> 用户确认的 OpenAI-compatible 端点
                                      └─> 结构化结果返回应用

可选 iPhone 伴侣（代码链路已实现，生产验收未完成）：
Mac 隐私化快照 ─[默认关闭；显式同意]─> Mac CloudKit producer
                                      ↓
用户私有 CloudKit 固定记录 ─> iPhone CloudKitSnapshotProvider
                                      ↓
按 iCloud 账号隔离的 iPhone 沙盒缓存 ─> SwiftUI 看板
                                      └─> ActivityKit
                                           （仅 App 启动/回前台/手动刷新时更新）

当前不存在：开发者后端、独立应用账号、分析、广告、追踪、崩溃上报、APNs 后台 Live Activity 远程更新
```

## 2. 逐项数据清单

| 数据或权限 | 来源 | 处理目的 | 保存位置 | 是否离开设备 | 保留/删除 | 当前事实 |
| --- | --- | --- | --- | --- | --- | --- |
| 本机监测同意与开关 | 用户在首次原生说明和设置页中选择 | 决定是否允许 Agent 日志周期只读扫描 | macOS UserDefaults（同意版本 + 启用状态） | 否 | 停止后取消刷新定时器并清除界面快照；重新开启需有效同意 | 首次确认前不创建刷新定时器，所有 GUI 快照读取均有原生门控 |
| 已安装应用、运行中进程、IDE/Agent 扩展 | macOS 与本机应用目录 | 工具发现和运行状态 | 内存快照 | 否 | 刷新时重建 | 只读检查，不把“宿主运行”冒充为 Agent 活跃 |
| 会话标题、Agent 名、模型名、项目路径 | Codex/Claude/自定义日志 | 会话展示、搜索和来源归因 | 主要在内存；原始日志由来源工具保存 | 原始值不离开 Mac；用户单独同意后仅经过滤标题可进入下方快照 | 随来源日志和进程生命周期 | 可能包含敏感名称或路径；有隐私遮罩 |
| 状态、时间戳、时长、Token 用量 | 本地结构化日志 | 实时监控和历史汇总 | 内存；翻译器自身用量另存偏好设置 | 原始日志不离开 Mac；开启同步后精简派生值见下方快照 | 来源日志被清理后可能减少 | 历史是本机可读的会话生命周期累计，不是账单 |
| 自定义数据源路径和显示名 | 用户主动添加 | 后续刷新数据源 | 本机偏好设置 | 否 | 用户移除连接 | 移除连接不删除原文件 |
| 自定义 JSONL 内容 | 用户授权的文件/目录 | 自定义 Agent 监控 | 只读解析到内存 | 否 | 原文件由用户管理 | 有扩展名、路径、文件数和大小限制 |
| 网站名称与 URL | 用户输入 | 快捷入口 | `workspace.json` | 仅点击打开时由默认浏览器处理 URL | 用户在应用内删除 | 应用不预抓取网页内容 |
| 备忘录正文 | 用户输入 | 本地备忘 | `workspace.json` | 否 | 用户在应用内删除 | 无云同步 |
| 学习本原文和翻译结果 | 用户点击保存 | 复习与学习 | `workspace.json` | 保存本身不联网 | 用户在应用内删除 | 只有点击“存入学习本”才落盘 |
| 界面语言 | 用户选择/系统语言 | 本地化 | 本机偏好设置 | 否 | 清除偏好设置 | 首次跟随系统 |
| 翻译端点与模型名 | 默认值或用户配置 | 构造翻译请求 | 本机偏好设置 | 请求时端点可见 | 用户覆盖配置 | 当前默认端点为 DeepSeek API |
| 翻译 API Key | 用户输入 | 请求鉴权 | macOS Keychain | 仅发送给所配置端点 | 用户在设置中清除 | 不返回 Web 界面，不进入工作台/日志 |
| 翻译输入文本、语言、模式、系统指令 | 用户主动提交 | 翻译和学习解析 | 临时网络请求/内存 | 是，发往所配置端点 | 由端点政策决定 | 不自动读取剪贴板、备忘录或 Agent 正文 |
| 翻译响应与 usage | 所配置端点 | 展示结果和本机用量汇总 | 内存；用户保存后写工作台；usage 汇总写偏好设置 | 从端点返回设备 | 用户保存内容由用户删除 | 临时会话、无 Cookie/URL 缓存、512 KB 响应上限 |
| 剪贴板 | 用户点击“复制” | 复制翻译结果 | 系统剪贴板 | 取决于用户后续粘贴位置 | 由系统/用户管理 | 应用写入选定结果，不自动读取剪贴板 |
| iPhone 隐私化 Agent 快照 | Mac producer 从本机快照生成；用户必须先明确开启 | iPhone 看板 | 用户私有 CloudKit 固定 `latest` 记录 + 按 iCloud 账号隔离的 iPhone 沙盒缓存 | 仅开启同步后离开 Mac；写入用户私有 CloudKit | 新快照覆盖固定记录；Mac 关闭同步时停止上传并删除云记录；iPhone 发现缺失记录时清除当前账号缓存 | 当前 producer 含 Agent/工具类别和安全名称、状态、时长、Token、时间戳、计数和临时序号；不含 prompt、任务摘要、回复、模型、密钥、备忘录、翻译内容或 Mac 路径 |
| 可选完整对话标题 | Mac 用户单独明确选择，且仅接受明确标题来源 | iPhone 会话展示 | 同一私有 CloudKit 记录及当前账号 iPhone 沙盒缓存 | **默认不发送**；单独同意后才离开 Mac | 随快照覆盖；关闭同步删除固定云记录 | producer 执行长度、路径、密钥样式和控制字符过滤；iPhone 每次启动默认隐藏；Live Activity 永不包含 |
| Live Activity 状态 | iPhone 主 App 从已验证快照生成 | 锁屏与灵动岛展示 | 由 ActivityKit 管理 | 不使用 APNs 远程推送 | 用户停止、无活跃 Agent 或系统结束 | 仅在 App 启动、返回前台或手动刷新时更新；仅含 Agent/对话数量、时长、Token、状态和更新时间，不含标题 |

当前 macOS 构建不包含摄像头、麦克风、屏幕录制或辅助功能用途字符串，也不调用对应的权限请求 API。“检查更新”只在用户点击后通过默认浏览器打开经统一 HTTPS 验证的 `AgentIslandSupportURL`；未配置时显示错误，不包含自动更新器。

## 3. 开发者实际接收的数据

按当前代码，开发者没有接收数据的服务器或遥测通道。周期性本机监控不联网。业务网络路径只有两类：用户明确开启的私有 CloudKit 快照同步，以及用户主动使用翻译器时直接连接到设置中显示的第三方或本机端点。

Mac producer、固定私有 CloudKit 记录契约、iPhone receiver、按账号隔离的缓存和 Live Activity 代码链路已实现，producer 的本地 CLI/回归已通过。当前仍未完成真实 Developer ID CloudKit entitlement/provisioning profile、正式 Container 与 Production schema、同一 iCloud 账号的 Mac→iPhone 真机验证和可提交 Archive，因此不得把“代码完成”写成“已上线同步”。

上线前仍应使用正式签名构建重做数据流审计：验证默认关闭和两级同意、固定记录覆盖/删除、账号切换隔离、项目路径/prompt/回复/API Key/备忘录/学习条目排除、可选标题的实际过滤，并将结果与 Privacy Manifest 和 App Privacy 回答对齐。

## 4. App Privacy 标签：最终选择前的判断

Apple 将“收集”定义为数据以开发者和/或第三方合作方可访问、且超过实时处理请求所必需时长的方式离开设备。仅仅在本机读取和显示的数据不属于 App Store 标签中的“收集”。但翻译端点是否保留请求、是否被视为第三方合作方，以及数据能否通过 API Key 关联到账号，必须在提交前确认。

### 建议的保守提交口径

在保留当前默认第三方翻译端点、且无法证明服务只做瞬时处理并立即删除的情况下，建议在 App Store Connect 选择“是，我们会从此 App 收集数据”，并至少审查/披露：

| App Privacy 数据类型 | 用途 | 是否关联身份 | 是否用于追踪 | 选择依据 |
| --- | --- | --- | --- | --- |
| Usage Data → Other Usage Data | App Functionality | **是** | 否 | 用户开启同步后，Agent/工具状态、时长和 Token 摘要保存在其 iCloud 私有数据库；当前 iOS Privacy Manifest 已按此声明 |
| User Content → Other User Content | App Functionality | **是/可能是**；完整标题通过私有 iCloud 与用户关联，翻译 API Key 也可能关联端点账号 | 否 | 正式版若保留可选标题同步，条件性标题必须披露；翻译正文也会在用户提交后发送到可能保留的端点 |
| Identifiers → User ID | App Functionality | 是（如端点把 API Key 映射到账号并保留请求） | 否 | 必须向最终服务商确认；不是开发者自建用户 ID |
| Usage Data → Product Interaction | App Functionality 或 Analytics | 取决于端点 | 否 | 仅当端点保留请求时间、模型或交互事件时选择 |
| Other Data | App Functionality | 取决于端点 | 否 | 仅当端点保存 IP/网络元数据且现有分类无法覆盖时选择 |

不要把只留在 Mac 的原始日志、备忘录、网站列表、项目路径或运行进程勾选为“收集”。只要最终构建开放 CloudKit 同步，就应至少保留上述 Other Usage Data 披露。如果保留“同步完整标题”开关，即使默认关闭，也要按 Apple 对条件性收集的要求评估并披露 Other User Content，或在首发构建中移除该功能。

### 何时可能选择 “Data Not Collected”

只有同时满足并留存证据时再考虑：

1. 最终提交构建不包含或完全不开放 CloudKit 同步，且开发者没有后端、遥测、分析、广告或崩溃上报；
2. 翻译端点完全由用户自行选择，开发者没有集成或合作关系；或服务商书面确认数据仅为实时完成请求且不会被其保留；
3. 最终构建不会向默认第三方端点自动或隐式发送任何内容；
4. App Store Connect/Apple Developer Support 对该具体安排的解释与此一致。

当前默认地址指向 DeepSeek，且可选 CloudKit 同步会保存 Other Usage Data，因此不能只凭“用户主动点击”就直接认定为 Data Not Collected。上线负责人需要记录服务商条款链接、版本/日期、保留期限和是否用于模型训练，再作最终选择。

### Tracking

当前应为 **No**。代码中没有广告标识符、数据经纪、广告 SDK或跨 App/网站定向广告逻辑。若未来加入任何分析或广告 SDK，必须重新评估，不得沿用本结论。

## 5. 隐私政策 URL 与用户隐私选择 URL

- macOS App Store 需要有效的公开隐私政策 URL：`[隐私政策URL]`。
- 用户隐私选择 URL 可选。当前没有开发者服务器账户；若填写，应指向真实可操作的本地数据清理、关闭私有同步并删除 CloudKit `latest` 记录的说明：`[用户隐私选择URL，可选]`。
- 支持页面应提供真实联系方式和完整卸载/清理说明，不应声称开发者能够删除从未收到的本机数据。

## 6. Privacy Manifest 与 Required Reason API

App Privacy 标签和 `PrivacyInfo.xcprivacy` 是两套相关但不同的申报。当前代码至少使用：

- `NSUserDefaults` 保存语言、翻译配置、自定义源和翻译 usage；
- 文件属性/修改时间用于日志签名、缓存、排序和增量扫描。

正式提交构建应让每个相关 Target 包含与自身行为一致的 `PrivacyInfo.xcprivacy`。根据最终沙盒实现逐个可执行文件审计，并从 Apple 当时的批准理由清单选择真实用途。当前实现可能对应的候选项是：

- `NSPrivacyAccessedAPICategoryUserDefaults`：应用自身可访问的偏好设置用途通常对应 `CA92.1`；提交前在 Apple 文档复核。
- `NSPrivacyAccessedAPICategoryFileTimestamp`：Mac App Store 沙盒版若只读取用户通过选择器授权的外部日志，可能对应 `3B52.1`；应用容器内文件元数据可能对应 `C617.1`。必须按每个实际调用的数据位置区分。

不要为了通过验证随意填理由码。Mac App Store 版若继续未经用户选择就扫描外部主目录，既无法由 `3B52.1` 合理解释，也会与 App Sandbox 要求冲突。

当前应用没有第三方二进制 SDK，但仍需让 Xcode 生成 Privacy Report，并检查 WebKit、系统框架、SQLite 链接和最终归档中是否出现额外清单或警告。

macOS 的 `Resources/PrivacyInfo.xcprivacy` 与 iOS App Target 的 `Config/PrivacyInfo.xcprivacy` 都已声明 `NSPrivacyCollectedDataTypeOtherUsageData` 和条件性的 `NSPrivacyCollectedDataTypeOtherUserContent`：与用户关联，用于 App Functionality，不用于追踪；`NSPrivacyTracking` 为 `false`，没有 tracking domains。后者覆盖用户单独同意后可能进入私有 CloudKit 的对话标题；即使默认关闭，也按 Apple 对持续性可选功能的口径申报。两个主 App 清单都声明 UserDefaults 的 `CA92.1` 理由；iOS 目前只用它保存是否开启明确标识的离线示例模式。iOS Widget Extension 使用独立的 `WidgetExtension/PrivacyInfo.xcprivacy`，其 collected data、accessed API、tracking domains 均为空，tracking 为 false；Widget 不拥有 CloudKit entitlement，只接收主 App 生成的不含标题 ActivityKit 状态。

上述 App Target 披露与私有 CloudKit 中的 Agent/工具状态、时长、Token 摘要及条件性标题一致，但仍必须在正式 Container/schema、签名和真机链路确定后使用 Xcode Privacy Report 复核，并在 App Store Connect 中采用相同口径。加入 APNs、认证 HTTPS、崩溃报告或分析时同样重审。

## 7. 翻译供应商上线决策表

已于 2026-09-02 完成官方公开资料基线审计，详见 `DEEPSEEK_TRANSLATION_PRIVACY_AUDIT.md`。技术接入符合当前官方文档，但 DeepSeek 的通用隐私政策明确排除下游应用终端用户的具体处理规则。公开材料未提供适用于本应用 API 请求的固定保留期或不训练承诺，因此下表区分“已验证事实”与“上线决策”，不得把通用政策当作 API 数据处理附件。

| 问题 | 2026-09-02 官方公开资料审计 | 上线前状态 |
| --- | --- | --- |
| 正式版默认端点是否仍为 DeepSeek | 当前代码默认为 `https://api.deepseek.com` | **待产品负责人决定** |
| 当前 API/模型是否有效 | `POST /chat/completions`、`deepseek-v4-flash` 和 `json_object` 为当前官方支持 | 已验证；发布日再查 |
| 是否允许无 API Key 的开发者代理端点 | 当前实现没有开发者代理或共享密钥 | 已验证；保持不变 |
| 供应商隐私政策与条款 | [DeepSeek 隐私政策](https://cdn.deepseek.com/policies/zh-CN/deepseek-privacy-policy.html)；[DeepSeek 开放平台服务协议](https://cdn.deepseek.com/policies/zh-CN/deepseek-open-platform-terms-of-service.html) | 已归档公开链接与版本日期 |
| 请求正文保留期 | 通用政策仅给出“必要期限”等原则；无本下游应用 API 请求的固定期限 | **未解决**；取得 API 专用书面依据或保守披露 |
| 是否用于训练或产品改进 | 通用政策称输入/输出可能用于训练和优化，但未给出本下游应用 API 专用规则 | **不得声称“不用于训练”** |
| 是否通过 API Key 关联用户账号 | 开放平台协议称 API Key 由账号创建，是调用必要凭证 | 以“可与端点账号关联”披露 |
| 是否保存 IP、时间、模型和错误日志 | 通用政策描述 IP、设备/网络和日志处理，但不是下游 API 专用保留清单 | **未解决**；保守告知可能处理连接/请求元数据 |
| 数据处理地区/跨境安排 | 通用中英文政策称其所覆盖的个人信息在中华人民共和国处理/存储；下游规则明确排除 | 在应用内和隐私政策显著告知这一公开基线及其边界 |
| 最终 App Privacy 数据类型/目的 | 不能据此公开证据选择 `Data Not Collected` | **待最终端点决策和 Apple 提交当日定义确定** |

## 8. 每次发布的差异审计

每个版本比较上一版并回答：

- 是否增加任何网络域名、SDK、后台任务或通知？
- 是否开始传输 Agent 标题、项目路径、Token、笔记或学习本？
- 是否增加 CloudKit、账号、登录、支付或崩溃上报？
- 是否改变翻译默认端点、请求字段、保留逻辑或 API Key 存储？
- 是否新增相机、麦克风、屏幕录制、辅助功能、通讯录、日历或位置权限？
- 是否改变 iOS 同步、Live Activity、APNs、后台刷新或标题选择？如果有，App Privacy 必须按对应 App 记录中数据实践最全面的平台填写。

任一答案为“是”都应先更新本文件、双语隐私政策、App Review Notes 和 App Store Connect 标签，再提交构建。

## 9. Apple 官方参考

- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)

Apple 会更新定义和理由码；以实际提交当日官方文档及 App Store Connect 为准。
