# macOS App Store 发布工程

`AgentIslandMac.xcodeproj` 是「MAC版灵动岛--Agent运行监测」的 Mac App Store Target。它与直接下载版使用同一份 Objective-C/Web 源码，但发布管道不同：

- `scripts/release-macos.sh` 是 Developer ID 直接分发、公证与 stapling 流程；
- `ApplePlatforms/macOS/scripts/release-macos-app-store.sh` 是 Mac App Store Archive/本地导出流程，**不上传、不提交审核、不运行 notarytool**。
- `ApplePlatforms/macOS/scripts/submit-macos-app-store.sh` 独立复验并可显式验证/上传同一个 `.pkg`；
- `ApplePlatforms/macOS/scripts/confirm-functional-qa-evidence.sh` 将五项实机 QA 与精确 Archive ZIP + PKG 绑定为只读、不覆盖证据；
- `ApplePlatforms/macOS/scripts/validate-functional-qa-evidence.sh` 本地复验 QA 记录、五份附件和精确候选；
- `ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh` 独立重验上传交付链，并可输出供 readiness 使用的 JSON；
- `ApplePlatforms/macOS/scripts/confirm-macos-app-store-evidence.sh` 在人工核对 Apple 处理结果后生成只读证据，**不访问或修改 App Store Connect**。
- `ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh` 独立重验处理证据，并可输出供 readiness 使用的 JSON。

## 先准备 Apple 签名资产

当前已锁定 Universal Purchase 生产身份：macOS/iOS 主应用为
`com.kiki.agentisland`，Team 为 `AW4HMBZN7M`，CloudKit Container 为
`iCloud.com.kiki.agentisland`。Production Schema 已部署，Mac App Store 与
Developer ID CloudKit Profile 已生成；下列各项仍是正式候选包的必经校验，
不代表 Archive 或上传已完成。

开始前必须满足：

1. 安装并选中完整 Xcode 14 或更新版（仅 Command Line Tools 不足够）。Apple 的 2026 通用上传门槛是 Xcode 14+；Xcode 26 + 26 SDK 的 Upcoming Requirements 条款列出了 iOS/iPadOS/tvOS/visionOS/watchOS，未列 macOS，因此本渠道不再误设 macOS 26 SDK 或 macOS Sequoia 15.6 门槛。若同时构建 iOS 伴侣，仍须按 iOS 渠道使用 Xcode 26 + iOS 26 SDK，并满足 Xcode 26 的主机要求。
2. 复核 Apple Developer 后台已注册的 Mac App ID，确认 CloudKit 只绑定本项目的 Production Container。
3. 用 schemaVersion 2 `Config/ReleaseIdentity.json` 声明并用 `scripts/apply-release-identity.sh` 应用已确认的身份。`appStoreRecordMode=universal-purchase` 时 macOS/iOS 主 App Bundle ID 必须相同；`separate-records` 时必须不同。旧 schemaVersion 1 只能规范化为 Universal Purchase，不能表示分开记录。
4. 确认 `.release/identity.lock.json` 已锁定同一模式和标识；`AGENT_ISLAND_APP_STORE_RECORD_MODE`、`AGENT_ISLAND_BUNDLE_ID` 和 `AGENT_ISLAND_IOS_BUNDLE_ID` 必须分别等于锁中的模式、macOS App ID 和 iOS App ID。Mac Target 使用独立的 `AGENT_ISLAND_MAC_APP_BUNDLE_ID`，分开记录时不得误用 iOS App ID。
5. 在 Keychain 中安装同一 Team 的 `Apple Distribution` 或旧版 `3rd Party Mac Developer Application` 证书。
6. 准备未过期、非设备限定、非 `ProvisionsAllDevices` 的 Mac App Store provisioning profile。它必须包含本次使用的分发证书。
7. 如果要导出 `.pkg`，还要安装同 Team 的 `Mac Installer Distribution` 或旧版 `3rd Party Mac Developer Installer` 证书。
8. 确定 App Store 中使用的最终版权文字。Apple 要求 macOS 应用在 `Info.plist` 包含 `NSHumanReadableCopyright`，所以脚本不会为你编造法定姓名或版权主体。

