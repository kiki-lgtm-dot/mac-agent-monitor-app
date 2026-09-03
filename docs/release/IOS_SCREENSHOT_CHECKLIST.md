# iOS App Store 截图清单

> 状态：计划稿。Mac producer 与 iPhone receiver 代码链路已实现，但真实 Developer ID CloudKit entitlement/profile、Production schema、同一 iCloud 账号 Mac→iPhone 真机链路和可提交 Archive 尚未验收。不能用 SwiftUI Preview 或手工放入 `latest-snapshot.json` 的画面冒充已上线的跨设备功能。只有最终提交 Build 能通过真实同账号同步，或随包提供且明确标记的审核演示模式重现画面后，才可生成商店截图。

## 1. Apple 当前技术要求

- 每个设备尺寸可上传 1–10 张截图。
- 支持 `.jpeg`、`.jpg`、`.png`；图片不能有 alpha/透明通道。
- 当前 Target 是 iPhone-only（`TARGETED_DEVICE_FAMILY = 1`），不需要 iPad 截图；如果最终改为 Universal，必须补齐 iPad 素材和 QA。
- 优先从 6.9 英寸 iPhone 模拟器/真机按原始像素直接截图。Apple 当前接受的 6.9 英寸竖屏尺寸包括 1320×2868、1290×2796 或 1260×2736，具体取决于设备；不要把其他比例强行拉伸。
- 如果不提供 6.9 英寸截图，6.5 英寸可能成为必填并被用于缩放。提交前以 App Store Connect 实际提示为准。
- 当前产品以竖屏为主要信息密度，建议商店组全部使用竖屏；若提交横屏，整组构图与像素规格要一致。
- 简体中文和英文分别上传本地化截图，文案、应用语言和商店语言必须匹配。

