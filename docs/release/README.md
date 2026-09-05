# MAC版灵动岛--Agent运行监测 上线材料索引

> 状态：发布准备进行中。更新日期：2026-09-05。Apple 标识、Universal Purchase 记录、Production CloudKit schema、双语商店元数据与 TestFlight 描述/URL 已保存；截图、法律/版权信息、联系人、DSA、价格/地区、Content Rights、年龄分级、Build、App Privacy 问卷和审核仍未完成。

本目录以 MAC版灵动岛--Agent运行监测 0.6.1（Build 8）的 macOS 实现和 `ApplePlatforms/iOS` 中的 iPhone 伴侣工程为准，覆盖 Developer ID 直接分发、Mac App Store、iOS App Store 与 TestFlight。Mac CloudKit producer、原生 macOS Xcode 工程、SwiftUI iPhone 看板、Widget/Live Activity Extension、私有 CloudKit receiver/离线缓存、Privacy Manifest、App Icon 与发布证据链均已进入仓库。正式 Team、Bundle、Widget、Container 已锁定，四份渠道 profile 已在 Apple Developer 生成并保存到 Git 忽略的本地发布目录，Production schema 也已部署；但这些后台准备不等于可提交构建，仍须完成正式 Archive、签名/profile 绑定验证、上传、真机 QA、商店素材与审核流程。

## 已登记的正式配置

| 项目 | 当前值 |
| --- | --- |
| App Store 记录模式 | Universal Purchase（iOS 与 macOS 共用一个 App 记录） |
| App 名称 | `MAC版灵动岛--Agent运行监测` |
| macOS / iOS Bundle ID | `com.kiki.agentisland` |
| Widget / Live Activity Bundle ID | `com.kiki.agentisland.liveactivity` |
| Team ID | `AW4HMBZN7M` |
| CloudKit Container | `iCloud.com.kiki.agentisland` |
| CloudKit 契约 | Private / Production / `AgentIslandSnapshot` / `latest` / `payloadJSON` |
| App Store Connect App ID | `6808917414` |
| SKU | `AGENTISLAND-UNIVERSAL` |
| iOS / macOS 版本 | `0.6.1` |
| 发布方式 | 审核通过后手动发布（iOS / macOS） |
| 类别 | Developer Tools（主）/ Productivity（次） |
| Marketing URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/` |
| Support URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/` |
| Privacy Policy URL | `https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/` |

Production schema 已部署。公共数据库仅保留兜底权限：`_icloud` 可创建，`_creator` 可读取和写入，未授予 `_world` 读取；应用运行时仍固定使用用户私有数据库。已生成 iOS App Store、Widget App Store、Mac App Store 与 Developer ID CloudKit 四份 profile，本地文件只存放在 Git 忽略的发布目录中，不纳入仓库。

## 文件

- `PRIVACY_POLICY_ZH.md`：简体中文隐私政策草案。
- `PRIVACY_POLICY_EN.md`：英文隐私政策草案。
- `APP_STORE_METADATA.md`：Mac App Store 中英文元数据。
- `APP_REVIEW_NOTES.md`：macOS 审核说明及审核路径。
- `IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md`：iOS App Store 与 TestFlight 中英文元数据。
- `IOS_APP_REVIEW_NOTES.md`：iOS 审核说明、数据边界和演示路径。
- `IOS_SCREENSHOT_CHECKLIST.md`：iPhone、锁屏实时活动和灵动岛截图清单。
- `STORE_SCREENSHOT_EVIDENCE.schema.json`：最终中英文截图与精确候选包的结构化证据契约；填写方式见 `../release-assets/README.md`。
- `APP_STORE_SUBMISSION.schema.json`：macOS/iOS App Store 记录、版本、商业合规、审核、TestFlight 与截图顺序的强类型提交清单契约；可复制的待填样例位于 `../../Config/AppStoreSubmission.example.json`。
- `PUBLIC_PAGES_EVIDENCE.md`：隐私政策与支持页面的显式联网采集、本地封存及离线复验流程。
- `ASC_READONLY_SNAPSHOT.md`：App Store Connect App/Build/提交元数据子集的只读快照、精确候选绑定和 15 分钟有效期契约。
- `DATA_HANDLING_AND_PRIVACY_LABELS.md`：数据处理清单、App Privacy 标签建议和 Privacy Manifest 审计项。
- `APP_PRIVACY_SUBMISSION_WORKSHEET.md`：App Store Connect App Privacy 逐项填写基线、Manifest 映射和最终构建证据表。
- `DEEPSEEK_TRANSLATION_PRIVACY_AUDIT.md`：DeepSeek 默认翻译端点的官方公开资料、代码核对、数据地区/保留/训练边界和建议的分层告知文案。
- `RELEASE_IDENTITY.md`：正式 Bundle/Team/Container 的只读检查、首次可恢复应用、身份锁和 profile 派生 entitlement 流程。
- `RELEASE_CHECKLIST.md`：从当前开发构建到公开上线的检查清单。