任何会读取真实 provisioning profile 的 Archive、导出或提交预检都必须在隔离的受控钥匙串中运行。钥匙串必须是当前用户拥有、权限 `0600`、非符号链接、已解锁的绝对路径；命令结束后应重新锁定。本地包装器或 CI 应设置：

```bash
export AGENT_ISLAND_CMS_KEYCHAIN="/absolute/path/AgentIslandRelease.keychain-db"
export AGENT_ISLAND_SIGNING_KEYCHAIN="$AGENT_ISLAND_CMS_KEYCHAIN"
```

CMS 验签不会回退到默认/`login` 钥匙串，也不接受未验证的 OpenSSL 解码作为替代。不带 profile 的本地预览构建不受此限制。

实际 Archive 入口会重新生成 `release-readiness.sh --json` 报告，并以 `mac-app-store` 档案门禁校验 identity lock、已应用配置、Xcode 工程/资源/权限和当前 Mac 工具链。只有在文档中勾选、但报告未通过时，脚本不会开始 Archive。

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

`--export` 使用 Xcode 14 对应的 `app-store`，或 Xcode 15 及以上对应的 `app-store-connect`，并固定 `destination=export` 生成本地 `.pkg`。脚本会在 metadata 中记录实际方法，后续复验会按记录的 Xcode 大版本拒绝不匹配的方法。脚本不接受 App Store Connect 私钥、Apple ID 或 App 专用密码，也没有 upload 动作。

如果同一 Team 在 Keychain 中有多张同类证书，脚本会停止，而不是随机选择。只能把 `security find-identity` 中的完整证书名称原样传入：

```bash
export AGENT_ISLAND_MAC_APP_STORE_DISTRIBUTION_IDENTITY="<Keychain 中的完整 App Distribution 身份>"
export AGENT_ISLAND_MAC_APP_STORE_INSTALLER_IDENTITY="<Keychain 中的完整 Installer Distribution 身份>"
```

不要将证书、私钥、Apple 密码或 App Store Connect API Key 写入仓库。

## 脚本实际验证什么

所有中间产物先放入 `dist/macos-app-store` 的隐藏临时目录。以下检查全部通过后，它才会原子地改名为 `<Version>-<Build>-<UTC 时间>`：

- Xcode Release 设置中的正式 Bundle ID、10 位 Team ID、显示名、Production CloudKit Container、HTTPS 隐私/支持 URL 和版权文字；
- Archive 与导出包的 `LSApplicationCategoryType` 必须为 `public.app-category.developer-tools`，并与 App Store Connect 主类别 “Developer Tools” 保持一致；
- Archive 只包含一个 App，其二进制同时包含 `arm64` 与 `x86_64`；
- 代码签名属于指定 Team，启用 Hardened Runtime，且签名证书确实在嵌入 profile 的 `DeveloperCertificates` 中；
- profile 不是 Development/Developer ID 类型，未过期，App ID Prefix、Team、Bundle ID 与 Production CloudKit 权限和签名一致；
- App Sandbox、用户选择目录只读、App Scope Bookmark、Network Client 与 CloudKit 权限完整，`get-task-allow` 未开启；
- Privacy Manifest、图标、开源声明和 Web UI 已入包，不含源码、测试 fixture、Apple 私钥/证书文件或 Finder 垃圾数据；Archive、导出 PKG 及其中 App 还会只读检查并拒绝任何 `com.apple.quarantine`，不会在签名后静默清除；
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

## 精确复验、验证与上传

任何联网操作前，先对发布目录运行完全离线的独立复验：

```bash
./ApplePlatforms/macOS/scripts/submit-macos-app-store.sh --check \
  dist/macos-app-store/<版本-构建-时间>
```

