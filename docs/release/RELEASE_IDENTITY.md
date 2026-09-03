# 安全应用正式 Apple 发布身份

正式 Bundle ID、Team ID 和 iCloud Container 一旦进入 Apple 后台或上传构建，后续修改成本很高。工程用 `scripts/apply-release-identity.sh` 把这组不可逆标识作为一个整体校验、应用和锁定；它不会修改产品显示名，也不会接触 `release-site`。

## 1. 身份文件只允许这些字段

复制示例，但先不要运行 `--apply`：

```bash
cp Config/ReleaseIdentity.example.json Config/ReleaseIdentity.json
```

允许的顶层字段只有：

- `schemaVersion`，当前必须为 `1`；
- `primaryBundleIdentifier`，Mac 与 iPhone 主 App 共用的正式 Bundle ID；
- `widgetBundleIdentifier`，必须严格等于主 Bundle ID 加 `.liveactivity`；
- `teamIdentifier`，Apple Developer 中显示的 10 位大写 Team ID；
- `iCloudContainerIdentifier`，已经或准备在同一 Team 注册的正式容器；
- `cloudKit`，必须保持固定的 `private` / `Production` / `AgentIslandSnapshot` / `latest` / `payloadJSON` 契约。

产品名称、法定姓名、Apple ID、密码、App 专用密码、API Key、notarytool profile、证书或私钥都不是这个文件的字段。脚本会拒绝未知字段、秘密形态的字段和值、占位命名、Widget 偏差和 CloudKit 契约偏差。

## 2. 默认检查不写工程

```bash
./scripts/apply-release-identity.sh
```

省略模式时就是 `--check`。输出 JSON 会列出计划修改项、锁状态和 profile 状态；`writesPerformed` 必须为 `false`。检查模式只使用系统临时目录，不会创建 `.release`，也不会修改 plist 或 xcconfig。

确认 Apple 后台中的主 App ID、Widget App ID、Team 和 Container 拼写一致后，才运行：

```bash
./scripts/apply-release-identity.sh --apply
```

第一次应用会在写入前保存：

```text
.release/identity-backup/manifest.json
.release/identity-backup/Resources/Info.plist
.release/identity-backup/ApplePlatforms/iOS/Config/Project.xcconfig
```

然后只更新 Mac `CFBundleIdentifier` 和 iOS xcconfig 中的 App、Widget、Team、Container 设置，并生成 `.release/identity.lock.json`。重复应用相同身份不会改变目标内容、首次备份或锁内容。锁存在后，脚本拒绝把工程切到另一套不可逆标识。

需要恢复第一次应用前的工程时，先停止构建和 Xcode，再把备份中的两个文件按原相对路径复制回去。随后把 `.release/identity.lock.json` 和可能存在的 `.release/CloudKit.entitlements` 移到工程外保留审计，不要在没有检查备份哈希的情况下直接删除。`manifest.json` 记录了原文件 SHA-256 和原本不存在的生成文件。

## 3. App ID Prefix 只能来自正式 profile

Team ID 不一定等于 App ID Prefix。没有正式 Developer ID provisioning profile 时，第一次 `--apply` 仍可以锁定已确认的 Bundle/Team/Container，但它会保持：

```text
provisioningProfile: null
generatedEntitlements: null
```

并且不会创建 `.release/CloudKit.entitlements`。

在 Apple Developer 后台为正式 macOS App ID 启用 CloudKit、只绑定身份文件中的 Container，并下载未过期的 Developer ID provisioning profile 后，先检查：

```bash
./scripts/apply-release-identity.sh --check \
  --profile /absolute/path/AgentIsland_Developer_ID.provisionprofile
```

脚本要求 profile 是 Apple 签名 CMS、属于同一 Team、包含精确主 Bundle ID、只授权指定 CloudKit Container、环境为 Production、`ProvisionsAllDevices=true`、未开启 `get-task-allow` 且未过期。通过后再应用：

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
export AGENT_ISLAND_BUNDLE_ID="已锁定的 primaryBundleIdentifier"
export AGENT_ISLAND_IOS_BUNDLE_ID="$AGENT_ISLAND_BUNDLE_ID"
export AGENT_ISLAND_IOS_WIDGET_BUNDLE_ID="$AGENT_ISLAND_BUNDLE_ID.liveactivity"
export AGENT_ISLAND_DEVELOPMENT_TEAM="已锁定的 teamIdentifier"
export AGENT_ISLAND_ICLOUD_CONTAINER_ID="已锁定的 iCloudContainerIdentifier"
export AGENT_ISLAND_DISPLAY_NAME="已完成名称清查的 2–30 字符正式名称"
export AGENT_ISLAND_ENTITLEMENTS="$PWD/.release/CloudKit.entitlements"
export AGENT_ISLAND_PROVISIONING_PROFILE="/absolute/path/AgentIsland_Developer_ID.provisionprofile"
```

正式显示名、版本、Build、公开隐私/支持 URL、Developer ID 签名身份和 Keychain 中的 notarytool profile 继续按 `Config/Release.example.env` 设置。显示名只在已完成名称清查后配置；当前公开名称虽然通过字数门禁，仍须另行完成 App Store 可用性与 Apple 商标规范核验。密码、App 专用密码、API Key、证书私钥和 App Store Connect API 私钥始终只进入系统 Keychain 或受控 CI Secret，不进入身份 JSON、锁或构建日志。
