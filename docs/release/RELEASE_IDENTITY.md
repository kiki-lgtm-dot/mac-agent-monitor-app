# 安全应用正式 Apple 发布身份

正式 Bundle ID、Team ID 和 iCloud Container 一旦进入 Apple 后台或上传构建，后续修改成本很高。工程用 `scripts/apply-release-identity.sh` 把这组不可逆标识作为一个整体校验、应用和锁定；它不会修改产品显示名，也不会接触 `release-site`。

## 当前已锁定身份

| 字段 | 当前值 |
| --- | --- |
| `appStoreRecordMode` | `universal-purchase` |
| `macOSAppBundleIdentifier` | `com.kiki.agentisland` |
| `iOSAppBundleIdentifier` | `com.kiki.agentisland` |
| `iOSWidgetBundleIdentifier` | `com.kiki.agentisland.liveactivity` |
| `teamIdentifier` | `AW4HMBZN7M` |
| `iCloudContainerIdentifier` | `iCloud.com.kiki.agentisland` |
| `cloudKit` | `private` / `Production` / `AgentIslandSnapshot` / `latest` / `payloadJSON` |

该身份已应用并由 Git 忽略目录中的本地锁保护。Apple Developer 已生成 iOS App Store、Widget App Store、Mac App Store 与 Developer ID CloudKit 四份 profile；profile 仅存放于 Git 忽略的本地发布目录，不在本文记录绝对路径、证书、联系人或凭据。Production schema 已部署，公共数据库兜底权限仅 `_icloud` CREATE、`_creator` READ + WRITE，无 `_world` READ；应用运行时固定使用私有数据库。

对应的 App Store Connect Universal Purchase 记录名称为 `MAC版灵动岛--Agent运行监测`，App ID 为 `6808917414`，SKU 为 `AGENTISLAND-UNIVERSAL`，iOS/macOS 版本均为 `0.6.1`。App ID 与 SKU 属于提交记录引用，不写入 `Config/ReleaseIdentity.json`。

## 1. 身份文件只允许这些字段

以下复制步骤仅用于尚未建立身份的新 checkout；当前仓库不得用另一套值重新应用：

```bash
cp Config/ReleaseIdentity.example.json Config/ReleaseIdentity.json
```

允许的顶层字段只有：

- `schemaVersion`，新配置必须为 `2`；旧版 `1` 仅按“Mac/iPhone 共用主 App ID”的原始含义兼容，并在校验时规范化为 v2 Universal Purchase；
- `appStoreRecordMode`，只能是 `universal-purchase` 或 `separate-records`；
- `macOSAppBundleIdentifier`，macOS App 的正式 Bundle ID；
- `iOSAppBundleIdentifier`，iPhone App 的正式 Bundle ID；Universal Purchase 时必须与 macOS 相同，分开记录时必须不同；
- `iOSWidgetBundleIdentifier`，必须严格等于 iPhone App Bundle ID 加 `.liveactivity`；
- `teamIdentifier`，Apple Developer 中显示的 10 位大写 Team ID；
- `iCloudContainerIdentifier`，已经或准备在同一 Team 注册的正式容器；
- `cloudKit`，必须保持固定的 `private` / `Production` / `AgentIslandSnapshot` / `latest` / `payloadJSON` 契约。

产品名称、法定姓名、Apple ID、密码、App 专用密码、API Key、notarytool profile、证书或私钥都不是这个文件的字段。脚本会拒绝未知字段、秘密形态的字段和值、占位命名、Widget 偏差和 CloudKit 契约偏差。

## 2. 默认检查不写工程

```bash
./scripts/apply-release-identity.sh
```

省略模式时就是 `--check`。输出 JSON 会列出计划修改项、锁状态和 profile 状态；`writesPerformed` 必须为 `false`。检查模式只使用系统临时目录，不会创建 `.release`，也不会修改 plist 或 xcconfig。

新环境仅在确认 Apple 后台中的 macOS App ID、iPhone App ID、Widget App ID、记录模式、Team 和 Container 拼写一致后，才运行：

```bash
./scripts/apply-release-identity.sh --apply
```

第一次应用会在写入前保存：

```text
.release/identity-backup/manifest.json
.release/identity-backup/Resources/Info.plist
.release/identity-backup/ApplePlatforms/iOS/Config/Project.xcconfig
.release/identity-backup/ApplePlatforms/macOS/Config/Project.xcconfig
```

然后只更新 Mac `CFBundleIdentifier`、macOS xcconfig 中独立的 `AGENT_ISLAND_MAC_APP_BUNDLE_ID`，以及 iOS xcconfig 中的 App、Widget、Team、Container 设置，并生成 `.release/identity.lock.json`。Mac Xcode Target 绑定 macOS 专用宏，不会在 `separate-records` 模式下误用 iPhone Bundle ID。重复应用相同身份不会改变目标内容、首次备份或锁内容。锁存在后，脚本拒绝把工程切到另一套不可逆标识。

需要恢复第一次应用前的工程时，先停止构建和 Xcode，再把备份中的三个文件按原相对路径复制回去。随后把 `.release/identity.lock.json` 和可能存在的 `.release/CloudKit.entitlements` 移到工程外保留审计，不要在没有检查备份哈希的情况下直接删除。`manifest.json` 记录了原文件 SHA-256 和原本不存在的生成文件。一次 `--apply` 中如果后面的原子替换失败，脚本还会自动恢复本次事务里已经替换的前置文件；永久基线备份仍会保留。

旧脚本生成的 v1 锁若尚未管理 macOS xcconfig，首次用新版 `--apply` 时会额外创建 `.release/identity-backup/schema-v2-macos-config/` 补充基线，并把 macOS 配置哈希加入锁；之后再次应用才是内容与锁均不变的 no-op。