它不会信任 `release-metadata.json` 中的结论：会重新计算 Archive ZIP 与 PKG 哈希、检查 checksum sidecar、确认当前 Archive 与该 ZIP 完全一致、展开 PKG，并分别复验 Archive/PKG 内 App 的 Bundle ID、版本、分类、资源、双架构、签名证书、Installer 证书、profile、Sandbox/CloudKit 权限、Privacy Manifest 和递归 quarantine 属性。上传前的私有 PKG 快照还会再次检查 `com.apple.quarantine`；发现后停止并要求从干净输入重建，不会改写已签名候选。两份 App 的非签名内容与去签名后的可执行代码也必须一致。通过后会打印：

```text
<Bundle ID>:<Version>:<Build>:<PKG SHA-256>
```

### 记录精确候选的功能 QA

对上述本地复验通过的同一候选完成五项检查，并将五份已脱敏报告保存在候选发布目录中：

```bash
export AGENT_ISLAND_CONFIRM_MAC_APP_STORE_FUNCTIONAL_QA="<Bundle ID>:<Version>:<Build>:<Archive ZIP SHA-256>:<PKG SHA-256>"

./ApplePlatforms/macOS/scripts/confirm-functional-qa-evidence.sh \
  --mac-model "<Mac 型号>" \
  --macos-version "<macOS 版本，例如 15.6.1>" \
  --tested-at "<UTC 时间，例如 2026-09-04T12:00:00Z>" \
  --sandbox-flow-result passed \
  --sandbox-flow-evidence "$PWD/dist/macos-app-store/<版本-构建-时间>/qa-sandbox.md" \
  --archive-install-launch-quit-result passed \
  --archive-install-launch-quit-evidence "$PWD/dist/macos-app-store/<版本-构建-时间>/qa-install.md" \
  --profile-certificate-result passed \
  --profile-certificate-evidence "$PWD/dist/macos-app-store/<版本-构建-时间>/qa-profile.md" \
  --privacy-report-result passed \
  --privacy-report-evidence "$PWD/dist/macos-app-store/<版本-构建-时间>/qa-privacy.pdf" \
  --review-path-result passed \
  --review-path-evidence "$PWD/dist/macos-app-store/<版本-构建-时间>/qa-review.md" \
  "$PWD/dist/macos-app-store/<版本-构建-时间>/release-metadata.json"
```

五项分别覆盖：沙盒授权/拒绝/撤销/恢复；Archive/PKG 安装、启动和退出；profile 与实际签名证书；Xcode Privacy Report；审核示例和生产路径。五个 result 必须是 literal `passed`。五份附件必须是发布目录内的绝对、规范、非符号链接路径，而且路径、device+inode 和内容 SHA-256 都必须两两不同；不能把 metadata、Archive ZIP、PKG 或其他核心发布证据当作 QA 附件。

生成器原子创建 `macos-functional-verification-*.json`、拒绝覆盖并移除写权限。这是只读/不覆盖证据，不是由文件系统强制的不可变存储。可以再次独立复验：

```bash
./ApplePlatforms/macOS/scripts/validate-functional-qa-evidence.sh --json \
  --expected-release-metadata "$PWD/dist/macos-app-store/<版本-构建-时间>/release-metadata.json" \
  --expected-archive-sha256 "<Archive ZIP SHA-256>" \
  --expected-package-sha256 "<PKG SHA-256>" \
  "$PWD/dist/macos-app-store/<版本-构建-时间>/macos-functional-verification-<时间>.json"

export AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE="$PWD/dist/macos-app-store/<版本-构建-时间>/macos-functional-verification-<时间>.json"
```

生成器和验证器都会重新运行 `submit-macos-app-store.sh --check`。它们只读本地文件，不上传、不回查 Apple、不选择 Build，也不提交 App Review。

只联系 Apple 做远程验证，不上传：

```bash
export AGENT_ISLAND_ASC_API_KEY_ID="<10 位 Key ID>"
export AGENT_ISLAND_ASC_API_ISSUER_ID="<Issuer UUID>"

./ApplePlatforms/macOS/scripts/submit-macos-app-store.sh --validate \
  dist/macos-app-store/<版本-构建-时间>
```

私钥只能放在 `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`，权限须为 `0600` 或更严格。不要把私钥、Key ID 或 Issuer ID 写进仓库。

