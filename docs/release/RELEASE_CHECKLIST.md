# MAC版灵动岛--Agent运行监测 发布检查清单

> 当前状态：macOS 与 iOS 已统一为 0.6.1（Build 8）。macOS 仍是 `local.agentisland.desktop` + ad-hoc 签名的本机开发预览；iOS 已有 SwiftUI App、Widget/Live Activity Extension、按 iCloud 账号隔离的私有 CloudKit 接收器、离线缓存、Xcode 工程和图标，Mac CloudKit producer 也已实现并通过本地 CLI/回归。当前仍使用 `com.example.agentisland`/`iCloud.com.example.agentisland`/空 Team ID，且真实 Developer ID CloudKit entitlement/profile、Production schema、同账号 Mac→iPhone 真机验证和经完整 Xcode+iOS SDK 验证的 Archive 均未完成。下面分别覆盖 Developer ID、Mac App Store 和 iOS TestFlight/App Store。

## 0. 确定本次发布范围

- [ ] 选择渠道：`Developer ID 官网分发` / `Mac App Store` / `iOS TestFlight` / `iOS App Store`，并为不同平台分别记录构建和审核状态。
- [ ] 明确 App Store Connect 记录模式：同一记录/Universal Purchase 选 `AGENT_ISLAND_APP_STORE_RECORD_MODE=universal-purchase` 并确保 macOS/iOS App Bundle ID 相同；分开两个记录选 `separate-records`，且 macOS/iOS App Bundle ID 必须不同。
- [ ] Mac producer 和 iOS receiver 代码链路已实现，但在正式签名/Container/schema 和同账号真机验证通过前不宣传“手机可查看 Mac Agent”；不把本地回归通过当成已上线服务。
- [ ] 确定正式产品名，并检索 App Store、商标和域名冲突。
- [ ] 核验公开名 `MAC版灵动岛--Agent运行监测` 的 App Store、商标与域名可用性；正式分发时 `AGENT_ISLAND_DISPLAY_NAME`、`CFBundleDisplayName`、`.app` 与 ZIP 必须保持该名称。如必须更名，先将构建/发布脚本和文档作为一次完整迁移，不得只覆盖环境变量。
- [ ] 确定版本号；首次公开发布建议采用清晰的 `1.0.0` 或经确认的版本策略。
- [x] 已于 2026-09-02 根据 DeepSeek 官方 API 文档、隐私政策和开放平台服务协议完成公开资料基线审计，并归档到 `DEEPSEEK_TRANSLATION_PRIVACY_AUDIT.md`。
- [ ] 确定正式版是否保留 DeepSeek 默认端点；如保留，取得 API 请求保留/训练的专用书面依据，或接受无固定保留期与可能训练/优化的保守披露，并实施分层同意。
- [ ] 决定免费、付费或后续商业模式；当前没有 IAP/订阅实现。

## 1. 开发者与标识

- [ ] 在 Apple Developer 账号核对个人开发者法定姓名和 Team ID。
- [ ] 注册正式 Bundle ID：`[正式Bundle ID]`。
- [ ] 按 `RELEASE_IDENTITY.md` 填写 `Config/ReleaseIdentity.json`，先运行默认 `--check`；确认主 App、Widget、Team、Container 和固定 CloudKit 契约全部通过后才运行 `--apply`。
- [ ] 核对第一次 `--apply` 已在 `.release/identity-backup` 保存可恢复原文件，并生成 `.release/identity.lock.json`；锁定后不得直接编辑另一套不可逆标识。
- [ ] 同步修改 `CFBundleIdentifier`、Keychain service 标识、构建脚本、测试和文档。
- [ ] 为 iOS App 与 Widget Extension 分别注册 `[正式iOS Bundle ID]` 和 `[正式iOS Widget Bundle ID]`，保持 Extension ID 与 Xcode 配置一致。
- [ ] 在 `ApplePlatforms/iOS/Config/Project.xcconfig` 替换 `com.example.agentisland` 和空 Team ID；确认 iOS 版本/Build 单调递增。
- [ ] 为已安装开发版设计一次性本地数据/Keychain 迁移；更换 Bundle ID 后旧偏好和密钥不会自然属于新应用。
- [ ] 创建正式 App Icon（完整尺寸、无敏感或侵权素材），在浅色/深色桌面检查。
- [ ] 确认 `CFBundleShortVersionString`、`CFBundleVersion`、最低 macOS 版本和版权信息。
- [ ] 安装完整 Xcode，并在 Accounts 中登录正确开发者账号。