源码阶段可分别运行 `node scripts/validate-app-privacy.mjs` 和 `node scripts/validate-store-submission.mjs`。正式素材除了 `docs/release-assets` 下四组图片，还必须提供默认位于 `.release/store-screenshot-evidence.json` 的结构化证据，把每张本地化截图绑定到 App Privacy 已核验的同一候选包；详见 `../release-assets/README.md`。商店素材校验器的 `releaseReady` / `storeSubmissionAssetsReady` 是 macOS 与 iOS 都完成后的汇总；单独发布某个平台时，以 readiness 报告中的 `macStoreSubmissionAssetsReady` 或 `iosStoreSubmissionAssetsReady` 为准。Mac 上传不会被未完成的 iOS 截图或 Build 阻断，iOS 最终提审也只读取 iOS 对应材料；双语隐私政策、App Privacy worksheet 和公开支持联系方式仍是两端共用门禁。这些检查不代替最终 Archive、签名/profile、Xcode Privacy Report 和真机验证。

## 强类型 App Store 提交清单

请先复制样例，再由有权账号持有人填写 App Store Connect 真实状态：

```bash
cp Config/AppStoreSubmission.example.json .release/app-store-submission.json
node scripts/validate-app-store-submission.mjs
node scripts/validate-app-store-submission.mjs --release
```

草案和本地诊断可以用 `AGENT_ISLAND_APP_STORE_SUBMISSION` 指定已规范化的仓库相对路径；但最终 readiness、公开页绑定和 App Review 选择门禁只接受固定文件 `.release/app-store-submission.json`。自定义路径不是发布别名，不能进入最终证据链。无 `--release` 的草案模式允许显式占位符并逐项报告未决项，但 `localPreflightReady` 与各平台 `submissionManifestReady` 会保持 `false`；发布模式会对任何占位符、未知/缺失字段、不安全路径、符号链接、明文凭据、版本/Bundle 偏差、未决商业合规以及与精确候选包不一致的截图集失败关闭。清单校验器会消费 `validate-store-submission.mjs` 的结果并绑定 identity lock、证据哈希、候选包 tuple、双语元数据与有序截图集合。输出中的 `appStoreConnectComparison.expected` 提供每个平台预期的 App Resource ID、Bundle ID、SKU、Primary Locale、价格与地区，供 ASC 对照；当前 Build 快照只能证明 App 身份子集，不能证明可售地区、Made for Kids、Content Rights 和加密回答等远端元数据。因此 `macAppStoreConnectRemoteMetadataComparisonComplete` / `iosAppStoreConnectRemoteMetadataComparisonComplete` 当前固定为 `false`，`readyForMacAppStoreReviewSelection` / `readyForIOSAppStoreReviewSelection` 也保持失败关闭；`submissionReadyForRemoteAction` 同样始终为 `false`。它不接受 Apple 密码、App 专用密码、API 私钥或 Token；审核账号必须使用 `keychain://` 或 `ci-secret://` 定位引用，且密文本身不得进入清单或 Git。

精确 Build 快照之上还可使用 `capture-asc-submission-metadata.mjs` 封存 API 可见的 App、版本、已关联 Build、双语文案、脱敏审核匹配结果与 TestFlight 子集；脚本不会查询或保存审核账号名和密码。该证据会诚实列出税类、DSA、Made for Kids 当前声明、年龄分级、截图顺序及审核凭据可用性等人工项，不会将 API 可见子集误报为整份提交已验证。首发须将 `version.releaseKind` 设为 `initial` 且所有商店 `whatsNew` 设为 `null`；后续更新才使用 `update` 与非空更新说明。

