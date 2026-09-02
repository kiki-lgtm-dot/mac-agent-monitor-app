# MAC版灵动岛--Agent运行监测 上线材料索引

> 状态：草案。生成日期：2026-09-01。以下文件不能在保留占位符的情况下直接发布或提交 App Review。

本目录以 MAC版灵动岛--Agent运行监测 0.6.1（Build 8）的 macOS 实现和 `ApplePlatforms/iOS` 中的 iPhone 伴侣工程为准，覆盖 macOS 直接分发、Mac App Store、iOS App Store 与 TestFlight 准备。仓库现已包含 Mac CloudKit 隐私化快照 producer、SwiftUI iPhone 看板、Widget/Live Activity Extension、按 iCloud 账号隔离的私有 CloudKit receiver/离线缓存、App 与 Widget 独立 Privacy Manifest、可直接打开的 Xcode 工程、App Icon 和只归档/可选导出但不上传的 `scripts/release-ios.sh`，且 producer 的本地 CLI/回归验证已通过。但正式 Team/Bundle/Container ID、Mac 端真实 Developer ID CloudKit entitlement 与 provisioning profile、Production schema、同一 iCloud 账号的 Mac→iPhone 真机验证、完整 Xcode+iOS SDK 编译及可提交 Archive 仍未完成，因此不能宣称当前同步已具备上线条件。

## 文件

- `PRIVACY_POLICY_ZH.md`：简体中文隐私政策草案。
- `PRIVACY_POLICY_EN.md`：英文隐私政策草案。
- `APP_STORE_METADATA.md`：Mac App Store 中英文元数据。
- `APP_REVIEW_NOTES.md`：macOS 审核说明及审核路径。
- `IOS_APP_STORE_AND_TESTFLIGHT_METADATA.md`：iOS App Store 与 TestFlight 中英文元数据。
- `IOS_APP_REVIEW_NOTES.md`：iOS 审核说明、数据边界和演示路径。
- `IOS_SCREENSHOT_CHECKLIST.md`：iPhone、锁屏实时活动和灵动岛截图清单。
- `DATA_HANDLING_AND_PRIVACY_LABELS.md`：数据处理清单、App Privacy 标签建议和 Privacy Manifest 审计项。
- `DEEPSEEK_TRANSLATION_PRIVACY_AUDIT.md`：DeepSeek 默认翻译端点的官方公开资料、代码核对、数据地区/保留/训练边界和建议的分层告知文案。
- `RELEASE_IDENTITY.md`：正式 Bundle/Team/Container 的只读检查、首次可恢复应用、身份锁和 profile 派生 entitlement 流程。
- `RELEASE_CHECKLIST.md`：从当前开发构建到公开上线的检查清单。

## 必须替换的占位符

发布前全文搜索 `[`，逐项替换或删除：

- `[开发者法定姓名]` / `[Developer Legal Name]`
- `[支持邮箱]` / `[Support Email]`
- `[隐私政策URL]` / `[Privacy Policy URL]`
- `[支持URL]` / `[Support URL]`
- `[营销URL，可选]` / `[Marketing URL, optional]`
- `[正式Bundle ID]`、`[SKU]`、`[版权所有者]`
- `[正式iOS Bundle ID]`、`[正式iOS Widget Bundle ID]`、`[正式iCloud Container ID]`、`[iOS SKU]`
- `[TestFlight反馈邮箱]` 与 iOS/macOS 审核联系人、演示数据说明
- `[生效日期：YYYY-MM-DD]` / `[Effective Date: YYYY-MM-DD]`
- 审核所需的测试文件、翻译端点和临时凭据占位符

不得编造公司名称、网址、邮箱、电话、地址或组织身份。个人开发者应填写 Apple Developer 账号对应的法定个人姓名。

## 当前上线阻断项

1. 当前 Bundle ID 为开发占位值 `local.agentisland.desktop`，构建采用 ad-hoc 签名。
2. Mac App Store 要求 App Sandbox；当前应用直接读取 `~/.codex`、`~/.claude` 等目录，必须改为用户明确选择并授权目录的沙盒数据源流程。
3. 隐私政策与支持页面尚无可公开访问的正式 URL。
4. 翻译器默认地址当前指向 DeepSeek API。官方公开资料基线审计已归档，技术接入符合当前文档；但公开材料未给出本下游应用 API 请求的固定保留期或不训练承诺。仍需决定是否保留默认第三方端点，实施应用内分层告知，并据此最终确认 App Privacy 标签。
5. 没有可供审核人员在无本地 Agent 日志时使用的内置演示模式或已准备好的无敏感测试 JSONL。
6. Mac producer 与 iPhone receiver 的代码契约已接通：用户明确同意后，Mac 可向其私有 CloudKit 数据库写入 `AgentIslandSnapshot/latest/payloadJSON`，iPhone 按当前 iCloud 账号读取并缓存。但正式 Developer ID entitlement/profile、生产 Container/schema 和同账号真机链路尚未验收；完成这些项目、完整 Xcode 构建和 Archive 之前，不得提交或宣传可用的跨设备监控。
7. iOS 配置仍使用 `com.example.agentisland` 占位 Bundle ID、空 Team ID 和 0.1.0（Build 1）；Widget ID 也必须随正式 App ID 注册。

## 官方核对入口

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App Store Connect 元数据字段](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [App Privacy 填写说明](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Privacy Manifest](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [iPhone 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [TestFlight 概览](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)

Apple 的要求会更新。每次正式提交前，应重新核对上述官方页面和 App Store Connect 当时显示的字段。
