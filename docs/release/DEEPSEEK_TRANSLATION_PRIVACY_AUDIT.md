# DeepSeek 翻译器公开资料审计

> 审计日期：2026-09-02。范围仅限 MAC版灵动岛--Agent运行监测 当前默认 DeepSeek API 接入与 DeepSeek 官方公开资料。本文是发布决策记录，不是法律意见，也不把通用隐私政策当作 API 数据处理附件。

## 1. 结论

- **技术接入符合当前官方文档。** 默认 Base URL `https://api.deepseek.com`、`POST /chat/completions`和模型 `deepseek-v4-flash` 都是 2026-09-02 官方文档列明的有效值。
- **JSON 请求方式符合官方指南。** 当前请求使用 `response_format: {"type":"json_object"}`，系统指令明确要求 JSON 并给出所需结构，也设置了 `max_tokens`。
- **不能声称 DeepSeek API 请求“不保留”或“不用于训练”。** 官方公开资料没有给出适用于本下游应用请求的固定保留期或 API 专用的不训练承诺。
- **通用政策只能作为风险基线。** DeepSeek 公布的中文隐私政策称，它所覆盖的境内运营中收集和产生的个人信息存储于中华人民共和国境内，输入/输出可能在去标识化等条件下用于模型训练和服务优化；但该政策同时明确，下游应用终端用户的具体处理规则不在其说明范围内。
- **发布方仍是下游应用的责任方。** DeepSeek 开放平台服务协议要求开发者在提供服务前告知个人信息处理规则，并为委托 DeepSeek 处理取得同意或其他合法性基础。现有“只在首次向该目的地发送前确认”是有用基础，但告知内容不足。

## 2. 官方证据

| 主题 | 官方资料 | 审计结果 |
| --- | --- | --- |
| Base URL 与当前模型 | [DeepSeek 首次 API 调用](https://api-docs.deepseek.com/) | 列明 `https://api.deepseek.com`、`deepseek-v4-flash`、`deepseek-v4-pro` 和实验性视觉模型。 |
| Chat Completions | [Chat Completions API](https://api-docs.deepseek.com/api/create-chat-completion/) | 列明 `POST /chat/completions`、`messages`、模型字段和 `response_format`。 |
| JSON Output | [JSON Output](https://api-docs.deepseek.com/guides/json_mode/) | 要求 `json_object`、在 prompt 中提到 JSON 并提供目标格式，合理配置 `max_tokens`。 |
| 开放平台责任边界 | [DeepSeek 开放平台服务协议](https://cdn.deepseek.com/policies/zh-CN/deepseek-open-platform-terms-of-service.html) | 2026-04-29 生效版要求开发者披露下游应用处理规则，为委托处理取得合法性基础，并响应用户权利请求。 |
| 通用隐私基线 | [DeepSeek 隐私政策](https://cdn.deepseek.com/policies/zh-CN/deepseek-privacy-policy.html) | 2026-02-10 生效版描述输入、IP/设备/日志等处理，境内存储、通用保留原则与可能的模型训练/优化；同时排除下游应用终端用户的具体处理规则。 |
| 英文跨境告知基线 | [DeepSeek Privacy Policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html) | 公开英文政策同样说明在中华人民共和国处理/存储其所覆盖的 Personal Data，但不覆盖下游应用终端用户的具体规则。 |

## 3. 当前实现核对

| 检查项 | 当前实现 | 结果 |
| --- | --- | --- |
| 默认目的地 | `Native/AgentIsland.m` 中为 `https://api.deepseek.com` | 符合官方文档 |
| 默认模型 | `deepseek-v4-flash` | 当前官方可用模型 |
| 请求路径 | 在 Base URL 后追加 `/chat/completions` | 符合官方 API |
| JSON 模式 | `response_format.type=json_object`，prompt 含 JSON 目标结构，`max_tokens=1200` | 符合官方必要条件；8,000 字符长文本仍需做真实端点截断测试 |
| 请求字段 | 正文、源/目标语言、模式、解释语言、模型、系统指令、API Key | 现有发布隐私文档已列明 |
| 发送时机 | 只在用户点击“仅翻译”或“学习解析”后 | 符合现有说明 |
| 首次同意 | Web 层按目的地 origin 记录首次确认 | 有同意机制，但仅告知“由提供方决定”，未告知默认 DeepSeek 的中国处理/存储基线、可能训练/优化及无固定 API 保留期证据 |

## 4. 发布前精确差距

1. **应用内告知不足。** 现有持续提示和首次 `confirm` 只显示 origin，没有区分默认 DeepSeek 与用户自定义端点，也没有告知上述公开风险基线。
2. **缺少可点击的供应商政策链接。** `window.confirm` 无法放链接；如保留默认 DeepSeek，应改为自定义对话框，在确认前同时提供 MAC版灵动岛--Agent运行监测 隐私政策、DeepSeek 隐私政策和开放平台协议链接。
3. **无法完成“不保留/不训练”证明。** 公开材料没有给出 API 专用的固定保留期、不训练承诺或下游终端用户数据处理附件。上线负责人应向供应商取得可归档的 API 专用答复/条款，或接受保守披露，或取消默认远程供应商。
4. **App Privacy 目的尚未锁定。** 如供应商可保留输入并用于训练/优化，除 User Content 的 App Functionality 外，还必须按提交时 Apple 定义重新评估其他处理目的；在取得 API 专用证据前不得勾选 `Data Not Collected`。
5. **发布站隐私页仍是通用表述。** `release-site/app/{privacy,en/privacy}/page.tsx` 需在部署前与本审计和最终端点决策同步。

## 5. 建议的应用内文案（尚未改源码）

### 持续提示（中文）

> 提交后，当前文本、语言/模式、模型名和结构化指令会发送至 {destination}。若使用默认 DeepSeek 端点，请先查看数据地区、保留和可能的训练/优化说明；请勿提交敏感或无权披露的内容。

### 首次确认（中文）

> 是否允许将当前输入发送至 {destination}？如果这是默认 DeepSeek 端点：DeepSeek 的公开政策称，其所覆盖的个人信息在中华人民共和国境内处理/存储，输入可能用于模型训练和服务优化；但该政策明确不说明下游应用终端用户的具体处理规则，也未公布固定 API 请求保留期。请先查看隐私政策，并确认你有权发送该内容。

### Persistent notice (English)

> After submission, the current text, language/mode, model name, and structured instructions are sent to {destination}. If you use the default DeepSeek endpoint, first review the disclosed data location, retention, and possible training/service-improvement practices. Do not submit sensitive or unauthorized content.

### First-use confirmation (English)

> Allow the current input to be sent to {destination}? For the default DeepSeek endpoint, DeepSeek's public policy says the personal data it covers is processed/stored in the People's Republic of China and inputs may be used for model training and service improvement. That policy expressly does not describe the specific processing rules for end users of downstream apps, and no fixed API-request retention period is published. Review the privacy notice first and confirm that you are authorized to send this content.

## 6. 发布决策

三种可接受路径，三选一后才能锁定隐私政策和 App Privacy：

1. **保留 DeepSeek 为默认。** 实施上述分层告知和链接，按可能保留/训练的保守口径披露，并完成目标销售地区的法律审查。
2. **保留自定义端点，但不内置默认远程供应商。** 用户必须先配置端点和密钥；应用仍需披露用户选择的端点可能保留数据。
3. **首发仅开放本机 loopback 服务。** 隐私边界最清晰，但使用门槛最高，且要做可用性与审核演示设计。
