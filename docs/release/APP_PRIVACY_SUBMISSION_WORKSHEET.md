# App Privacy 提交工作表

> 状态：发布门禁模板。只有最终签名候选包、Xcode Privacy Report、生产 CloudKit、翻译供应商决策和 App Store Connect 答案都以下方结构化证据绑定到同一候选包后，发布检查才会通过。

这份工作表把代码中的 Privacy Manifest、隐私政策和 App Store Connect 问卷分开管理。Privacy Manifest 不会自动替代 App Store Connect 的 App Privacy 回答；两者必须与最终构建的真实行为一致。

## 1. 先确定回答范围

App Privacy 回答位于 **App 记录级别**，不是单个 Target 或单个平台级别。若 iOS 与 macOS 使用同一个 App Store Connect App 记录，应按两个平台中最全面的实际数据处理方式回答，而不是只看 iPhone App。

当前工作表基于以下候选功能：

- Mac 可在用户明确同意后把精简 Agent 状态写入用户的 CloudKit 私有数据库；
- 状态快照包含工具/Agent 类别与安全名称、状态、时长、Token、时间戳、数量和临时序号；
- 完整对话标题默认关闭，但提交构建中保留了单独选择同步标题的能力；
- Mac 翻译器由用户主动提交自由文本，当前预览默认远程端点为 DeepSeek API；
- Mac 提供用户主动开启、持续显式标识的内置离线 Agent 监测示例；示例快照每次在内存重建，只保存一个开关，不读本机 Agent 日志或自定义源，不访问网络或 CloudKit；
- 没有开发者后端、广告、分析、崩溃上报或跨 App/网站追踪；
- iOS Widget 不自行访问 CloudKit，只显示主 App 提供的不含标题的 ActivityKit 状态。

若最终构建删除、增加或改变任何一项，先停止填写并更新本工作表。

## 2. App Store Connect 起始答案

在 **App Privacy → Get Started** 中，当前候选构建不能选择 **No, we do not collect data from this app**。选择：

> **Yes, we collect data from this app**

原因：持续性的可选 CloudKit 同步不满足 Apple 的全部“可选披露”条件；当前翻译供应商也没有提供足以证明请求只为实时处理且立即删除的公开证据。

## 3. 当前必须选择的数据类型

下面是保留当前 CloudKit schema 和可选标题同步时的最低申报。每个问题都按 App Store Connect 英文标签记录，避免中文界面翻译变化造成歧义。

| 数据类型 | Select purposes | Linked to the user's identity? | Used for tracking? | 对应真实数据 |
| --- | --- | --- | --- | --- |
| **Usage Data → Other Usage Data** | **App Functionality** | **Yes** | **No** | 用户开启同步后写入私有 CloudKit 的 Agent/工具状态、时长、Token、时间戳和数量摘要 |
| **User Content → Other User Content** | **App Functionality** | **Yes** | **No** | 用户另行同意后可进入私有 CloudKit 的完整对话标题；若翻译服务保留请求，也覆盖用户主动提交的自由文本 |

选择 **Linked: Yes** 是当前保守且一致的口径：CloudKit 记录属于已登录 Apple ID 的私有数据库；翻译请求还可能通过用户自己的 API Key 关联到供应商账号。当前没有可靠的去标识化措施证明这些数据无法重新关联。

选择 **Tracking: No** 的前提是最终构建继续没有广告 SDK、数据经纪、跨 App/网站定向广告或广告衡量。此答案不等于“不会离开设备”。

## 4. 翻译供应商决定后才能锁定的类型

DeepSeek 的公开材料没有为本应用 API 请求提供固定保留期、不训练承诺或完整的 API 请求日志字段清单。发布负责人必须在下表逐项留下证据；不能凭猜测勾选，也不能为了得到更简短的隐私标签而省略。

| 条件 | 若最终证据表明会保留，应增加 | 用途 | Linked | Tracking |
| --- | --- | --- | --- | --- |
| API Key 对应的账号标识被保存或用于处理记录 | **Identifiers → User ID** | App Functionality | Yes | No |
| 请求时间、模型、功能调用或交互事件被保存 | **Usage Data → Product Interaction** | App Functionality；只有实际用于产品分析时才增加 Analytics | 按供应商证据；无法证明去关联时选 Yes | No |
| IP 地址或连接元数据被保存，且不能由其他已选类型准确覆盖 | **Other Data → Other Data Types** | App Functionality | 按供应商证据；无法证明去关联时选 Yes | No |

