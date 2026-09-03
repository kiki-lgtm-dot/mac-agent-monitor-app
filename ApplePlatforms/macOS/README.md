# macOS App Store 发布工程

`AgentIslandMac.xcodeproj` 是「MAC版灵动岛--Agent运行监测」的 Mac App Store Target。它与直接下载版使用同一份 Objective-C/Web 源码，但发布管道不同：

- `scripts/release-macos.sh` 是 Developer ID 直接分发、公证与 stapling 流程；
- `ApplePlatforms/macOS/scripts/release-macos-app-store.sh` 是 Mac App Store Archive/本地导出流程，**不上传、不提交审核、不运行 notarytool**。

## 先准备 Apple 签名资产

开始前必须满足：

1. 安装并选中完整 Xcode 26 或更新版（仅 Command Line Tools 不足够）。
2. 在 Apple Developer 后台注册最终 Mac App ID，为它开启 CloudKit，并仅绑定本项目的 Production Container。
3. 用 `scripts/apply-release-identity.sh` 将已确认的 Bundle ID、Team ID 和 Container 应用到工程；不要临时在命令中猜测这些值。
4. 在 Keychain 中安装同一 Team 的 `Apple Distribution` 或旧版 `3rd Party Mac Developer Application` 证书。
5. 准备未过期、非设备限定、非 `ProvisionsAllDevices` 的 Mac App Store provisioning profile。它必须包含本次使用的分发证书。
6. 如果要导出 `.pkg`，还要安装同 Team 的 `Mac Installer Distribution` 或旧版 `3rd Party Mac Developer Installer` 证书。
7. 确定 App Store 中使用的最终版权文字。Apple 要求 macOS 应用在 `Info.plist` 包含 `NSHumanReadableCopyright`，所以脚本不会为你编造法定姓名或版权主体。

## 本地生成 Archive

先在当前 shell 中设置真实的最终版权文字：

```bash
export AGENT_ISLAND_MAC_APP_STORE_COPYRIGHT="© <年份> <Apple Developer 账号对应的法定姓名>. All rights reserved."
```

上面的尖括号是待填项，不能照抄后发布。然后运行：

```bash
./ApplePlatforms/macOS/scripts/release-macos-app-store.sh
```

默认只使用已安装的证书和 profile，不授权 Xcode 修改签名资产。如果你已在 Xcode 登录正确账号，并且愿意让 Xcode 联系 Apple 以创建或更新 provisioning profile，显式加上：

```bash
./ApplePlatforms/macOS/scripts/release-macos-app-store.sh \
  --allow-provisioning-updates
```

`--allow-provisioning-updates` 可能更新 Apple 账号下的签名资产，但不会上传应用构建。

## 可选：导出本地 App Store Package

```bash
./ApplePlatforms/macOS/scripts/release-macos-app-store.sh --export
```

需要 Xcode 自动管理签名时：

```bash
./ApplePlatforms/macOS/scripts/release-macos-app-store.sh \
  --export \
  --allow-provisioning-updates
```

`--export` 只使用 `app-store-connect` + `destination=export` 生成本地 `.pkg`。脚本不接受 App Store Connect 私钥、Apple ID 或 App 专用密码，也没有 upload 动作。

如果同一 Team 在 Keychain 中有多张同类证书，脚本会停止，而不是随机选择。只能把 `security find-identity` 中的完整证书名称原样传入：

```bash
export AGENT_ISLAND_MAC_APP_STORE_DISTRIBUTION_IDENTITY="<Keychain 中的完整 App Distribution 身份>"
export AGENT_ISLAND_MAC_APP_STORE_INSTALLER_IDENTITY="<Keychain 中的完整 Installer Distribution 身份>"
```

不要将证书、私钥、Apple 密码或 App Store Connect API Key 写入仓库。

## 脚本实际验证什么

所有中间产物先放入 `dist/macos-app-store` 的隐藏临时目录。以下检查全部通过后，它才会原子地改名为 `<Version>-<Build>-<UTC 时间>`：

- Xcode Release 设置中的正式 Bundle ID、10 位 Team ID、显示名、Production CloudKit Container、HTTPS 隐私/支持 URL 和版权文字；
- Archive 只包含一个 App，其二进制同时包含 `arm64` 与 `x86_64`；
- 代码签名属于指定 Team，启用 Hardened Runtime，且签名证书确实在嵌入 profile 的 `DeveloperCertificates` 中；
- profile 不是 Development/Developer ID 类型，未过期，App ID Prefix、Team、Bundle ID 与 Production CloudKit 权限和签名一致；
- App Sandbox、用户选择目录只读、App Scope Bookmark、Network Client 与 CloudKit 权限完整，`get-task-allow` 未开启；
- Privacy Manifest、图标、开源声明和 Web UI 已入包，不含源码、测试 fixture、Apple 私钥/证书文件或 Finder 垃圾数据；
- `.xcarchive.zip` 结构与 ZIP 完整性正确，并生成 SHA-256；
- 导出 `.pkg` 时，Installer 签名受信任，解出的 App 再次通过相同内容、权限和 profile 检查，并产生独立 SHA-256。

每个发布目录包含：

```text
AgentIslandMac.xcarchive
AgentIslandMac.xcarchive.zip
AgentIslandMac.xcarchive.zip.sha256
AgentIslandMac-archive.xcresult
release-metadata.json
export/                         # 仅 --export 时存在
```

`release-metadata.json` 明确记录 `uploaded: false`、候选包哈希、签名身份、profile UUID/到期日和重要发布设置，方便将隐私证据与同一个未改动的候选包绑定。

## 导出后仍需人工完成

脚本成功不等于可以提审。对同一个未改动候选包，还要：

1. 将 `AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA` 指向该目录的 `release-metadata.json`，运行 `scripts/release-readiness.sh --json`。readiness 会要求 metadata 中的 `version`/`build` 与当前 macOS Target 的 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 一致，并重新计算 Archive ZIP 与 PKG 哈希；只有全部相符才输出 `macAppStoreExactCandidateEvidenceReady: true`。
2. 在 Xcode Organizer 生成并审查 Privacy Report，处理全部 validation 警告。
3. 用真实签名包验证首次启动、拒绝/撤销/书签失效后恢复、离线示例隔离以及无活跃 Agent 的空状态。
4. 完成 Production CloudKit schema 部署和同 iCloud 账号的 Mac→iPhone 真机检查。
5. 用 `AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_ARCHIVE_SHA256` 和 `AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_EVIDENCE_PACKAGE_SHA256` 将五项 QA 开关、App Privacy、截图、Review Notes 与审核联系人证据绑定到这一个候选包；两个哈希不同时匹配时，五项 `...VERIFIED` 在报告中会全部保持 `false`。
6. 只有 `readyForMacAppStoreUpload: true` 才表示该本地候选包通过上传前门槛。当前工程没有 macOS 上传、App Store Connect 处理与审核交付证据链，因此已废弃的兼容字段 `readyForFunctionalMacAppStoreSubmission` 会保持 `false`，报告同时输出 `readyForFunctionalMacAppStoreSubmissionDeprecated: true`；不得将本地 `uploaded: false` 冒充为可提审。
7. 确认 `release-metadata.json` 仍为 `uploaded: false` 后，再由你在 Xcode Organizer 或 Apple 支持的上传工具中明确执行上传。

运行本流程的专用回归检查：

```bash
./Tests/test-macos-app-store-release.sh
```

Apple 的 Xcode 与提交要求会更新。每次候选版构建前，重新核对 [Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)、[Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/) 和 [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。
