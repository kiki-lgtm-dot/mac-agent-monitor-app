# MAC版灵动岛--Agent运行监测 上线材料索引

> 状态：草案。更新日期：2026-09-04。以下文件不能在保留占位符的情况下直接发布或提交 App Review。

本目录以 MAC版灵动岛--Agent运行监测 0.6.1（Build 8）的 macOS 实现和 `ApplePlatforms/iOS` 中的 iPhone 伴侣工程为准，覆盖 macOS 直接分发、Mac App Store、iOS App Store 与 TestFlight 准备。仓库现已包含 Mac CloudKit 隐私化快照 producer、带 App Sandbox 和主目录只读安全书签流程的原生 macOS Xcode 工程、SwiftUI iPhone 看板、Widget/Live Activity Extension、按 iCloud 账号隔离的私有 CloudKit receiver/离线缓存、App 与 Widget 独立 Privacy Manifest、App Icon，以及只归档/导出但不上传的发布脚本、需要精确 IPA 二次确认的 TestFlight 上传脚本与离线后处理证据链，本地静态校验与回归已通过。但正式 Team/Bundle/Container ID、真实签名与 provisioning profile、Production schema、完整 Xcode Archive、沙盒实机流程及同一 iCloud 账号的 Mac→iPhone 真机验证仍未完成，因此不能宣称当前构建已具备商店上线条件。

## 文件

- `PRIVACY_POLICY_ZH.md`：简体中文隐私政策草案。
- `PRIVACY_POLICY_EN.md`：英文隐私政策草案。
- `APP_STORE_METADATA.md`：Mac App Store 中英文元数据。
- `APP_REVIEW_NOTES.md`：macOS 审核说明及审核路径。
- `IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md`：iOS App Store 与 TestFlight 中英文元数据。
- `IOS_APP_REVIEW_NOTES.md`：iOS 审核说明、数据边界和演示路径。
- `IOS_SCREENSHOT_CHECKLIST.md`：iPhone、锁屏实时活动和灵动岛截图清单。
- `DATA_HANDLING_AND_PRIVACY_LABELS.md`：数据处理清单、App Privacy 标签建议和 Privacy Manifest 审计项。
- `APP_PRIVACY_SUBMISSION_WORKSHEET.md`：App Store Connect App Privacy 逐项填写基线、Manifest 映射和最终构建证据表。
- `DEEPSEEK_TRANSLATION_PRIVACY_AUDIT.md`：DeepSeek 默认翻译端点的官方公开资料、代码核对、数据地区/保留/训练边界和建议的分层告知文案。
- `RELEASE_IDENTITY.md`：正式 Bundle/Team/Container 的只读检查、首次可恢复应用、身份锁和 profile 派生 entitlement 流程。
- `RELEASE_CHECKLIST.md`：从当前开发构建到公开上线的检查清单。

源码阶段可分别运行 `node scripts/validate-app-privacy.mjs` 和 `node scripts/validate-store-submission.mjs`。商店素材校验器的 `releaseReady` / `storeSubmissionAssetsReady` 是 macOS 与 iOS 都完成后的汇总；单独发布某个平台时，以 readiness 报告中的 `macStoreSubmissionAssetsReady` 或 `iosStoreSubmissionAssetsReady` 为准。Mac 上传不会被未完成的 iOS 元数据或截图阻断，iOS 最终提审也只读取 iOS 对应材料；双语隐私政策、App Privacy worksheet 和公开支持联系方式仍是两端共用门禁。这些检查不代替最终 Archive、签名/profile、Xcode Privacy Report 和真机验证。

## 身份锁与 Mac App Store 证据层级

新的正式身份必须使用 `Config/ReleaseIdentity.json` schemaVersion 2，并由 `.release/identity.lock.json` 锁定。`appStoreRecordMode=universal-purchase` 时 macOS/iOS 主 App Bundle ID 必须相同；`separate-records` 时必须不同。`AGENT_ISLAND_APP_STORE_RECORD_MODE`、`AGENT_ISLAND_BUNDLE_ID` 和 `AGENT_ISLAND_IOS_BUNDLE_ID` 必须分别等于锁中的记录模式、macOS App ID 和 iOS App ID；旧 schemaVersion 1 只作 Universal Purchase 兼容输入，不能表示分开记录。

Mac App Store 发布状态必须按以下证据层级逐步判定，不得用单个布尔值跨层代替：