官方规格：[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

## 2. 截图前 Go/No-Go

- [ ] Mac producer 使用真实 Developer ID CloudKit entitlement/profile 签名，精确 Container 的 Production schema 已部署，并已通过同一 iCloud 账号 Mac→iPhone 真机验证，不再只有 `notConfigured` 空状态。
- [ ] 完整 Xcode+iOS SDK Build、真机安装和 App Store Archive 已通过。
- [ ] 截图所用 Build 与准备提交的 Build 相同，或只有无行为差异的版本号变化。
- [ ] 截图数据来自无敏感测试账号/审核演示数据，且用户可在最终 App 中复现。
- [ ] 不包含真实用户名、电脑名、项目名、会话标题、路径、API Key、Apple ID、通知正文或个人照片。
- [ ] Token、时长、状态和更新时间彼此合理，不使用夸张或无法由产品生成的数字。
- [ ] 完整标题默认隐藏；只有专门展示“用户主动显示标题”的截图才可开启。
- [ ] Mac 私有同步默认关闭，已在无敏感测试数据上完成离机字段的明确同意；如截图展示标题，还必须有独立标题同意。
- [ ] Live Activity 中没有对话标题、个人设备名、prompt、回复或路径。
- [ ] 隐私政策、支持 URL、App Privacy 标签和截图表达一致。

## 3. 推荐 6 张截图顺序

### 1. 总览：首页已连接状态

画面：顶部显示已从 Mac 同步和最近更新时间，四张指标卡展示相关 Agent、运行中、活跃对话和 Token；下方露出第一张 Agent 卡片。

- 中文短文案：`Mac Agent 状态，一眼掌握`
- English caption: `Your Mac agents at a glance`
- 核验：不能出现“尚未配置同步”；指标必须与下方卡片一致。

### 2. Agent 与会话详情

画面：一个工作中 Agent 和一个空闲/完成 Agent；展示工具名、状态、工作时长、Token 和隐私化对话占位。当前 Mac producer 不从 prompt/回复生成 `safeSummary`，不得在生产同步截图中伪造任务摘要。

- 中文短文案：`只看正在发生的工作`
- English caption: `Focus on work in progress`
- 核验：保留 Mac producer 主动筛选纳入的工具，即使当前无会话/无 Token 也可显示，但不把它冒充为运行中 Agent；最多三条会话与 `+N` 行为符合 UI。

### 3. 隐私化摘要与标题控制

画面：完整标题隐藏，使用“隐私对话 N”等占位；顶部眼睛按钮处于默认隐藏状态，底部隐私说明可见。

- 中文短文案：`只同步必要的状态摘要`
- English caption: `Sync only the status you need`
- 辅助小字可写：`不包含 Prompt、回复、密钥或 Mac 路径` / `No prompts, responses, keys, or Mac paths`
- 核验：辅助文案不得遮盖原 UI；最终同步负载必须真的排除这些字段。

### 4. App 内 Live Activity 控制

画面：有活跃 Agent 时的“开启实时活动”区域，或开启后的“停止实时活动”状态。

- 中文短文案：`需要时，主动开启实时活动`
- English caption: `Start a Live Activity when needed`
- 核验：不能暗示持续后台采集或 APNs 远程更新；当前设计仅在 App 启动、回前台或手动刷新时由主 App 更新 ActivityKit。

### 5. 锁屏 Live Activity

画面：真实锁屏上的 Agent 状态、Token 和工作时长。

- 中文短文案：`锁屏也能快速查看进度`
- English caption: `Check progress from the Lock Screen`
- 核验：使用通用 `Mac` 来源标签，无完整标题和个人设备名；背景和系统时间不含私人信息。
- 核验：如锁屏画面时间早于快照更新时间，不得用文案把它写成正在后台实时变化的数据。

### 6. Dynamic Island 展开形态

画面：支持设备上的展开灵动岛，显示 Agent 数、Token、状态、活跃对话和时长。可在同一营销画布中附带紧凑/最小形态，但每个形态必须来自真实系统截图且不改变 UI 含义。

- 中文短文案：`灵动岛里，状态随手可见`
- English caption: `Agent status in Dynamic Island`
- 核验：不得把静态设计稿冒充系统 Live Activity；不支持灵动岛的设备仍应有可用锁屏体验。

## 4. 可选第 7–8 张

### 离线缓存/更新时间

当前 UI 已对离线缓存和 Live Activity 过期状态做明确标识；仍只能使用最终签名 Build 的真实画面。Live Activity 两分钟无主 App 更新时应显示本地化过期标签和橙色状态。

- 中文：`离线时保留最近一次摘要`
- English: `Keep the latest summary offline`

不要把旧数据显示成实时状态；截图必须能看到更新时间或缓存标签。

### 完整标题的明确选择

只在 Mac 端已实现“允许同步完整标题”的明确选择、iPhone 端离开前台即恢复默认隐藏并经过隐私复核后使用。

- 中文：`敏感标题，由你决定是否显示`
- English: `You control when titles appear`

不建议作为前 3 张主图，以免让用户误解标题默认上传。

## 5. 安全测试数据建议

建议使用确定性、无品牌争议的测试数据：

- 来源设备名：`Mac`，不要使用真人姓名或机器 hostname。
- Agent 显示名：`Builder`、`Reviewer`。
- 工具名：使用最终 App 实际支持且允许展示的工具名，或中性测试 Provider。
- 对话占位：使用最终 UI 自动生成的“隐私对话 N” / `Private conversation N`，不人工注入任务摘要。
- 状态：一项 Working、一项 Completed/Idle。
- 时长：10–45 分钟范围，便于看清格式。
- Token：展示 K/M 紧凑格式即可，避免极大数字抢夺主视觉。
- 更新时间：截图前 1–3 分钟。

不得使用仓库开发者的真实 31B 历史总量、真实对话标题、真实项目路径或现有本机日志截图。

## 6. 本地化与无障碍画面检查

- [ ] 中文截图运行在 `zh-Hans`，英文截图运行在 `en`；系统状态栏语言不混用。
- [ ] 中英文同一序号表达相同功能，数据与构图尽量一致。
- [ ] 使用默认 Dynamic Type 拍主素材，另用最大无障碍字号做 QA，但不要仅靠缩小字体解决截断。
- [ ] 浅色或深色可择一作为主视觉；至少对另一模式完成 QA。
- [ ] 颜色不是区分 Working/Idle/Failed 的唯一信息，状态文字可读。
- [ ] 截图中的 Caption 与 App 字体不会贴边、被灵动岛遮挡或进入圆角安全区。
- [ ] VoiceOver 标签、阅读顺序虽不会显示在截图中，仍须在同一 Build 验证。

## 7. 导出与文件检查

建议文件名：

```text
ios-zh-Hans-01-dashboard.png
ios-zh-Hans-02-agents.png
ios-zh-Hans-03-privacy.png
ios-zh-Hans-04-live-control.png
ios-zh-Hans-05-lock-screen.png
ios-zh-Hans-06-dynamic-island.png
ios-en-US-01-dashboard.png
...
```

- [ ] 原图像素与 App Store Connect 接受规格完全一致。
- [ ] 无 alpha；用图像检查工具验证，不只看扩展名。
- [ ] 不经过聊天软件压缩，不上传带色彩异常或模糊缩放的二次导出图。
- [ ] 不加虚假的系统控件、通知、评分、奖项、价格或“官方”字样。
- [ ] 不展示 Apple 未发布硬件或模仿其他产品的界面。
- [ ] 逐张与最终 Build 对照，所有数字、按钮和状态都能复现。
- [ ] App Store Connect 预览中检查顺序、裁切和每个本地化。

## 8. TestFlight 截图说明

TestFlight 邀请体验可以选择是否展示已批准版本的 App 信息和截图。首个尚未获批的 Beta 不应依赖商店截图解释核心设置；Beta App Description、What to Test 和审核步骤必须可以独立说明配对、同步与 Live Activity。外部 Beta 上传任何宣传截图前，同样执行本清单的隐私检查。