## 身份锁与 Mac App Store 证据层级

新的正式身份必须使用 `Config/ReleaseIdentity.json` schemaVersion 2，并由 `.release/identity.lock.json` 锁定。`appStoreRecordMode=universal-purchase` 时 macOS/iOS 主 App Bundle ID 必须相同；`separate-records` 时必须不同。`AGENT_ISLAND_APP_STORE_RECORD_MODE`、`AGENT_ISLAND_BUNDLE_ID` 和 `AGENT_ISLAND_IOS_BUNDLE_ID` 必须分别等于锁中的记录模式、macOS App ID 和 iOS App ID；旧 schemaVersion 1 只作 Universal Purchase 兼容输入，不能表示分开记录。

Mac App Store 发布状态必须按以下证据层级逐步判定，不得用单个布尔值跨层代替：

1. `release-macos-app-store.sh --export` 生成 `release-metadata.json`、Archive ZIP 和 PKG；`submit-macos-app-store.sh --check` 在本地重算哈希并重验精确候选，不上传。
2. `confirm-functional-qa-evidence.sh` 将沙盒授权/拒绝/撤销/恢复、Archive/PKG 安装启退、profile+证书、Xcode Privacy Report 和审核路径的五份不同附件绑定到同一 Archive ZIP + PKG。将生成的只读、不覆盖记录填入 `AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE`。
3. `readyForMacAppStoreUpload: true` 只表示本地候选、候选级 App Privacy、功能 QA 和 `macStoreSubmissionAssetsReady` 已通过上传前门禁；它不依赖 iOS 独有素材，也不表示已上传、Apple 已处理或已提审。
4. 显式执行 `submit-macos-app-store.sh --upload` 后，将交付记录填入 `AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE`。上传命令被接受不等于 App Store Connect 处理完成。
5. 人工在 App Store Connect 确认该精确构建为 `Complete` 并检查全部警告后，用 `confirm-macos-app-store-evidence.sh` 生成处理记录，再填入 `AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE`。这是操作人员的本地证据，验证脚本不会回查 Apple 状态。
6. 当前已能封存 App Store Connect API 可见的 macOS 提交元数据子集；但价格/地区、DSA、年龄分级语义、版权/Content Rights 和截图顺序等仍需独立人工证据，所以 `readyForMacAppStoreReviewSelection` 总门禁继续失败关闭。元数据快照要求授权人先把精确 Build 关联到对应 macOS version；未来即使该字段为 `true`，也只表示这条关联及本地证据链已通过，不表示已经 Add for Review 或 Submit for Review。执行审核动作前仍需运行 `scripts/assert-release-preflight.sh mac-app-store-review /absolute/path/readiness.json` 复验，并由授权人再次核对价格/地区、DSA、年龄分级、版权/Content Rights 和加密回答。

iOS 也分为两个独立层级：`readyForFunctionalIOSTestFlight: true` 只表示精确 TestFlight 安装包已完成候选绑定的处理、安装、隐私与真机功能验收；`readyForIOSAppStoreReviewSelection` 另外要求 iOS 中英文商店材料、截图、App Icon、公开支持信息、App Privacy 证据、记录模式和全量远端元数据比对。当前已能封存 API 可见子集，但价格/地区、DSA、年龄分级语义、版权/Content Rights 和截图顺序等仍需独立人工证据，所以该选择总门禁继续失败关闭并保持 `false`。可用
`scripts/assert-release-preflight.sh ios-app-store-review /absolute/path/readiness.json`
在进入 App Store Connect 前复验。该证据可验证精确 Build 已关联到对应 iOS version，但仍不表示已经 Add for Review 或 Submit for Review；这两项远程操作必须由账号授权人明确执行。

readiness 报告会把本次 ASC 新鲜度策略原样固化为 `appStoreConnectSnapshotMaxAgeValid` 和 `appStoreConnectSnapshotMaxAgeSeconds`，供后续 preflight 使用同一边界复验。当 ASC 快照未配置或未通过验证时，`macAppStoreConnectBuildSnapshotWarningsPresent` / `iosAppStoreConnectBuildSnapshotWarningsPresent` 为 `null`，表示“未知”，而不是“已确认无警告”。整个 `release-readiness.sh` 流程只做本地 `--verify`，不联网也不修改 App Store Connect。