## 3. App ID Prefix 只能来自正式 profile

Team ID 不一定等于 App ID Prefix。没有正式 Developer ID provisioning profile 时，第一次 `--apply` 仍可以锁定已确认的 Bundle/Team/Container，但它会保持：

```text
provisioningProfile: null
generatedEntitlements: null
```

并且不会创建 `.release/CloudKit.entitlements`。

当前 Developer ID CloudKit profile 已生成、验签并应用，本机 Git 忽略目录已生成 `.release/CloudKit.entitlements`。在其他机器重建或重新复核时，带 profile 的任何命令都必须指定一个隔离的受控钥匙串：

```bash
export AGENT_ISLAND_CMS_KEYCHAIN="/absolute/path/AgentIslandRelease.keychain-db"
export AGENT_ISLAND_SIGNING_KEYCHAIN="$AGENT_ISLAND_CMS_KEYCHAIN"
./scripts/apply-release-identity.sh --check \
  --profile /absolute/path/AgentIsland_Developer_ID.provisionprofile
```

钥匙串文件必须是当前用户拥有、权限 `0600`、非符号链接、已解锁的绝对路径。建议用本地包装器在命令前解锁并置于搜索首位，命令后恢复搜索顺序并重新锁定。此要求适用于真实 profile 的验证、Archive 和提交预检；不带 profile 的本地预览或模拟器构建不需要它。

脚本要求 profile 是单签名且状态为 `GoodSignature` 的 Apple CMS、属于同一 Team，并要求 profile 顶层 `ApplicationIdentifierPrefix` 与 entitlement 中的 `com.apple.application-identifier` 精确组成 `前缀.macOSAppBundleIdentifier`；profile 必须授权目标 CloudKit Container 和 Production 环境，可同时包含 Apple 签发的更宽 profile-only 授权，但不得开启 `get-task-allow`，必须 `ProvisionsAllDevices=true` 且未过期。脚本不会假设 App ID Prefix 等于 Team ID。通过后再应用：

```bash
./scripts/apply-release-identity.sh --apply \
  --profile /absolute/path/AgentIsland_Developer_ID.provisionprofile
```

此时才会从 profile 的 `com.apple.application-identifier` 取得完整 App ID 和前缀，生成：

```text
.release/CloudKit.entitlements
.release/identity.lock.json
```

锁只记录 profile 的 SHA-256、UUID、名称、到期日、完整 App ID 和前缀，不记录本机 profile 路径，也不记录任何公证或账号凭据。

## 4. 接入发布命令

正式公证前，将安全身份与凭据分别传给原有发布脚本：

```bash
export AGENT_ISLAND_APP_STORE_RECORD_MODE="universal-purchase"
export AGENT_ISLAND_BUNDLE_ID="com.kiki.agentisland"
export AGENT_ISLAND_IOS_BUNDLE_ID="com.kiki.agentisland"
export AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID="com.kiki.agentisland.liveactivity"
export AGENT_ISLAND_DEVELOPMENT_TEAM="AW4HMBZN7M"
export AGENT_ISLAND_ICLOUD_CONTAINER_ID="iCloud.com.kiki.agentisland"
export AGENT_ISLAND_DISPLAY_NAME="MAC版灵动岛--Agent运行监测"
export AGENT_ISLAND_ENTITLEMENTS="$PWD/.release/CloudKit.entitlements"
export AGENT_ISLAND_PROVISIONING_PROFILE="/absolute/path/AgentIsland_Developer_ID.provisionprofile"
# 必需：profile CMS 验签与签名身份解析使用同一受控钥匙串。
export AGENT_ISLAND_CMS_KEYCHAIN="/absolute/path/AgentIslandRelease.keychain-db"
export AGENT_ISLAND_SIGNING_KEYCHAIN="/absolute/path/AgentIslandRelease.keychain-db"
```

版本、Build、公开隐私/支持 URL、Developer ID 签名身份和 Keychain 中的 notarytool profile 继续按 `Config/Release.example.env` 设置。当前名称已用于 App Store Connect 记录，但仍须独立完成商标规范核验。密码、App 专用密码、API Key、证书私钥和 App Store Connect API 私钥始终只进入系统 Keychain、权限锁定的本地密钥存储或受控 CI Secret，不进入身份 JSON、锁、Git 或构建日志。

如果同一证书同时存在于登录钥匙串和独立发布钥匙串，发布脚本会按“证书 SHA-1 + 完整身份名”去重；相同名称但不同 SHA-1 的证书仍会保留为歧义并失败关闭。`AGENT_ISLAND_CMS_KEYCHAIN` 与 `AGENT_ISLAND_SIGNING_KEYCHAIN` 只指定受控范围，不负责解锁或改变系统搜索顺序；本地/CI 包装器必须在命令开始前解锁该钥匙串并将其临时置于搜索首位，在命令结束后恢复原顺序并重新锁定。CMS 帮助器不会回退到默认或登录钥匙串。

当前门禁还会将同一份不可变 CMS 快照中的实际单一 signer 绑定到经复核的 Apple iPhone OS / Mac OS X Provisioning Profile Signing 叶证书 SHA-256。OpenSSL 只用于二次验证 CMS 内容签名并提取该实际 signer，不代替 Security.framework 的信任判定。这两张当前叶证书均在 2030 年到期；Apple 轮换签名证书后，脚本会按设计失败关闭。维护者必须从 Apple 官方新 profile 提取新证书、独立复核主体/颁发者/指纹并补充负例测试，不得通过移除 allowlist 恢复发布。