1. `release-macos-app-store.sh --export` 生成 `release-metadata.json`、Archive ZIP 和 PKG；`submit-macos-app-store.sh --check` 在本地重算哈希并重验精确候选，不上传。
2. `confirm-functional-qa-evidence.sh` 将沙盒授权/拒绝/撤销/恢复、Archive/PKG 安装启退、profile+证书、Xcode Privacy Report 和审核路径的五份不同附件绑定到同一 Archive ZIP + PKG。将生成的只读、不覆盖记录填入 `AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE`。
3. `readyForMacAppStoreUpload: true` 只表示本地候选、候选级 App Privacy、功能 QA 和 `macStoreSubmissionAssetsReady` 已通过上传前门禁；它不依赖 iOS 独有素材，也不表示已上传、Apple 已处理或已提审。
4. 显式执行 `submit-macos-app-store.sh --upload` 后，将交付记录填入 `AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE`。上传命令被接受不等于 App Store Connect 处理完成。
5. 人工在 App Store Connect 确认该精确构建为 `Complete` 并检查全部警告后，用 `confirm-macos-app-store-evidence.sh` 生成处理记录，再填入 `AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE`。这是操作人员的本地证据，验证脚本不会回查 Apple 状态。
6. `readyForMacAppStoreReviewSelection: true` 只表示证据链已支持在对应 macOS 版本中人工选择该 Build；它不表示 Build 已被选中，更不表示已执行 App Review 提交。选择构建和最终提审仍由账号授权人在 App Store Connect 中完成。

iOS 也分为两个独立层级：`readyForFunctionalIOSTestFlight: true` 只表示精确 TestFlight 安装包已完成候选绑定的处理、安装、隐私与真机功能验收；`readyForIOSAppStoreReviewSelection: true` 还要求 iOS 中英文商店材料、截图、App Icon、公开支持信息、App Privacy 证据和记录模式全部通过。可用
`scripts/assert-release-preflight.sh ios-app-store-review /absolute/path/readiness.json`
在进入 App Store Connect 前复验。该结果仍不表示已经选择 Build、Add for Review 或 Submit for Review，这些远程操作必须由账号授权人明确执行。

## 必须替换的占位符

发布前全文搜索 `[`，逐项替换或删除：

- `[开发者法定姓名]` / `[Developer Legal Name]`
- `[支持邮箱]` / `[Support Email]`
- `[营销URL，可选]` / `[Marketing URL, optional]`
- `[正式Bundle ID]`、`[SKU]`、`[版权所有者]`
- `[正式iOS Bundle ID]`、`[正式iOS Widget Bundle ID]`、`[正式iCloud Container ID]`、`[iOS SKU]`
- `[TestFlight反馈邮箱]` 与 iOS/macOS 审核联系人、演示数据说明
- `[生效日期：YYYY-MM-DD]` / `[Effective Date: YYYY-MM-DD]`
- 审核所需的测试文件、翻译端点和临时凭据占位符

不得编造公司名称、网址、邮箱、电话、地址或组织身份。个人开发者应填写 Apple Developer 账号对应的法定个人姓名。

## 当前上线阻断项

1. Apple 自 2026-04-28 起要求 iOS/iPadOS 上传使用 iOS/iPadOS 26 SDK 或更新版；Xcode 26 至少需要 macOS Sequoia 15.6。Mac App Store 不在这条 26 SDK 清单中，其 2026 通用上传门槛为完整 Xcode 14+；`release-readiness.sh` 会分别报告 iOS 与 Mac App Store 门槛。Developer ID 流程只检查实际所需的 `clang`/`notarytool`/`stapler`，不继承 Xcode 26 门槛。
2. 当前 Bundle ID 为开发占位值 `local.agentisland.desktop`，构建采用 ad-hoc 签名。
3. Mac App Store Xcode Target、App Sandbox、主目录只读安全书签及撤销/重新授权源码已完成静态验证；Archive、PKG 与上传快照现会递归拒绝 `com.apple.quarantine`。仍需在完整 Xcode、正式签名的商店构建中实测授权、拒绝、书签失效、监测停止与恢复流程。
4. 隐私政策与支持页面已部署到稳定的公开 GitHub Pages URL，并于 2026-09-04 从未登录请求复核 HTTPS 200。每个候选提交前仍须重新验证并将结果绑定到候选包，同时补齐 App Store Connect 所需的法定姓名、支持邮箱等账号材料。
5. 翻译器默认地址当前指向 DeepSeek API。官方公开资料基线审计已归档，应用内分层告知、首次离机传输确认和官方政策链接已实施，公开隐私页也已同步。但公开材料未给出本下游应用 API 请求的固定保留期或不训练承诺；仍需决定是否保留默认第三方端点，并据此最终确认 App Privacy 标签。
6. iOS 与 macOS 都已有明确标识、可退出并重置的内置离线示例模式。macOS 示例仅替代 Agent 监测数据，不读本机 Agent 日志/自定义源，不访问网络或 CloudKit，且退出后不自动恢复真实监测；iOS 示例不访问 CloudKit。两者都不能替代候选签名构建的动态验收、真实生产同步或真机验证。
7. Mac producer 与 iPhone receiver 的代码契约已接通：用户明确同意后，Mac 可向其私有 CloudKit 数据库写入 `AgentIslandSnapshot/latest/payloadJSON`，iPhone 按当前 iCloud 账号读取并缓存。但正式 Developer ID entitlement/profile、生产 Container/schema 和同账号真机链路尚未验收；完成这些项目、完整 Xcode 构建和 Archive 之前，不得提交或宣传可用的跨设备监控。
8. iOS 已与 macOS 统一为 0.6.1（Build 8），但仍使用 `com.example.agentisland` 占位 Bundle ID 和空 Team ID；Widget ID 也必须随正式 App ID 注册。

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