真正上传是显式的外部状态变更。复制本次 `--check` 打印的完整确认值后再运行：

```bash
export AGENT_ISLAND_CONFIRM_MAC_APP_STORE_UPLOAD="<Bundle ID>:<Version>:<Build>:<PKG SHA-256>"

./ApplePlatforms/macOS/scripts/submit-macos-app-store.sh --upload \
  dist/macos-app-store/<版本-构建-时间>
```

脚本先复验本地候选，再验证并上传同一个 PKG。validation 结果、upload 结果和 `mac-app-store-delivery-*.json` 使用不可覆盖的时间戳文件名并设为只读；原始 `release-metadata.json` 仍保持 `uploaded: false`，因为它描述的是本地构建，不应被回写成远端状态。

`uploadAccepted: true` **只表示上传命令被接受**。新 delivery record 会明确保持 `processingState: null`、`processingVerified: false`、`warningsReviewed: false` 和 `submittedForAppReview: false`，不能据此宣称 Apple 已处理完成或已经提审。

可以随时对这一层“上传已接受”证据做完全离线复验：

```bash
./ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh --check \
  dist/macos-app-store/<版本-构建-时间>/mac-app-store-delivery-<时间>.json

./ApplePlatforms/macOS/scripts/verify-macos-app-store-delivery.sh --json \
  dist/macos-app-store/<版本-构建-时间>/mac-app-store-delivery-<时间>.json
```

只有当只读 delivery、metadata、Archive ZIP、PKG、validation 结果和 upload 结果的路径与 SHA-256 都一致，上传时间有效，且该精确候选包仍能通过 `submit-macos-app-store.sh --check` 时，`--json` 才会输出 `evidenceVerified: true`。证据入口和记录内所有绝对路径都必须已规范化，任何经父目录符号链接绕行的路径都会被拒绝。该结果始终保持 `processingState: null`、`processingVerified: false` 和 `submittedForAppReview: false`，便于 readiness 将“可上传”、“上传已接受”和“Apple 已处理”分层判定。

将已通过复验的交付记录接入 readiness：

```bash
export AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE="$PWD/dist/macos-app-store/<版本-构建-时间>/mac-app-store-delivery-<时间>.json"
```

## 记录 Apple 处理完成证据

等待 App Store Connect 的 Build Upload 状态变为 `Complete`，打开交付详情检查全部 errors、warnings 和 information，并记下对应的 App Store Connect Build ID。然后使用同一个 delivery record：

```bash
export AGENT_ISLAND_CONFIRM_MAC_APP_STORE_PROCESSING="<Bundle ID>:<Version>:<Build>:<PKG SHA-256>:<ASC Build ID>"

./ApplePlatforms/macOS/scripts/confirm-macos-app-store-evidence.sh \
  --processing-state Complete \
  --app-store-connect-build-id "<ASC Build ID>" \
  --processing-verified-at "<UTC 时间，例如 2026-09-04T12:30:00Z>" \
  --warnings-reviewed \
  dist/macos-app-store/<版本-构建-时间>/mac-app-store-delivery-<时间>.json
```

生成器会重新计算 PKG、Archive ZIP、metadata、validation、upload 和 delivery record 的哈希，再次运行离线精确候选复验，最后原子生成只读的 `mac-app-store-processing-verification-*.json`。这是人工核对后的本地证据，不会重新查询 Apple，也不会选择版本构建或提交 App Review。

随时可独立重验这份证据；`--json` 只会在 evidence、只读 delivery/validation/upload 文件、全部哈希、时间顺序、Build ID、`Complete` 状态、警告确认和本地候选复验都通过后输出 `evidenceVerified: true`。处理完成 JSON 会携带与独立 delivery JSON 同名的 delivery、metadata、Archive ZIP、PKG、validation、upload 路径与 SHA-256，以及 Bundle ID、版本、构建号和 `submittedAt`；验证器会内部调用 delivery 验证器并逐字段交叉绑定：