## 2. 法务、隐私与支持页面

- [ ] 填写 `[开发者法定姓名]`、`[支持邮箱]`，不得把个人开发者写成不存在的公司。
- [ ] 将最终中文和英文隐私政策发布到稳定 HTTPS 页面：`https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/`。
- [ ] 建立支持页面：`https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/`，包含联系入口、系统要求、常见问题、卸载和本地数据清理方法。
- [ ] 如提供营销页，填写 `[营销URL，可选]`。
- [ ] 删除所有上线材料中的方括号占位符和“草案”提示。
- [ ] 复核 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`，把第三方声明随最终应用分发。
- [ ] 核实产品名、图标、截图和文案不复制参考项目或暗示厂商背书。
- [ ] 完成 `DATA_HANDLING_AND_PRIVACY_LABELS.md` 的翻译供应商决策表。
- [ ] 按 `APP_PRIVACY_SUBMISSION_WORKSHEET.md` 填写 App Store Connect，并运行 `node scripts/validate-app-privacy.mjs --release`；不得用源码清单代替最终 Xcode Privacy Report。
- [ ] 在翻译页首次使用前提供清楚的离机传输提示，显示目标服务，并让用户主动提交。
- [ ] 确认隐私遮罩、删除网站/备忘录/学习条目、清除 API Key 和移除数据源均可正常工作。

## 3A. Developer ID 官网分发

- [ ] 在新用户偏好环境首次 GUI 启动：确认原生说明出现前没有 Agent 日志扫描或刷新定时器；选择“暂不开始”后保持无扫描。
- [ ] 确认同意后才开始周期只读刷新；在设置中停止后定时器取消、快照清除，恢复后重新读取；状态栏和设置都能重新查看说明。
- [ ] 确认可移除自定义数据源，应用包不包含摄像头、麦克风、屏幕录制或辅助功能用途字符串/请求 API。
- [ ] “检查更新”仅打开最终 `AgentIslandSupportURL` 的 HTTPS 支持/下载页；空或占位 URL 显示明确错误，不包含自动下载/安装器。
- [ ] 创建或确认有效的 `Developer ID Application` 证书。
- [ ] 为应用开启 Hardened Runtime，并只加入实际需要的 entitlements。
- [ ] 如 Developer ID 版包含 iPhone 私有同步，为正式 App ID 开启 CloudKit，绑定精确 Container，生成包含该能力且未过期的 Developer ID provisioning profile；从 profile 复制完整 macOS `com.apple.application-identifier` 与 Team ID，并验证源 entitlement、profile 的 `DeveloperCertificates` 确实包含本次签名证书、归档后的 entitlement 完全一致且未启用 `get-task-allow`。
- [ ] 使用 `apply-release-identity.sh --check --profile ...` 验证 Apple 签名 profile，再用 `--apply --profile ...` 生成 `.release/CloudKit.entitlements`；不得把 Team ID 猜成 App ID Prefix，也不得手写最终 entitlement 冒充已验证产物。
- [ ] 不使用 ad-hoc 签名；使用正式身份、secure timestamp 和 runtime options 签名。
- [ ] 从干净目录生成 universal `arm64 + x86_64` 归档，确认没有 Finder 扩展属性、测试日志或密钥。
- [ ] `dist` 中只保留唯一 canonical `MAC版灵动岛--Agent运行监测-macOS-universal.zip`；把带空格、序号或其他后缀的旧副本移出发布目录，正式脚本会拒绝歧义来源包。
- [ ] 使用 `codesign --verify --deep --strict --verbose=2` 验证签名；同时检查每个架构可启动。
- [ ] 用 `xcrun notarytool` 提交公证并等待 Accepted；下载同一 submission ID 的详细日志，即使 Accepted 也处理其中全部 issue，并把日志随构建 manifest 留档。
- [ ] 将公证票据 staple 到最终 `.app`，再生成最终 ZIP/DMG；如使用 DMG，也验证其签名与公证流程。
- [ ] 在另一台未信任开发证书的 Mac 上下载并测试 Gatekeeper 首次启动。
- [ ] 使用 `spctl --assess --type execute --verbose=4` 验证最终应用。
- [ ] 计算并公布 SHA-256；确保下载页面全程 HTTPS。
- [ ] 不把 Apple ID、App Store Connect API 私钥、notarytool 凭据或证书密码写入仓库或构建日志。
- [ ] 准备回滚：保留上一版已签名归档和发布说明。

## 3B. Mac App Store 专项

- [ ] 为商店版建立可归档的 Xcode macOS Target；不提交当前 ad-hoc 构建。
- [ ] 将该 Target 的工程与 Scheme 填入 `AGENT_ISLAND_MAC_APP_STORE_PROJECT` / `AGENT_ISLAND_MAC_APP_STORE_SCHEME`；确认 readiness 从同一 App Target 读到 `AgentIsland.m`、`PrivacyInfo.xcprivacy`、`Web/index.html`、`AgentIsland.icns`、`THIRD_PARTY_NOTICES.md`、Release Bundle ID/Team/显示名、有效 Info.plist URL 键和 `CODE_SIGN_ENTITLEMENTS`。
- [ ] 开启 App Sandbox。
- [ ] 把 `~/.codex`、`~/.claude`、IDE 扩展目录和自定义日志改为用户通过选择器明确授权的只读目录。
- [ ] 仅申请实际需要的 `user-selected read-only`、`bookmarks.app-scope`、CloudKit 和翻译功能所需 `network.client`，使用 security-scoped bookmarks 持久化授权，并提供撤销/重新选择入口。
- [ ] 在用户未授权、拒绝授权、目录移动或 bookmark 失效时显示可恢复的空状态，不反复弹窗。
- [ ] 验证沙盒内能否可靠识别运行进程；不能访问的能力应删除或降级，不得虚假展示。
- [ ] 使用与 `AGENT_ISLAND_DEVELOPMENT_TEAM` 同一 Team 的 Apple Distribution / Mac App Distribution 证书及 provisioning profile 完成 Archive；另一 Team 的证书不得让 readiness 通过。
- [ ] 添加并验证 `PrivacyInfo.xcprivacy`；原生 macOS 按最终数据收集行为核对清单。Required Reason API 的平台门禁只应用到 Apple 当前要求的平台，不把 iOS 规则误套到原生 macOS。
- [ ] 用 Xcode Organizer 生成并审阅 Privacy Report，处理所有验证警告。
- [ ] 商店包必须自包含，不安装外部代码、不提权、不自动加入登录项，也不在退出后遗留子进程。
- [ ] 准备无敏感自定义 JSONL 审核夹具或内置离线演示模式。
- [ ] 为翻译功能提供审核可用的临时端点/凭据或离线演示，不要求审核员付费购买第三方 API。
- [ ] 在 App Store Connect 创建记录，填写 `[SKU]`、Bundle ID、类别、年龄分级、版权与地区可用性。
- [ ] 按账号与销售地区如实完成 DSA trader status、税务、银行、出口合规和中国大陆等地区问卷。
- [ ] 根据最终加密用途回答出口合规；不要在未核对时猜测 `ITSAppUsesNonExemptEncryption`。
- [ ] 填写并发布 App Privacy 标签，和最终构建、隐私政策保持一致。
- [ ] 上传中英文元数据、最终截图、隐私政策 URL、支持 URL 和 Review Notes。
- [ ] 先通过 macOS TestFlight/内部测试验证，再提交 App Review。
- [ ] 仅针对同一个未改动的候选 Archive，记录沙盒授权流程、Archive 签名结构、匹配 profile/证书、Xcode Privacy Report 和审核路径证据后，才将 `AGENT_ISLAND_MAC_APP_STORE_SANDBOX_FLOW_VERIFIED`、`AGENT_ISLAND_MAC_APP_STORE_ARCHIVE_VERIFIED`、`AGENT_ISLAND_MAC_APP_STORE_PROFILE_CERTIFICATE_VERIFIED`、`AGENT_ISLAND_MAC_APP_STORE_PRIVACY_REPORT_VERIFIED`、`AGENT_ISLAND_MAC_APP_STORE_REVIEW_PATH_VERIFIED` 设为 `true`。

## 3C. iOS TestFlight 与 App Store 专项

- [ ] 安装项目要求的完整 Xcode 26 或更新版本及 iOS SDK；不能只依赖 Command Line Tools 的静态校验。
- [ ] 先运行 `ApplePlatforms/iOS/scripts/validate-project.sh`，再在完整 Xcode 环境运行 `--build`，处理全部编译、签名和 Sendable/并发警告。
- [ ] 正式配置齐全后运行 `ApplePlatforms/iOS/scripts/release-ios.sh`生成签名 Archive；如需本地 IPA，使用 `--export`。该脚本**不上传**，必须先审阅 `dist/ios` 中的 Archive、release metadata 和可选 SHA-256，再在 Xcode Organizer 中单独决定上传。
- [ ] 在开发者后台注册 iOS App ID、Widget Extension ID 和生产所需能力。
- [ ] 注册正式 iCloud container，并把现有 entitlement/xcconfig 中的 `iCloud.com.example.agentisland` 替换为精确标识；在开发者后台关联正式 App ID。
- [ ] 保留并验证现有 Mac 隐私化快照 producer 和 `CloudKitSnapshotProvider` 私有数据库 receiver；使用真实 Developer ID CloudKit entitlement/provisioning profile 完成签名上传，并验证同账号、撤销、重试、账号切换隔离、冲突和过期状态。
- [ ] 创建 `AgentIslandSnapshot/latest/payloadJSON` 对应的开发 schema 并部署到生产 CloudKit；Mac 与 iPhone 的 record type/name/field 必须一致。
- [ ] 验证 Mac 同步默认关闭，必须经离机字段说明和明确同意后才上传；普通刷新上传至少节流 60 秒，“立即同步”可强制刷新。
- [ ] 验证实际 producer 隐私 schema：默认不上传完整对话标题，只有用户单独明确选择且标题来源明确时才允许，并通过长度/路径/密钥样式过滤。
- [ ] 确认生产负载始终排除 prompt、任务摘要、回复、模型名、API Key、进程 ID、备忘录、翻译内容、Mac 文件路径和工作区路径；当前 producer 的 `safeSummary` 保持空值。
- [ ] 验证 Mac 关闭同步会立即停止上传并删除 CloudKit `latest` 记录；iPhone 在缺失记录时仅清除当前 iCloud 账号缓存，不读取其他账号或旧共享缓存。
- [ ] 处理 iCloud 未登录、CloudKit 被禁用、网络离线、账号切换、设备移除、权限撤销、数据损坏和未来 schema 版本。
- [ ] 当前 Live Activity 仅在 iPhone App 启动、回到前台或用户手动刷新时由主 App 更新，不含 APNs push-to-start/远程更新；如以后加入，先完成 APNs、安全和隐私审计。
- [ ] 验证无活跃 Agent 时不能错误启动实时活动；Agent 结束后活动能及时结束。
- [ ] 在锁屏和灵动岛中只显示数量、状态、时长、Token 和更新时间，不显示会话标题或个人电脑名。
- [ ] 用相同 Team 正式签名 App 与 Extension，并确认 Extension 被正确嵌入 App Archive。
- [ ] 检查 App Icon 的所有槽位、最终品牌权利及 1024×1024 marketing icon，不使用透明通道。
- [ ] 核对 App Target `Config/PrivacyInfo.xcprivacy` 已同时声明 Other Usage Data 与 Other User Content（与用户关联 / App Functionality / no tracking），并在 App Store Connect 使用相同口径；确认 Widget 嵌入独立 `WidgetExtension/PrivacyInfo.xcprivacy`，collected data/accessed API/tracking domains 均为空且 tracking=false，并确认 Widget 无 iCloud entitlement。若首发移除完整标题同步，再按最终行为重新评估 Other User Content，而不是保留过时披露。
- [ ] 使用真实同步数据完成 iPhone/iPad 适配范围决定、Dynamic Type、VoiceOver、深浅色、旋转和本地化测试。
- [ ] 在支持 Dynamic Island 的真机测试紧凑、最小、展开和锁屏视图；普通 iPhone 上验证锁屏 Live Activity。
- [ ] 生成 Development/TestFlight Archive，先邀请内部测试；正式签名/Production schema/同账号真机链路未验收时，不邀请外部测试或提交 Beta App Review。
- [ ] 外部 TestFlight 前填写中英文 Beta Description、What to Test、反馈邮箱、审核联系人和可复现的配对/演示步骤。
- [ ] App Store 提交前使用 `IOS_APP_REVIEW_NOTES.md` 提供无需审核员自行搭建开发环境的可审核路径。
- [ ] 仅在 Production CloudKit schema、同账号 Mac→iPhone 真机同步、Live Activity 真机表现和审核演示路径都针对同一签名 Build 验收后，才把 `Config/Release.example.env` 中对应四个手工证据开关设为 `true`；`readyForFunctionalIOSTestFlight` 不再只凭源码与占位配置推断。

## 4. 功能与隐私 QA

### 启动和界面

- [ ] macOS 13、当前主流 macOS 版本分别测试；Intel 与 Apple Silicon 均测试。
- [ ] 有刘海/无刘海、多显示器、不同缩放、全屏和多个 Space 下测试定位。
- [ ] 悬停约 150 ms 展开、移出约 450 ms 收回、点击固定、`Esc`/失焦收起均符合预期。
- [ ] 悬停不抢走其他应用焦点；固定后输入框、文本选择和滚动可用。
- [ ] 状态栏菜单的显示、移动、刷新、语言和退出均可用；退出后无残留进程。
- [ ] 中英文无截断、错位或漏翻，最窄支持宽度下按钮仍可操作。

### 数据源和计量

- [ ] 无任何 Agent/日志时显示有解释的空状态，不崩溃、不伪造数据。
- [ ] Codex、Claude Code、自定义 JSONL 分别验证正常、空、损坏、超大和权限拒绝场景。
- [ ] 相同事件/消息去重，缓存输入不重复计入总量。
- [ ] 实时页只汇总 working 会话；已安装或运行中的 IDE 不等于 Agent 正在工作。
- [ ] 历史总量等于可读会话总量；旧日志删除后口径说明仍准确。
- [ ] `exact`、`currentCounter`、`totalOnly`、`reported`、`estimated` 等质量标签正确。
- [ ] 标题优先使用工具保存的真实标题；隐私遮罩隐藏名称、路径和模型。
- [ ] 沙盒版只读取用户授权目录，撤销后立即停止读取。

### 工作台

- [ ] 网站仅允许 HTTPS 或 loopback HTTP，拒绝凭据、fragment 和危险 scheme。
- [ ] 点击网站只调用默认浏览器，不后台抓取页面。
- [ ] 网站、备忘录和学习条目的新建、编辑、删除、搜索与持久化均测试。
- [ ] 损坏/旧版 `workspace.json` 不被盲目覆盖，恢复提示可理解。
- [ ] 卸载与本地数据清理说明按实际发行 Bundle ID 验证。

### 翻译与网络

- [ ] 未点击提交时抓包确认无翻译网络请求。
- [ ] HTTPS、自定义端口、本机 loopback、错误证书、跨域重定向、超时、离线、HTTP 错误和超大响应均测试。
- [ ] API Key 只在请求鉴权头和 Keychain 中出现，不进入工作台、Web、快照、崩溃日志或截图。
- [ ] 更换端点时 Keychain 项目按端点隔离，清除密钥后不可恢复读取。
- [ ] 输入变化后旧结果不能误存；复制只写入剪贴板，不读取剪贴板。
- [ ] App Privacy 标签和网络抓包结果一致。

### iPhone 看板、同步与 Live Activity

- [ ] 未配置同步时只显示准确空状态，不显示 Preview 数据或虚构 Agent。
- [ ] 同步成功后 Agent 数、运行数、活跃对话、时长和 Token 与同一时间的 Mac 隐私化快照一致。
- [ ] `relevantAgents` 保留 Mac producer 已主动筛选纳入的所有工具，包括当前无会话/无 Token 的条目；状态仍如实显示为 idle/completed，不得计入 `activeAgents`。
- [ ] 2 MB、100 Agent、500 对话、文本长度、未来时间戳和 cached-input 校验边界均有测试。
- [ ] 缓存写入具备原子性和文件保护；损坏缓存不会覆盖最后可恢复状态或导致崩溃。
- [ ] 完整标题默认不传输；收到可选标题时每次冷启动仍默认隐藏。
- [ ] 刷新、后台/前台切换、离线缓存、陈旧数据标记和账号切换行为可理解。
- [ ] 在 Mac 上关闭同步并删除 `latest` 后，iPhone 刷新会清空当前账号快照；退出/切换 iCloud 账号时不显示上一账号数据。
- [ ] 实时活动不会出现标题、prompt、回复、Mac 路径、API Key 或个人设备名。
- [ ] 活动开始、更新、停止、系统禁用、无活跃 Agent 和系统自动结束均验证。
- [ ] 验证 Live Activity 仅在 App 启动、回前台或手动刷新时获得新状态；锁屏/灵动岛文案不暗示 APNs 后台实时监控。
- [ ] 启动 Live Activity 后强制结束并重启 App，按钮会从 ActivityKit 恢复已运行状态；两分钟无主 App 更新时，锁屏/灵动岛以本地化过期文字和橙色状态显示，不继续假装为实时。
- [ ] iOS 17 最低系统、当前 iOS、支持/不支持 Dynamic Island 的真机均测试。

## 5. 构建与安全检查

- [ ] 运行 `./scripts/test.sh` 全部通过。
- [ ] 运行 `node scripts/validate-store-submission.mjs --release` 和 `node scripts/validate-app-privacy.mjs --release`，确认元数据、截图、双语政策、App Privacy 与源码清单均无占位符或发布阻断项。
- [ ] 运行 `./scripts/release-readiness.sh --json`，将输出与候选构建证据一起留档；不得把源码字符串命中当成功能已验收。
- [ ] 运行 iOS `validate-project.sh` 静态检查；在完整 Xcode 环境运行 `validate-project.sh --build` 并 Archive。
- [ ] 运行 iOS `scripts/release-ios.sh`，确认它验证 App/Widget 嵌入、Bundle ID、签名、provisioning profile、App CloudKit entitlement 和 Widget 无 iCloud entitlement；如使用 `--export`，确认只本地导出 IPA 和 SHA-256，metadata 中 `uploaded` 仍为 false。
- [ ] 在干净 checkout 重建并记录 commit、构建时间、Xcode/SDK 版本和依赖清单。
- [ ] 检查归档中无 `.DS_Store`、测试 fixture、源代码、调试符号泄漏、个人路径或凭据。
- [ ] `Info.plist` 的 ATS、最低系统、Bundle ID、版本、`LSUIElement` 与实际行为一致。
- [ ] 仅使用必要系统框架；记录第三方组件及许可证。
- [ ] 对最终二进制运行签名、架构、恶意软件和网络域名审计。
- [ ] 保存公证日志、App Store validation 结果和可复现的 checksum。

## 6. 商店素材与审核

- [ ] 根据最终构建重新截取中英文截图，遮盖真实项目路径、对话、用户名、API Key 和 Token 敏感信息。
- [ ] 截图只展示最终构建中真实可操作的功能，不使用竞品截图/Logo；iPhone 看板和灵动岛可以展示，但必须来自正式签名、Production schema 和同账号真机链路均已验收的最终 iOS 构建。
- [ ] 按 `IOS_SCREENSHOT_CHECKLIST.md` 制作 1–10 张无透明通道的 iPhone 截图，并分别准备简体中文和英文。
- [ ] 校验名称、副标题、推广文本、关键词和描述字符限制。
- [ ] Support URL 能打开并显示真实联系方式；Privacy URL 不是空页面或仓库草稿。
- [ ] Review Notes 给出从启动到核心功能的完整步骤。
- [ ] 审核夹具不含用户数据，下载地址在审核期间稳定可访问。
- [ ] 临时审核凭据有效、额度足够、无额外验证；审核结束后撤销。
- [ ] 提交前再全文搜索 `[`, `TODO`, `草案`, `placeholder`。

## 7. 发布与发布后

- [ ] 写出中英文 Release Notes 和已知限制。
- [ ] 选择手动发布、自动发布或 phased release，并记录决定。
- [ ] 上线后从公开链接实际下载安装，验证签名、公证、首次启动和更新页面。
- [ ] 监控支持邮箱和 App Store Connect 审核/崩溃反馈，但不擅自新增用户遥测。
- [ ] 建立安全问题报告流程和紧急下架/换包联系人。
- [ ] 每次新增或改变网络、SDK、CloudKit/iOS 同步、APNs、账号或数据类型时，先更新隐私政策和标签。
- [ ] 保留最终二进制、dSYM（如生成）、提交记录、隐私标签快照、政策版本与 checksum。

## 8. 当前结论

- Developer ID 直接分发：完成正式 Bundle ID、证书签名、Hardened Runtime、公证、正式页面与 QA 后可以上线。
- Mac App Store：在上述基础上，还必须完成 App Sandbox 的用户授权数据源改造、Privacy Manifest 和审核演示路径。
- iPhone App Store：Xcode 工程、App/Extension Target、SwiftUI 看板、Live Activity、图标、Mac producer 和按账号隔离的 iOS receiver 代码已具备；仍需替换正式标识与 Team，为 Mac 配置真实 Developer ID CloudKit entitlement/profile，部署 Production schema，使用完整 Xcode+iOS SDK 编译，完成同账号真机验证并生成可提交 Archive。现有 macOS `.app` 仍不能直接转换或上传为 iPhone App。
