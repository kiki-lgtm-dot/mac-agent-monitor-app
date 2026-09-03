# App Store 最终截图目录

这里仅放从最终签名、可复现提交 Build 截取的商店原图。当前 `docs/media` 中的 1280×960 演示图只是开源仓库的功能示意：尺寸不属于 Apple 接受的 Mac 截图规格，不能上传 App Store Connect；`docs/screenshots` 继续只用于本地界面走查并保持忽略。

最终文件按平台和语言放置：

```text
docs/release-assets/
  macos/zh-Hans/*.png
  macos/en-US/*.png
  ios/zh-Hans/*.png
  ios/en-US/*.png
```

门禁命令：

```bash
node scripts/validate-store-submission.mjs
node scripts/validate-store-submission.mjs --release
```

普通模式验证中英文元数据字段限制、iOS 图标尺寸/透明通道，并报告待补素材。`--release` 还要求四组截图各有 1–10 张、无透明通道且尺寸符合当前目标规格；缺少最终产品名或截图时必须失败。

当前门禁固定采用 Apple 支持的 Mac 规格 1280×800、1440×900、2560×1600、2880×1800，以及 6.9 英寸 iPhone 原始截图规格。若 Apple 后续改变规格，先核对官方页面，再同步更新脚本和本文件：

- [Apple Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Apple App information field limits](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Apple Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)

不要用拉伸、AI 重绘或人工伪造的数据替代真实系统截图。iPhone 的锁屏 Live Activity 与 Dynamic Island 图必须来自真实签名 Build；Mac→iPhone 私有同步也必须先在同一 iCloud 账号的真机链路验收。