```bash
./ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh --check \
  dist/macos-app-store/<版本-构建-时间>/mac-app-store-processing-verification-<时间>.json

./ApplePlatforms/macOS/scripts/verify-macos-app-store-evidence.sh --json \
  dist/macos-app-store/<版本-构建-时间>/mac-app-store-processing-verification-<时间>.json
```

将已通过复验的处理记录接入 readiness：

```bash
export AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE="$PWD/dist/macos-app-store/<版本-构建-时间>/mac-app-store-processing-verification-<时间>.json"
```

`processingState=Complete` 是操作人员看到 App Store Connect 页面后写入的本地证据。它不是实时 Apple API 回查，也不等于构建已绑定到商店版本或已提交 App Review。

## 导出后仍需人工完成

脚本成功不等于可以提审。对同一个未改动候选包，还要：

1. 将 `AGENT_ISLAND_MAC_APP_STORE_RELEASE_METADATA` 指向该目录的 `release-metadata.json`，先运行 `submit-macos-app-store.sh --check`，再运行 `scripts/release-readiness.sh --json`。readiness 会要求 metadata 中的 `version`/`build` 与当前 macOS Target 的 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 一致，并重新计算 Archive ZIP 与 PKG 哈希。
2. 在 Xcode Organizer 生成并审查 Privacy Report，处理全部 validation 警告；将 App Privacy 证据按平台、记录模式、Bundle ID、版本、Build 和候选包 SHA-256 绑定。
3. 用真实签名包完成五项 QA，并将 `confirm-functional-qa-evidence.sh` 生成的 `macos-functional-verification-*.json` 填入 `AGENT_ISLAND_MAC_APP_STORE_FUNCTIONAL_QA_EVIDENCE`。每次重新构建都必须重做 QA 和五份附件，不得手抄哈希或自由布尔值代替。
4. 生产 CloudKit Schema 已部署；仍需完成同 iCloud 账号的 Mac→iPhone 真机检查。确认 `macStoreSubmissionAssetsReady: true`；它只要求 Mac 中英文元数据、Mac 截图和两端共用的隐私/支持材料，不会因 iOS 独有素材未完成而失败。只有 `readyForMacAppStoreUpload: true` 才表示该本地候选通过上传前门禁；它不表示已经上传。
5. 需要时先执行 `--validate`，仅在核对精确四段式确认值后显式执行 `--upload`。复验 delivery record 后将它填入 `AGENT_ISLAND_MAC_APP_STORE_DELIVERY_EVIDENCE`；`uploadAccepted: true` 不等于 Apple 处理完成。
6. 上传后在 App Store Connect 人工确认该 Build 为 `Complete`，检查全部 errors/warnings/information，用 `confirm-macos-app-store-evidence.sh` 生成并复验 processing evidence，再填入 `AGENT_ISLAND_MAC_APP_STORE_PROCESSING_EVIDENCE`。这是人工观察的本地证据，不是 Apple 状态的自动回查。
7. 账号授权人在 App Store Connect 为正确 macOS version 关联该精确 Build，然后采集提交元数据快照。采集脚本只读验证这一关系，不会选择或更改 Build。
8. 生成最新 readiness 报告并运行 `../../scripts/assert-release-preflight.sh mac-app-store-review /absolute/path/readiness.json`。`readyForMacAppStoreReviewSelection: true` 且该门禁通过，表示精确 Build 关联与本地证据链已通过；它不表示已 Add for Review 或已 Submit for Review。授权人必须再次复核所有商店资料和 App Privacy，再显式执行 App Review 提交。已废弃的 `readyForFunctionalMacAppStoreSubmission` 始终保持 `false`，不得将其当作提审证据。

运行本流程的专用回归检查：

```bash
./Tests/test-macos-app-store-release.sh
./Tests/test-macos-functional-qa-evidence.sh
./Tests/test-macos-app-store-delivery.sh
```

Apple 的 Xcode 与提交要求会更新。每次候选版构建前，重新核对 [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)、[Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)、[Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)、[Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/) 和 [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。Developer ID 直接分发只按 `release-macos.sh` 实际需要检查 `clang`、`notarytool`、`stapler` 等工具，不继承 iOS 的 Xcode 26 门槛。