上线前二选一并记录决定：

1. 保留默认 DeepSeek：取得适用于本应用 API 调用的书面保留、训练、账号关联、日志字段与处理地区说明；否则采用上表的保守扩展披露。
2. 移除默认供应商：只允许用户自行填写兼容端点，并重新审计应用内告知、网络域名、隐私政策和 App Privacy；CloudKit 的 **Other Usage Data** 与可选标题的 **Other User Content** 仍然保留。

即使翻译请求最终符合实时处理例外，只要提交构建仍保留持续 CloudKit 同步，就不能把整个 App 改成 **Data Not Collected**。

## 5. 不应选择的数据类型

在当前功能不变时，不要申报仅留在设备上的数据：本机原始 Agent 日志、项目路径、备忘录、网站列表、本地学习条目、运行进程清单和 Keychain 中的 API Key。App Privacy 的“收集”不等于设备内处理。

当前也没有证据支持选择广告、购买、位置、联系人、健康、照片、音频、浏览历史、搜索历史、崩溃、性能或设备标识等类型。若最终归档引入新的 SDK 或网络服务，必须重新审计，不能沿用本段。

内置虚构示例本身不是“收集”数据，也不改变上述 App Privacy 类型。候选包的网络观测和审核路径证据必须另外证明：示例期间没有 Agent 日志/数据源读取、CloudKit 访问、翻译或外链请求；“重新查看数据访问说明”不会开启真实监测；且退出示例后监测仍为关闭。

## 6. 与 Privacy Manifest 的固定映射

| Target | Manifest | 当前必须匹配的声明 |
| --- | --- | --- |
| macOS 主 App | `Resources/PrivacyInfo.xcprivacy` | Other Usage Data + Other User Content；App Functionality；Linked；No Tracking。原生 macOS 不套用 iOS 等平台的 Required Reason API 申报门禁 |
| iOS 主 App | `ApplePlatforms/iOS/Config/PrivacyInfo.xcprivacy` | Other Usage Data + Other User Content；App Functionality；Linked；No Tracking；UserDefaults `CA92.1` |
| iOS Widget Extension | `ApplePlatforms/iOS/WidgetExtension/PrivacyInfo.xcprivacy` | 不声明 collected data 或 required-reason API；No Tracking；无 tracking domains |

macOS 的 App Sandbox、用户选择目录和 security-scoped bookmark 是独立的文件授权与功能验收门禁，不由 Privacy Manifest 中的移动平台 Required Reason API 字段代替。`validate-app-privacy.mjs` 会报告源码扫描/bookmark 诊断，但不把字符串命中当作沙盒验收证据。

运行以下命令检查仓库内三份清单与本工作表的固定映射：

```bash
node scripts/validate-app-privacy.mjs
```

默认模式允许可复用仓库缺少本机发布证据；对候选发布使用 `node scripts/validate-app-privacy.mjs --release`。该命令会核对真实候选包和每份证据文件的 SHA-256，并要求每份文本证据都明文记录同一组候选包 SHA-256。它仍不会自动判断第三方条款是否充分，证据内容仍需发布负责人复核。

## 7. URL 填写值

正式站点公开后，为每个平台和本地化填写：

| Locale | Privacy Policy URL | User Privacy Choices URL（可选） |
| --- | --- | --- |
| 简体中文 | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/` | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/#delete-data` |
| English (U.S.) | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/` | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/#delete-data-en` |

上述页面已由公开 GitHub Pages 站点提供，中英文合并在同一份隐私政策中。每次提交前仍需用未登录浏览器复核 HTTPS、200 响应、移动端可读、无占位符，并确认两个隐私选择锚点分别直接定位到对应语言的关闭同步与数据清理步骤。

## 8. 发布前结构化证据