## 仍须补齐的范围

已保存的元数据不再列为待办。发布前只剩以下类别：

- 截图。
- 法律/版权信息，包括法定姓名、版权所有者、生效日期和必要的加密/许可回答。
- 支持、TestFlight 与 App Review 联系人。
- DSA、价格/地区、Content Rights 和年龄分级。
- 正式 Build 及其关联。
- App Privacy 问卷与最终数据处理证据。
- TestFlight / App Store 审核材料与提交。

不得编造公司名称、网址、邮箱、电话、地址或组织身份。个人开发者应填写 Apple Developer 账号对应的法定个人姓名。

## 当前上线阻断项

1. Apple 自 2026-04-28 起要求 iOS/iPadOS 上传使用 iOS/iPadOS 26 SDK 或更新版；Xcode 26 至少需要 macOS Sequoia 15.6。Mac App Store 不在这条 26 SDK 清单中，其 2026 通用上传门槛为完整 Xcode 14+；`release-readiness.sh` 会分别报告 iOS 与 Mac App Store 门槛。Developer ID 流程只检查实际所需的 `clang`/`notarytool`/`stapler`，不继承 Xcode 26 门槛。
2. 正式发布身份已锁定，但尚未生成并验证绑定该身份的最终 Archive/PKG/IPA，也尚未完成上传。
3. Mac App Store Xcode Target、App Sandbox、主目录只读安全书签及撤销/重新授权源码已完成静态验证；Archive、PKG 与上传快照现会递归拒绝 `com.apple.quarantine`。仍需在完整 Xcode、正式签名的商店构建中实测授权、拒绝、书签失效、监测停止与恢复流程。
4. 隐私政策与支持页面已部署到稳定的公开 GitHub Pages URL，并于 2026-09-04 从未登录请求复核 HTTPS 200。每个候选提交前仍须重新验证并将结果绑定到候选包，同时补齐 App Store Connect 所需的法定姓名、支持邮箱等账号材料。
5. 翻译器默认地址当前指向 DeepSeek API。官方公开资料基线审计已归档，应用内分层告知、首次离机传输确认和官方政策链接已实施，公开隐私页也已同步。但公开材料未给出本下游应用 API 请求的固定保留期或不训练承诺；仍需决定是否保留默认第三方端点，并据此最终确认 App Privacy 标签。
6. iOS 与 macOS 都已有明确标识、可退出并重置的内置离线示例模式。macOS 示例仅替代 Agent 监测数据，不读本机 Agent 日志/自定义源，不访问网络或 CloudKit，且退出后不自动恢复真实监测；iOS 示例不访问 CloudKit。两者都不能替代候选签名构建的动态验收、真实生产同步或真机验证。
7. Mac producer 与 iPhone receiver 的代码契约已接通，正式 Container 与 Production schema 已配置；同账号 Mac→iPhone 真机链路、同步关闭后的云端删除、账号切换和错误恢复仍须绑定最终签名构建验收。
8. App Store Connect 已建立 App ID `6808917414` 的 iOS + macOS Universal Purchase 记录，两个平台版本均为 `0.6.1` 且设为审核后手动发布；双语副标题、推广文本、描述、关键词、Marketing/Support/Privacy URL 与 TestFlight Beta App Description 已保存。仍待截图、法律/版权信息、联系人、DSA、价格/地区、Content Rights、年龄分级、Build、App Privacy 问卷与审核。

## 官方核对入口

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App Store 当前上传 SDK 要求](https://developer.apple.com/app-store/submitting/)
- [App Store Connect Upload builds（含支持的 Xcode 版本）](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Upcoming Requirements（含 macOS quarantine 门槛）](https://developer.apple.com/news/upcoming-requirements/)
- [Xcode 系统要求](https://developer.apple.com/xcode/system-requirements/)
- [App Store Connect 元数据字段](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [App Privacy 填写说明](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Privacy Manifest](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [iPhone 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [TestFlight 概览](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)

Apple 的要求会更新。每次正式提交前，应重新核对上述官方页面和 App Store Connect 当时显示的字段。
