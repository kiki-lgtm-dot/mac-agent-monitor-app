# App Store 最终截图目录

这里仅放从最终签名、可复现提交 Build 截取的商店原图。当前 `docs/media` 中 1280×960 的英文演示图与 1280×820 的中文演示图只是开源仓库的功能示意：尺寸不属于 Apple 接受的 Mac 截图规格，不能上传 App Store Connect；`docs/screenshots` 继续只用于本地界面走查并保持忽略。

最终文件按平台和语言放置：

```text
docs/release-assets/
  macos/zh-Hans/*.png
  macos/en-US/*.png
  ios/zh-Hans/*.png
  ios/en-US/*.png
```

图片目录本身不是发布证据。还必须按
[`STORE_SCREENSHOT_EVIDENCE.schema.json`](../release/STORE_SCREENSHOT_EVIDENCE.schema.json)
创建仓库内但保持忽略的 `.release/store-screenshot-evidence.json`。如需改用其他位置，
只能通过 `AGENT_ISLAND_STORE_SCREENSHOT_EVIDENCE` 指向规范化的仓库相对路径；校验器拒绝
绝对路径、符号链接和越出仓库的路径。

证据文件为每个平台各记录一项候选，包含正式 Bundle ID、版本、Build、`dist/` 中精确
候选包的路径与 SHA-256，以及上述目录中每张最终截图的路径、SHA-256、语言、设备、UTC
截取时间和 `source: "exact-candidate-build"`。每张图的四项人工声明必须均为 `true`：
`exactCandidateBuild`、`localizedForLocale`、`noSensitiveDataReviewed`、
`notStretchedOrSynthetic`。这四项只是具名人工复核结论，校验器仍会独立检查文件、格式、
尺寸、透明通道、路径和哈希；它不会凭声明推断真实设备或正确翻译。

候选包还必须与 `.release/app-privacy-evidence.json` 中已验证的同一平台 archive 精确匹配。
中英文目录必须使用真正对应语言的不同截图，跨语言复用相同图片字节会失败。正式截图与
这两份 `.release` 证据通常包含候选发布状态，提交前应留在受控发布工作区，不要把真实
设备信息或审核附件直接提交到公开仓库。

门禁命令：

```bash
node scripts/validate-store-submission.mjs
node scripts/validate-store-submission.mjs --release
```

普通模式验证中英文元数据字段限制、iOS 图标尺寸/透明通道，并报告待补素材。`--release` 还要求四组截图各有 1–10 张、无透明通道且尺寸符合当前目标规格，证据文件与截图及精确候选一一绑定，同时检查 macOS/iOS 商店元数据、审核说明、中英文隐私政策和 App Privacy 工作表中的占位符/“草案”标记；任一项未完成都必须失败。

当前门禁固定采用 Apple 支持的 Mac 规格 1280×800、1440×900、2560×1600、2880×1800，以及 6.9 英寸 iPhone 原始截图规格。若 Apple 后续改变规格，先核对官方页面，再同步更新脚本和本文件：

- [Apple Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Apple App information field limits](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Apple Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)

不要用拉伸、AI 重绘或人工伪造的数据替代真实系统截图。iPhone 的锁屏 Live Activity 与 Dynamic Island 图必须来自真实签名 Build；Mac→iPhone 私有同步也必须先在同一 iCloud 账号的真机链路验收。
