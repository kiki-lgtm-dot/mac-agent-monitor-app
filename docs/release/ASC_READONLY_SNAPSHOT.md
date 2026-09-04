# App Store Connect 只读快照

这组脚本只读取 Apple 的 App Store Connect API，不创建版本、不关联或切换构建、不分发
TestFlight，也不执行 Add for Review 或 Submit for Review。它用于把短暂的远端状态绑定到
本地候选产物和 `.release/identity.lock.json`，供发布就绪检查离线消费。

官方依据：

- [生成 App Store Connect API JWT](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [List Apps](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps)
- [List Builds](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds)
- [Build processingState](https://developer.apple.com/documentation/appstoreconnectapi/build/attributes-data.dictionary)
- [Read Build Upload](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builduploads-_id_)
- [Build Upload 状态](https://developer.apple.com/documentation/appstoreconnectapi/builduploadstate)

## 安全模型

- 请求主机固定为 `https://api.appstoreconnect.apple.com`，只允许 `/v1/...`。
- HTTP 方法固定为 `GET`；代码中没有 POST、PATCH 或 DELETE 通道。
- JWT 使用 ES256，生命周期 120 秒，并把 `scope` 限制到当前 GET URL。
- 仅支持 App Store Connect **Team API key**（Key ID + Issuer ID）。不支持使用
  `sub` 声明的 Individual API key，也不会将个人密钥默认成 Team key。
- Key ID 和 Issuer ID 只从环境变量读取。私钥路径不可配置，只读取
  `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`。
- 私钥必须是非符号链接的 P-256 私钥，且 group/other 无任何权限。
- 不跟随重定向；跨域重定向单独报错。
- 每个请求 15 秒超时，单响应最多 1 MiB，一次采集最多 10 页。
- 401、403、429 分别失败，不把响应 detail、JWT 或私钥写到日志和快照。
- 私钥、候选产物、identity lock、identity 已应用文件和离线快照都使用
  `O_NOFOLLOW` 文件描述符读取，并校验 inode/长度/哈希；远端采集或离线验证
  前后还会重新检查绑定。
- 输出先在目标目录写入临时 inode、fsync、设为 `0444`，再用 hard link 原子发布；
  已存在的目标绝不覆盖。

注意：`O_NOFOLLOW` 与前后重检只能缩小本地 TOCTOU 窗口，无法替代受限写入权限
的发布机。`0444` 和 `evidenceSHA256` 只是本地完整性诊断，不是 Apple 或项目的
数字签名证明。快照包含本地绝对路径和 ASC resource IDs，必须只写入已被
`.gitignore` 排除的 `dist/` 或 `.release/`，不得提交。

## Team API key 准备

```sh
export AGENT_ISLAND_ASC_API_KEY_ID="XXXXXXXXXX"
export AGENT_ISLAND_ASC_API_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
chmod 600 "$HOME/.appstoreconnect/private_keys/AuthKey_${AGENT_ISLAND_ASC_API_KEY_ID}.p8"
```

脚本不接受 `--key-file`、`--base-url`、JWT 参数或 fixture 参数。

`--identity-lock` 虽然显式传入便于门禁诊断，但其值必须精确是当前仓库的
`$PWD/.release/identity.lock.json`。脚本会完整校验 schemaVersion 2 identity、
`appStoreRecordMode`、macOS/iOS/Widget Bundle ID、Team ID、iCloud/CloudKit 约定、
profile/entitlements 绑定，以及三个已应用配置文件的实时 SHA-256。

## App 记录快照

```sh
node scripts/capture-asc-app-snapshot.mjs \
  --bundle-id "$AGENT_ISLAND_BUNDLE_ID" \
  --artifact "$PWD/dist/ios/1.2.3-45/AgentIsland.ipa" \
  --identity-lock "$PWD/.release/identity.lock.json" \
  --output "$PWD/dist/ios/1.2.3-45/asc-app-snapshot.json"
```

远端必须恰好有一个 `bundleId` 完全相等的 App。输出的关键字段：

```json
{
  "schemaVersion": 1,
  "kind": "app-store-connect-app-snapshot",
  "readOnly": true,
  "capturedAt": "...",
  "expiresAt": "...",
  "query": { "bundleID": "..." },
  "candidate": {
    "artifactPath": "...",
    "artifactSHA256": "...",
    "artifactByteLength": 0,
    "releaseIdentityLockPath": "...",
    "releaseIdentityLockSHA256": "...",
    "releaseIdentityLockByteLength": 0
  },
  "releaseIdentity": {
    "schemaVersion": 2,
    "appStoreRecordMode": "universal-purchase",
    "macOSAppBundleIdentifier": "...",
    "iOSAppBundleIdentifier": "...",
    "iOSWidgetBundleIdentifier": "...",
    "teamIdentifier": "...",
    "iCloudContainerIdentifier": "...",
    "cloudKit": {}
  },
  "resourceIDs": { "app": "..." },
  "app": {
    "resourceID": "...",
    "bundleID": "...",
    "name": "...",
    "sku": "...",
    "primaryLocale": "..."
  },
  "requestEvidence": [],
  "readiness": {
    "candidateBindingsVerified": true,
    "appResourceUnique": true,
    "snapshotReady": true
  },
  "evidenceSHA256": "..."
}
```

## 精确 Build 快照

```sh
node scripts/capture-asc-build-snapshot.mjs \
  --bundle-id "$AGENT_ISLAND_BUNDLE_ID" \
  --platform iOS \
  --version 1.2.3 \
  --build 45 \
  --artifact "$PWD/dist/ios/1.2.3-45/AgentIsland.ipa" \
  --identity-lock "$PWD/.release/identity.lock.json" \
  --output "$PWD/dist/ios/1.2.3-45/asc-build-snapshot.json"
```

`--platform` 支持 `iOS`/`IOS` 和 `macOS`/`MAC_OS`。成功必须同时满足：

- App 的 bundle ID 唯一且完全相等；
- platform、marketing version、build number 精确匹配且只有一个 Build；
- Build 与 App、PrereleaseVersion、BuildUpload 的 resource ID 关系完整；
- Build `processingState` 为 `VALID` 且 `expired` 明确为 `false`；
- Build `buildAudienceType` 必须为 `APP_STORE_ELIGIBLE`；
- Build `usesNonExemptEncryption` 必须是明确的 boolean；
- 对应 BuildUpload 的版本、构建号、平台再次完全匹配，state 为 `COMPLETE`。

BuildUpload 的 `errors`、`warnings`、`infos` 以及完整 `rawState` 会原样进入自校验
摘要。存在 warning 会设置 `warningsPresent=true`，但不会伪装成“已人工审核
warning”。`COMPLETE` 却带有 errors 时仍保存诊断快照，但
`buildUploadErrorFree=false` 且 `snapshotReady=false`。

`usesNonExemptEncryption=true` 时会设置 `exportComplianceRequired=true` 并令
`snapshotReady=false`。本轮没有独立、可信的出口合规证据绑定，因此绝不会假定
它已通过。

Build 快照额外输出：

```json
{
  "query": {
    "bundleID": "...",
    "platform": "IOS",
    "version": "1.2.3",
    "build": "45"
  },
  "resourceIDs": {
    "app": "...",
    "preReleaseVersion": "...",
    "build": "...",
    "buildUpload": "..."
  },
  "build": {
    "processingState": "VALID",
    "expired": false,
    "buildAudienceType": "APP_STORE_ELIGIBLE",
    "usesNonExemptEncryption": false,
    "exportComplianceRequired": false
  },
  "buildUpload": {
    "state": "COMPLETE",
    "errors": [],
    "warnings": [],
    "warningsPresent": false,
    "infos": [],
    "rawState": {}
  },
  "readiness": {
    "candidateBindingsVerified": true,
    "appResourceUnique": true,
    "preReleaseVersionExact": true,
    "buildResourceUnique": true,
    "buildProcessingValid": true,
    "buildNotExpired": true,
    "appStoreEligible": true,
    "encryptionDeclarationResolved": true,
    "exportComplianceRequired": false,
    "buildUploadComplete": true,
    "buildUploadErrorFree": true,
    "warningsPresent": false,
    "snapshotReady": true
  }
}
```

## 提交元数据快照（API 可见子集）

精确 Build 快照完成后，可再采集一份与最终
`.release/app-store-submission.json` 绑定的提交元数据快照：

```sh
node scripts/capture-asc-submission-metadata.mjs \
  --manifest "$PWD/.release/app-store-submission.json" \
  --build-snapshot "/absolute/path/to/asc-build-snapshot.json" \
  --bundle-id "$AGENT_ISLAND_IOS_BUNDLE_ID" --platform iOS \
  --version "$AGENT_ISLAND_VERSION" --build "$AGENT_ISLAND_BUILD_NUMBER" \
  --artifact "/absolute/path/to/exact-candidate.ipa" \
  --identity-lock "$PWD/.release/identity.lock.json" \
  --output "/absolute/path/to/asc-submission-metadata.json"
```

macOS 使用同一命令，但将 platform 改为 `macOS`，artifact 改为本次精确
PKG。采集仅发出 HTTPS `GET`，输出为不覆盖的普通 `0444` 文件；
`--manifest` 只接受仓库规范固定路径
`$PWD/.release/app-store-submission.json`。快照会逐值比对 App 身份、
分类、版本与已关联 Build、中英文案，以及脱敏后的审核联系信息/备注匹配结果；
iOS 外部测试还会比对 TestFlight 本地化、Beta Review 联系信息、登录需求和
`testFlight.betaReviewNotes`，快照对联系信息与备注只保存布尔匹配结果。
审核演示账号名和密码不会被 API 查询或写入证据，其是否真实可用必须另作
受控人工检查。内测专用 TestFlight 只比对精确 Build 的 What to Test；
Beta App Description、反馈邮箱、Beta Review 联系信息/备注和登录项继续列为人工范围。macOS
TestFlight 不在这份提交元数据快照的覆盖范围内，仍按独立测试流程验收。

特别注意，App Store 版本本地化中的 `whatsNew` 是更新说明。submission
manifest 必须用 `version.releaseKind` 明确区分 `initial` 和 `update`：首发时
每个商店 localization 的 `whatsNew` 必须为 `null`，更新时才必须填写并与
ASC 精确比对。TestFlight Beta Build 的 `whatsNew` 表示 What to Test，是
另一个可单独比对的字段。

当前提交契约只允许 `zh-Hans` 与 `en-US`；四组 ASC localization 子资源都
必须恰好包含这两个 locale，额外、缺失或重复语言都会失败关闭。采集前还
必须先在目标 App Store version 上关联精确 Build，否则无法生成这份快照。

输出把字段分为 `apiComparedPaths`、`semanticSignalPaths`、
`separatelyAttestedPaths` 和 `manualOrUnsupported`。Apple 公共 API 不能精确读取的
税类、DSA 法律声明、年龄问卷/最终评级、截图展示顺序等始终列入
`manualOrUnsupported`。`isOrEverWasMadeForKids` 也只是“当前或曾经”的语义信号，
不冒充当前 Made for Kids 声明的精确证明。因此当前版本即使 API 子集
全部一致，`submissionManifestFullyVerified` 和
`remoteMetadataComparisonComplete` 仍固定为 `false`；它只是 API 可见子集的
可审计中间证据，不是绕过人工合规复核或打开远端完整门禁的通行证。

离线复验命令与采集命令参数相同，另加 `--verify`：

```sh
node scripts/capture-asc-submission-metadata.mjs \
  --verify "/absolute/path/to/asc-submission-metadata.json" \
  --manifest "$PWD/.release/app-store-submission.json" \
  --build-snapshot "/absolute/path/to/asc-build-snapshot.json" \
  --bundle-id "$AGENT_ISLAND_IOS_BUNDLE_ID" --platform iOS \
  --version "$AGENT_ISLAND_VERSION" --build "$AGENT_ISLAND_BUILD_NUMBER" \
  --artifact "/absolute/path/to/exact-candidate.ipa" \
  --identity-lock "$PWD/.release/identity.lock.json" \
  --max-age-seconds 900
```

`--verify` 模式不创建 ASC 客户端、不发网络请求也不读取 API 凭据；它会
重新绑定固定 manifest、Build 快照、精确候选包与 identity lock，并要求
快照是普通 `0444` 文件且未过期。当前这份子集证据不会将
`remoteMetadataComparisonComplete` 翻转为 `true`。

## 离线验证

`release-readiness.sh` 不应联网。它应调用相同脚本的 `--verify` 模式，并传入当前候选：

```sh
node scripts/capture-asc-build-snapshot.mjs \
  --verify "$PWD/dist/ios/1.2.3-45/asc-build-snapshot.json" \
  --bundle-id "$AGENT_ISLAND_BUNDLE_ID" \
  --platform iOS \
  --version 1.2.3 \
  --build 45 \
  --artifact "$PWD/dist/ios/1.2.3-45/AgentIsland.ipa" \
  --identity-lock "$PWD/.release/identity.lock.json" \
  --max-age-seconds 900
```

App 快照的验证命令相同，但不需要 platform/version/build。验证会检查：

- snapshot 路径以及 artifact/identity lock 路径都是绝对、规范且不穿越符号链接；
- snapshot 是普通 `0444` 文件；
- schema、kind、查询身份、所有关键 resource ID 关系和 readiness 派生值；
- `evidenceSHA256`；
- artifact、固定路径 identity lock、其完整正式 schema，以及三个已应用文件的
  当前路径/inode/长度/SHA-256；
- `capturedAt`、固定 15 分钟 `expiresAt`，以及调用方设置的不超过 900 秒的最大年龄。

成功时 stdout 是可供门禁读取的 JSON，包含：

```json
{
  "verified": true,
  "snapshotSHA256": "...",
  "evidenceSHA256": "...",
  "capturedAt": "...",
  "expiresAt": "...",
  "query": {},
  "candidate": {},
  "releaseIdentity": {},
  "resourceIDs": {},
  "app": {
    "sku": "...",
    "primaryLocale": "..."
  },
  "preReleaseVersion": {},
  "build": {
    "buildAudienceType": "APP_STORE_ELIGIBLE",
    "usesNonExemptEncryption": false,
    "exportComplianceRequired": false
  },
  "buildUpload": {
    "errors": [],
    "warnings": [],
    "warningsPresent": false,
    "infos": []
  },
  "readiness": {}
}
```

App 快照不返回 `preReleaseVersion`/`build`/`buildUpload`。Build 快照会返回上述全部
规范化字段，便于 readiness 脚本离线交叉比对 SKU、locale、audience、encryption
和全部 upload issues。

`verified == true` 仅表示该快照完整、新鲜且仍绑定当前候选，不等于可提交。
后续门禁还必须要求 `readiness.snapshotReady == true`。过期、路径变化、候选哈希
变化、identity lock 变化、证据被编辑或权限变为可写都会失败。

## 仍需要用户或 Apple 的状态

这些脚本不会创建 App Store Connect App 记录。用户必须先在 App Store Connect 网页创建
记录、上传签名构建并等待 Apple 处理。Apple 状态达到 `VALID`/`COMPLETE` 后才能采集 Build
快照。授权人还必须先在对应 App Store version 中关联这一精确 Build，提交元数据快照才能采集；
脚本只验证这个已有关系，不会更改它。TestFlight 分发、人工审核 warning、Add for Review 和
Submit for Review 仍是独立且需要明确授权的后续步骤，本实现不会执行它们。

## 离线测试

```sh
./Tests/test-asc-readonly-snapshot.sh
```

测试使用注入 transport 和本地 JSON:API fixtures，不读取真实 ASC 凭证，也不连接 Apple。