不使用手动勾选框或单独的 `VERIFIED=true` 作为完成证明。先把每个待上传的 `.ipa`、`.pkg`、应用 ZIP 或 `.xcarchive.zip` 作为不再变更的普通文件放在仓库内已忽略的 `dist/` 目录，再将文本/JSON 证据放在 `.release/app-privacy-evidence/`。门禁会检查扩展名、ZIP/XAR 文件头、包内 App `Info.plist`、可执行文件和 Privacy Manifest；每份证据文件还必须明文包含它所验证的全部候选包 SHA-256。

默认门禁读取 `.release/app-privacy-evidence.json`；如果需要其他仓库内路径，设置 `AGENT_ISLAND_APP_PRIVACY_EVIDENCE`。路径不得越出仓库，不得是符号链接。下方是必须完整填写的结构；`null` 不会通过 `--release`：

`releaseEvidenceReady` 只表示这份文档自身完整，不代表任意平台的当前构建已绑定。`release-readiness.sh` 会先要求 evidence 的 `recordScope` 与 `AGENT_ISLAND_APP_STORE_RECORD_MODE` 精确一致（`universal-purchase` 或 `separate-records`），再对 iOS 和 macOS 分别查找唯一的 archive 条目，并要求 `platform` / `distribution` / `bundleID` / `version` / `build` 以及候选文件 SHA-256 全部匹配。iOS 必须绑定已通过本地 `submit-testflight.sh --check` 的同一 IPA；macOS 有导出包时必须绑定当前精确候选的 `.pkg`，未导出包时才绑定同一候选的 Archive ZIP。当记录模式为 `universal-purchase` 时，Mac-only 或 iOS-only 证据即使自身完整，也不会打开任一平台的发布门禁。

```json
{
  "schemaVersion": 1,
  "recordScope": null,
  "reviewedAt": null,
  "archives": [
    {
      "platform": null,
      "distribution": null,
      "path": null,
      "sha256": null,
      "bundleID": null,
      "version": null,
      "build": null
    }
  ],
  "evidence": {
    "privacyManifests": { "path": null, "sha256": null, "candidateArchiveSHA256s": [] },
    "xcodePrivacyReport": { "path": null, "sha256": null, "candidateArchiveSHA256s": [] },
    "networkAudit": { "path": null, "sha256": null, "candidateArchiveSHA256s": [] },
    "cloudKitVerification": { "path": null, "sha256": null, "candidateArchiveSHA256s": [] },
    "titleSyncVerification": { "path": null, "sha256": null, "candidateArchiveSHA256s": [] },
    "translationProviderDecision": { "path": null, "sha256": null, "candidateArchiveSHA256s": [] },
    "publicPagesVerification": { "path": null, "sha256": null, "candidateArchiveSHA256s": [] },
    "appStoreConnectPublication": { "path": null, "sha256": null, "candidateArchiveSHA256s": [] }
  }
}
```

`recordScope` 只能是 `macOS`、`iOS`、`universal-purchase` 或 `separate-records`；macOS 候选项的 `distribution` 必须是 `mac-app-store`，iOS 必须是 `app-store`。共用记录必须绑定各一份 iOS 与 macOS 候选包且 App Bundle ID 相同；分开记录也要绑定两份候选包，但 App Bundle ID 必须不同。八份证据依次覆盖：最终包内 Manifest、Xcode Privacy Report、网络观测（含 macOS 离线示例的零网络/零 Agent 日志读取证据）、CloudKit Production/删除验证、标题同步边界、翻译供应商决策、公开双语页面的 HTTP/`#delete-data` 验证，以及 App Store Connect App Privacy 已 Publish 的导出或截图索引。

## 9. 发布操作顺序

1. 冻结同一个最终候选 Build，生成并审阅 Xcode Privacy Report。
2. 完成上方供应商决定与证据记录；按最终事实增删数据类型。
3. 在 App Store Connect 的 App Privacy 中选择数据类型，逐个填写 Purpose、Linked 和 Tracking。
4. 填写并验证各平台、本地化的 Privacy Policy URL 与可选 Privacy Choices URL。
5. 对照产品页预览、双语隐私政策和最终 Archive；任一处不一致都先修正。
6. 由 Account Holder、Admin 或 App Manager 在确认答案准确后点击 **Publish**。

## 10. Apple 官方依据

- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [App privacy reference](https://developer.apple.com/help/app-store-connect/reference/app-privacy/)
