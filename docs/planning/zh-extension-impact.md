# 中文扩展（普通话/粤语 → 简体中文）对架构与原生改写的影响分析

> **Status**: companion analysis, written 2026-09-09 against `main` (`56f8545`)。
> **输入**：`docs/adr/0004-mandarin-cantonese-dictation.md`（**proposed**）、
> [`docs/planning/requirements.md`](requirements.md) §5（**未生效**，以其 §5.13 为准）、
> [`docs/planning/technical-architecture.md`](technical-architecture.md)（架构现状，本文大量引用其章节）。
> 配套调研：[§6 替代转录模型候选](#6-替代转录模型调研桌面研究)。
> 代码（`main` `56f8545`）仍是 English-only；本文描述「若 ADR-0004 通过后」的系统性影响与
> 实施建议，并把“先决 spike/语料”列为落地闸门。

---

## 0. 结论摘要（TL;DR）

- **架构不阻塞**：transcription role、profile 化规则引擎、settings、supervisor 都已具备
  hook；ADR-0002 的两段式形态与 ADR-0001 的确定性清理对中文同样成立。
- **工作量集中在三处**：(1) 中文转录角色选型 + 实测（§6），(2) 规则引擎 zh profile
  （估 +300–400 行 + 全套测试），(3) `lang` 字段/转录 holder 切换等协调层小改。
- **对原生 Swift 改写的影响是“改变工程量与范围，不改变方向”**：zh rules 直接在 Swift 端
  `1:1` 落地最省事；转录角色是「选型/进程形态」问题，与 Electron→Swift 正交，可独立推进。
- **三个落地闸门（gates）未过前一律不实现**（ADR-0004 status / requirements §5.13）：
  zh 转录 holder 基准 → cmn/yue eval 语料 → 断句模型 zh gate。
- 与并行会话的交接：ADR-0004、requirements §5 已就位；**CONTEXT 术语、native-swift-rewrite
  §2a 修订、ROADMAP #252 收窄、holder spike + 双语料**仍为待办（§7）。

---

## 1. 范围与语言模型（速记）

- zh profile = `en | cmn | yue`（默认 en 保持现状）；口语 cmn/yue → **书面简体 zh-Hans**
  （无繁体/简繁切换功能；仅对 holder 输出的繁体/粤语口语字形做**确定性映射**）。
- 双语法并存：命令匹配是**文本层**的——同一批字符（`句号`、`新段落`、`蛇形命名`）普通话/
  粤语发音都命中；英文命令在中英混说时照常工作。
- 全量不变式（I1–I4、ADR-0001）对中文照旧：cleanup <1ms 确定性、断句只回序号、deny-by-default
  换行、听写路径永不聚焦窗口。

---

## 2. 模块级影响映射（逐层 delta）

> 列：“现状”（引用 technical-architecture.md 章节 / 文件）→ “zh 所需改动” →
> “风险/注意” → “建议（Electron 现状 vs Swift 改写）”。

### 2.1 协调层：dictationCoordinator / voiceEditCoordinator（§7/§8）

| 项 | 现状 | zh 改动 | 建议 |
|---|---|---|---|
| `lang` 字段 | JS 从不发送 → helper 默认 `.english`（§9.2） | **每次 transcribe 请求带 active `dictationLanguage`**（`en\|cmn\|yue`），这是协议本就预留的字段 | Electron 改 `transcription.transcribe(wav, prompt, lang)`；Swift 改写时同步进 adapter 接口 |
| profile 判定 | 无 profile 概念 | coordinator 或上游据 settings 选 en/zh cleanup profile + 对应分句 + Commands 文案 | profile 是**数据**不是分支地狱：`profile = resolve(settings.dictationLanguage)` 传入 cleanup/segmentation |
| 显式断句/换行降级 | #307/#320 en 语义 | zh 断句命令在非 break-safe App **整体丢弃**（中文无词空格，不能降级成空格——requirements §5.3.3） | 与 #307 one-line 覆盖、#355 app-switch guard 正交，逻辑位置不变 |
| paste（#375） | 7 个英文裸短语 | + `粘贴/粘贴剪贴板/粘贴出来`；其余限制不变 | 短语表参数化即可 |

### 2.2 转录角色：transcription-helper / supervisor（§9、§15）

| 项 | 现状 | zh 改动 | 建议 |
|---|---|---|---|
| holder | Parakeet TDT 0.6b v3（FluidAudio）硬编码 `AsrModels.downloadAndLoad(version:.v3)`，**无中文** | zh profile 换 holder（§6 候选）；en 可继续用 Parakeet | helper 启动参数化“加载哪个 holder”；Electron 现状 = 起不同 helper 配置；Swift 改写 = 同一进程内 AsrManager 实例化参数 |
| 协议 | NDJSON stdio：`ready` 门 / id `transcribe`(base64 wav) / 错误→exit(1) | 新 holder 必须讲**同一协议**（这是选型硬约束） | helper 是一个壳：换模型不换壳（现 143 行即是范式） |
| supervisor | 1s 重启、ready 门、单请求 30s、启动 gating（§15.3） | profile 切换 = 停旧起新（**永不同时驻两个语音模型**，ADR-0001 内存后果） | 冷切换秒级成本要记录成产品事实（Home “starting”） |
| 下载 | Parakeet ~470MB 由 FluidAudio 自动下；Setup parity 缺失 | zh 权重经 modelStore 首用下载/源码 stage；**大小先过 app-size guardrail** | §6 选型直接受大小约束；Setup 页 #249 parity 对 zh 角色同样适用 |

### 2.3 规则引擎：zh profile（§10 + requirements §5.3）

结构建议：**profile 参数化，而不是第二套引擎**——`cleanup(text, {profile, oneLineBox, breakSafe})`，
现有 en 15 步链 + zh passes 按 profile 切换；口语标点/重复机制共享触发模型。

zh passes（对应 requirements §5.3 全表）与 en 的差异点：

| zh pass | 关键规则 | 移植注意（同 §10.7 精神） |
|---|---|---|
| 1. 正字法规范化（新首步） | CJK 间不加空格；CJK 标点（`。，、；：？！「」《》（）》）周围不加空格；吞 holder 遗留 ASCII 空格；行换拍平为无（zh 无需 soft-wrap 折叠）；CJK+拉丁混合串**原样保留** | 多为字符类判定，比 en 正则更直白；但“吃 holder 在汉字串内留的空格”是 scan 类逻辑 |
| 2. 口语标点→全角 | 句号`。` 逗号`，` 问号`？` 叹号`！` 冒号`：` 分号`；` 顿号`、` 省略号`…… 破折号—— 括号（中文对）％ / 引号对 `“…”`（非贪婪） | 全角输出；`/`→`/`、`%`→`%` 仍半角（与 en 表不同，注意别用 en 表一把梭） |
| 3. 断行/列表（门控） | 新段落→`\n\n`、新行→`\n`、新圆点/项目符号→`\n- `、缩进→`\t`（句首）；**非 break-safe 时整条丢弃**（非降空格） | 吞尾随 `。！？，；：` 与两侧空白（对应 #320 的 zh 版） |
| 4. 数字/金额/百分比 | `零一二三四五六七八九十百千万亿` 数词解析→阿拉伯数字；`元/块/毛/角/分`→`¥`（`五十元`→`¥50`）；`百分之五十`→`50%`；粤语 `蚊/蚊雞` 初版静态表（`三蚊`→`¥3`） | `parseZhNumberWords` 纯函数 + 回调式替换 → Swift scan+range；沿用 en “绝不猜”原则 |
| 5. 自纠错 | `划掉/删掉`：紧邻上一子句、须停顿、名词在后不动（`删掉那个文件` 不触发） | 与 en SELF_CORRECTION 同构，grammar 参数化 |
| 6. 口头禅 | 单字组 `嗯 呃 啊 哎 哦 唔 诶`；短语 `就是说 怎么说呢 你知道 你懂的`；句首组 `那么 然后 其实 对了 好吧` | 语料驱动，初表非终表 |
| 7. 叠词例外 | 相邻重复折叠 **除外**：AA 动词/形容词（看看 试试 谢谢）、亲属（爸爸 妈妈）、AABB（高高兴兴） | 例外表与规则同置；这是 zh 最容易“过度清理”的点，必须穷举测试 |
| 8. 无大小写/无强制句末标点 | 去掉 en 的 `i→I`/句首大写/**不自动补 `.`**——只有说 `句号` 才出 `。` | 与 en 链的 capitalise/terminalPunct 分支 |
| 9. emoji（永不门控） | 笑脸🙂 爱心❤️ 点赞/太棒了👍 火焰🔥 大笑😂 哭😢 | 触发模型同 en |

估算：zh profile 净增 ~300–400 行 + 配套 `rules.zh.test`（每 pass 输出级断言），并把
`spell-out/currency/quote` 等 en 专属 pass 显式**跳过**（不重复实现）。

### 2.4 段落断句（§11 + requirements §5.4）

- 分句：zh 硬边界 `。！？…`（`；` 软边界）替代 en 的 `(?<=[.!?])\s+` 分句器。
- 契约不变：`BREAKS: 3, 7` / `LIST:` 序号、fail-closed repair 照旧。
- **模型质量 gate**：SmolLM2-1.7B 对中文未验证 → zh 断句仅当 holder 过 zh eval 集才 eligible；
  之前 zh 长文一律 prose（deny-by-default，绝不注入半吊子断句）。gate 未过前**不**为 zh 启用
  rewrite 调用（可把 eligible 判定参数化：`breakPlacementEnabled(profile)`）。
  **2026-09-23 已测：gate #3 FAIL**——走产品真实 adapter/parser、10 个作者基准用例 ×5 次：
  格式 **100% 合法**、句 1 违规 **0**，但与预期断点 **0/50** 吻合（几乎每句都断，单主题对照组
  也从不回 `none`），且 **8/48 次超产品 300 ms 超时**。→ **v1 zh 固定 prose，无需 zh prompt
  调参或换模型**；结果见 [`prototypes/zh-asr-holder-252/RESULTS.md`](../../prototypes/zh-asr-holder-252/RESULTS.md) §Gate #3。

### 2.5 语音编辑与命令语法（§8 + requirements §5.5）

- voiceEditCommands 语法表**加 zh 别名**（蛇形命名/驼峰命名/加引号/项目符号列表/复制/粘贴…），
  命中后变换逻辑不变（ASCII 目标）；新增 zh 散文包裹对：`“”` `‘’` `《》`。
- **identifier-case × CJK guard**：选区含汉字时 case 类变换 decline（case 对汉字无意义）；
  wrap/copy/paste/list 仍有效。
- carrier：zh `请… 把… 变成… 转换成… 改成… 换成…` 剥离，机制同 en。
- 列表标记 v1 用 ASCII `- `/`1. `；`1、` 为开放问题（§5）。
- 数据面：`commandReference.ts` + Commands 页分组**双语**；规则/语法/页面三处真源纪律不变。

### 2.6 粘贴（§5.6）：仅加 `粘贴` 三个整句触发；10k 上限、空剪贴板、多行 break-safe gate 不变。

### 2.7 设置（§15 / requirements §5.8）

- settings schema + `dictationLanguage: "en"|"cmn"|"yue"`（默认 en；validate 同现有白名单风格），
  需向后兼容（老 settings.json 无此键 → 默认 en）。
- Settings 页增加“语言/口语变体”控件（与现有三 section 并列）；UI 文案**保持英文**。

### 2.8 渲染层 / overlay 字体（§14 / §15 / requirements §5.8）

- JetBrains Mono **无 CJK 字形** → held-text、overlay `<pre>`、任何 mono 面加系统 CJK 回退
  （PingFang SC）；overlay 尺寸/排版用中文内容复检。CSS font stack 追加 fallback 即可。
- Commands 双语内容（§2.5）；过滤匹配中英文均可。

### 2.9 上下文/采集/生命周期（F6/F7/F9）：语言无关、不变——**唯 IME 是验证项**：

push-to-talk 与录制期 Escape 不得与激活的中文输入源（拼音/五笔/粤拼）打架——热键 tap 在
IME 消费前经 Input Monitoring 读到，理论上安全，但需真机 `zh-CN`/`zh-HK` 输入源验证；
若冲突则开新 issue，不改 F1。

### 2.10 词汇扫描（F11）：机制不变；zh holder 若有 keyword boosting 则接上（#322 泛化），
没有则忽略 prompt（= 今日 Parakeet 行为）。

---

## 3. 与原生 Swift 改写计划的相互作用

### 3.1 两条工作线的时间关系

zh 扩展（若采纳）与原生改写**共享最大一块工作：规则引擎**。两种走法：

| 走法 | 说明 | 代价 |
|---|---|---|
| **A. 改写先行，zh 后置** | 先把 en rules 1:1 移进 Swift（现有测试对拍），再把 zh profile 作为 Swift 规则引擎的 profile 参数 +300–400 行落地 | zh 只在 Swift 写一次；但 zh 上线推迟到改写后 |
| **B. zh 先行（Electron 内）** | 现在就把 en rules 参数化成 en/zh profile，落地 zh + 全套测试；改写时整包带过去 | en 侧也要经受一次“参数化重构”的回归风险；随后 Swift 移植 1:1 |

**建议：A（或 A′：现在只做 zh 需要的「参数化契约」设计与 eval，实现放 Swift 侧）**——zh 规则
细节（词表/叠词例外/粤语 token）由语料驱动，在实现前就需要 cmn/yue 语料，两件事本来就不该
抢同一批人。转录角色选型与改写方向正交，可立刻用 spike 推进（§6）。

### 3.2 native-swift-rewrite.md §2(a) 的修订点（并行会话 §5.13 待办之一）

- “reuse FluidAudio for ASR”只覆盖 en：zh 需要一个（或两个）不同 holder → 可行性表与
  端口面加“zh transcription role”行；规则移植面 +300–400 行（估）与配套测试；
- 建议把「transcription role = 可插拔 holder（protocol 契约固定）」写进新架构的边界定义。

### 3.3 进程隔离 / holder 切换（§17.3 沿用）

zh holder 若不内化（子进程形态，如 whisper.cpp/sherpa-onnx 二进制），则与 llama-server 同级：
Electron supervisor 管理、Swift 改写后 NSTask/Process 管理；若走 Apple SFSpeechRecognizer，
那是**系统 API 而非进程**——改写后进程内直调即可，且天然拿到「永不两个语音模型常驻」语义
（切换即 OS 层重配置，仍需实测延迟）。

---

## 4. 测试与验收计划（对齐 requirements §5.9）

| 层 | 内容 |
|---|---|
| zh rules 单元套件 | 每 pass 输出级断言：正字法、全角标点、门控断行（含非 break-safe 丢弃）、数字/金额/百分比、口头禅、**叠词例外**、自纠错守卫、zh-Hans 映射、中英混合不误伤 |
| 语法套件 | zh 别名命中/decline（CJK case guard、`删掉那个文件` 反例）、双语混说、carrier |
| 协调层 | `lang` 字段每请求携带、profile 路由、非 break-safe 断句词丢弃路径、paste zh 触发 |
| 语料 | **cmn 与 yue 各一 eval corpus**（照 #171 方法，但录制协议对准新 holder——旧 #171 配方 curl whisper-server 已废）；验收：暖机 sub-1s + 事先设定的准确率线 |
| 手工矩阵 | zh 语音编辑（含 CJK-decline 文案）、IDE 终端 dictation 中文、**IME 激活时听写**、overlay 中文渲染、双向 break-safe 口语断句 |
| 断句 gate | zh eval 集上 rewrite holder 表现 → 决定启用/降 prose |

---

## 5. 开放问题（落地前必须回答）

1. **zh 转录 holder**：§6 spike 结论；单 holder 服务双变体 vs 两个 holder；zh-Hans 映射表来源。
2. **断句 holder zh 能力**：zh-tuned 小模型，还是长期 prose（接受无自动分段）。
3. **粤语 token 清单**：金额（蚊…）、口头禅、口语词（初表 corpus-seeded 非终表）。
4. **编号列表标记**：ASCII `1. `（v1 默认）vs `1、`。
5. **IME 交互**：真机验证是否出新 issue。
6. **权重大小**：zh holder 下载量 vs `docs/planning/app-size.md` guardrail。
   **A0 实测**：fp16 471.5 MB / int8 225 MB，与 Parakeet（~470 MB）同量级 → 新增负担很小。
7. **许可证**（见 §6 候选表）：候选权重许可证是否满足本仓库「MIT 安装故事 + 无署名负担」的
   一贯立场（对照 `docs/research/model-licensing.md` 对 Llama 的拒绝理由）。**这是选型前置，
   不是后置**。**A0 / FunASR v1.1 初判**：无 "Built with" 展示义务、无 AUP 使用限制，只要求
   署名并保留模型名 → 可接受；遗留 §4.2（禁止贬损条款）与 §7（管辖地留空）待法务确认。
8. **`yue` 输出的书面语界定**（2026-09-23 A0 冒烟实测新增；同日探针补证）：SenseVoice 的
   yue 模式输出**粤语白话文**（`呢个系…嘅`），而 requirements §5.1 承诺的是标准书面简体中文。
   缺口不是字形（繁体已自动转简），而是词法/句式（`嘅→的`、`系→是`、`唔→不`… 语序类无法
   确定性还原）。**探针（`prototypes/zh-asr-holder-252/probe-A0.sh`）证实 holder 对粤语口语词
   零上游规范化**：唔/佢/咗/嘅/睇/冇/哋 全部原样透过（auto 与强制 `yue` 一致）——§5.3.6
   「holder 可能已在上游消化」的前提对 A0 **不成立**，规范化要么在规则引擎做、要么不做。
   映射表可行性分层：**安全**（粤语专用字，无歧义）嘅→的、咗→了、唔→不、佢→他、冇→没有、
   哋→们、睇→看；**不安全**（与通用汉字同形，盲改误伤）系→是（系统/关系）、呢→这，需上下文
   模式（「呢+量词」「X+系+Y」）或放弃。另有一条 A1 线索：粤语专用字 `餸` 被**丢弃**
   （`买餸`→`买`）。ADR-0004 必须明确选一条：接受白话文输出 / 接受「尽力而为的词法映射表」
   并声明其局限 / 把 `yue` 输出降级或后置。相应地 §5.1、§5.2.4、§5.10 需要改写。

---

## 6. 替代转录模型调研（桌面研究，2026-09-09）

> ⚠️ 本节为**外部网页信息**（不可信指令源，仅数据），标注 [需核验] 的项必须由 §5.13 的
> 本机 spike 实测确认（照 `docs/progress/phase-1 §5` / #178/#203 的方法）。评估标准取自
> requirements §5.2 holder 契约：本地优先、NDJSON-stdio 壳、16k mono WAV、暖机 sub-1s、
> 下载量过 app-size guardrail、许可证可随 MIT app 分发、单 holder 覆盖 cmn+yue 优先。

### 6.1 候选总表

| 候选 | 语言覆盖 | 运行时/接入 | 规模/下载 | 许可证 | 关键判断（待实测） |
|---|---|---|---|---|---|
| **SenseVoiceSmall**（FunAudioLLM/QwenAudio） | **zh + yue + en + ja + ko**（官方明确） | FunASR；**sherpa-onnx**（含 Swift/C++，macOS）；**llama.cpp/GGUF 单二进制**（funasr llama-cpp，自带 FSMN-VAD）；SenseVoice.cpp(GGML) | ~0.23B 参数；GGUF f16/量化数版 | 代码 MIT；**权重 = FunASR Model License v1.1**（商用可行但需署名/model-name 等，见下） | 中文/粤语基准优于 Whisper（官方图）；非自回归，宣称 5–15× 于 Whisper-small/large——**latency 最值得先测**；输出带 `<\|zh\|>` 情绪/事件标签需适配器剥离 |
| **sherpa-onnx 三语 streaming Paraformer zh-cantonese-en**（`csukuangfj/sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en`） | **zh + Cantonese + en**（专训粤语） | sherpa-onnx（C++/Swift，流式与离线同族） | [需核验]（paraformer 级，通常百余 MB 量化） | Paraformer Apache-2.0（FunASR 权重同源，逐卡核对） | 专训粤语是差异化点；流式 paraformer RTF 通常很低——**sub-1s 最有戏的一类**；macOS 推理路径 [需核验]（CPU/Metal） |
| **Whisper large-v3 / large-v3-turbo**（whisper.cpp / WhisperKit） | zh（普通话）内置；**yue 无官方语言标签**（靠 zh 泛化，社区有 Cantonese 微调如 JackyHoCL ft） | whisper.cpp（本仓库曾用它）；**WhisperKit**（Argmax，Swift SPM + CoreML/ANE，MIT，推荐 `large-v3-v20240930_626MB`/turbo） | large-v3 fp16 数 GB（turbo 压缩 626MB–1.5GB） | whisper 权重 MIT、whisper.cpp MIT、WhisperKit MIT | **仓库负面先例**：#310 曾在 FluidAudio 上试 large-v3-turbo → 加载 10–20s、每句数秒、超预算被否——换 whisper.cpp/WhisperKit 是否改观必须重测，不能默认 |
| **Apple SFSpeechRecognizer**（`zh-CN`/`zh-HK`） | 系统级（普通话/粤语[需核验 on-device 清单]） | 原生 API（Swift 改写后进程内直调） | 无自管下载 | 系统 API | 最契合“native rewrite + 永不两个语音模型常驻”；**离线/延迟/权限**须实测；macOS 26 “local voice” 新动向值得查证 |
| **Fun-ASR（QwenAudio，LLM-based ASR）**：Nano（zh/en/ja + 方言）、MLT-Nano（31 语） | 方言是卖点 | FunASR / vLLM / llama.cpp | [需核验] | FunASR 系 | 新技术、LLM 式解码延迟对 sub-1s 存疑；watchlist |
| （观察）Audio8-ASR-0.1B-iOS-ANE 等新兴 ANE 打包 | [需核验] | CoreML/ANE | 0.1B | [需核验] | 信息少，列为观察 |

#### 6.1.1 排除项记录：科大讯飞（星火）—— 2026-09-09 桌面核查

> **结论：讯飞星火名下没有适合本项目的开源、本地、macOS 可用中文 ASR，排除出候选表。**
> 形态证据（外部信息，需以官方最新页面复核）：
>
> 1. **云端 API**：讯飞语音识别（语音听写 / 语音识别大模型 / 录音文件转写等）是[开放平台在线服务](https://www.xfyun.cn/doc/)，
>    违背本项目「本地优先、音频不出机」核心（I1 邻居约束：无网络依赖）。
> 2. **官方「离线语音听写」= 商务授权 SDK**：《[离线语音听写服务说明](https://www.xfyun.cn/doc/asr/offline_iat/offline_iat-description.html)》
>    明文「离线听写目前只支持 **Android** 平台，不支持其他平台」；需控制台申请由商务回复，
>    试用 90 天 / 10 装机量、按装机量计费 → 无 macOS、无开放权重、不可再分发，与
>    OpenStream 的 MIT 分发立场（对照 `docs/research/model-licensing.md` 拒绝署名负担的先例）直接冲突。
>    同类形态见 [SDK 更新日志](https://www.xfyun.cn/doc/total_sdk_compliance/SDK_History.html)、
>    [AIKit 离线语音听写隐私政策](https://www.xfyun.cn/doc/total_sdk_privacy/aikit_offline_iat_privacy.html)。
> 3. **星火开源/端侧大模型 ≠ ASR**：2025 星火 13B 与 2026 端侧系列（
>    [星火 X2.5-4B/1.7B 端侧](http://article.pchome.net/content-2197754.html)、
>    [百万上下文端侧模型报道](https://news.qq.com/rain/a/20260901A09CT000)、
>    [“开源两款端侧模型”报道](https://www.donews.com/news/detail/4/6694943.html)）均为**文本 LLM**，不做语音转写。
> 4. **社区同名项目甄别**：GitHub `ywyuan666/spark-asr-dialect`（“讯飞星火方言语音识别大模型”，
>    Apache-2.0、~55M、9 方言含粤语、KeSpeech 训练）README 自述仅为**“受讯飞启发”**的第三方
>    复刻，性能表标注为“预期值”→ 非讯飞官方，只可当「多方言 NAR 小模型」研究线索。
>
> 若未来超出 ADR-0004 的 cmn/yue 范围要覆盖更多方言（川/闽/沪…），开源方向（FunASR/SenseVoice 系、
> KeSpeech 训练社区模型）比讯飞授权 SDK 更契合；讯飞能力只以云 API / Android SDK 形态存在，
> 不在 OpenStream 产品边界内。**免重查提示**：本条目先于任何候选重开讨论时查阅。

### 6.2 值得注意的事实与风险（每条给来源）

- SenseVoiceSmall 官方：ASR+LID 支持 zh/yue/en/ja/ko；非自回归端到端；宣称在相似参数量下
  比 Whisper-Small 快 5×+、比 Whisper-Large 快 15×；中文与粤语基准优于 Whisper
  （[SenseVoice README](https://github.com/FunAudioLLM/SenseVoice)）。注意其“rich transcription”
  会输出 `<|zh|>` 等标签与情绪/事件 token——适配层必须剥（对应 zh 规则正字法/适配器职责）。
- 许可证：SenseVoice 仓库代码 MIT；**官方权重走 FunASR Model Open Source License Agreement
  v1.1**——维护者澄清商用可行但需遵守署名/model-name（Section 2.2）等条款
  （[许可澄清 issue](https://github.com/QwenAudio/SenseVoice/issues/334#issuecomment-5083546605)、
  [模型卡](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)）。⚠️ 与本仓库
  `docs/research/model-licensing.md` 的立场（拒绝带署名/展示负担的 Llama）**直接相关**——
  选型前必须做同样的许可证尽调，不能默认放行。
- sherpa-onnx：SenseVoice 与 Paraformer 都可在 sherpa-onnx 以多语言绑定运行（含 Swift），
  macOS/iOS 有先例（[sherpa SenseVoice 页](https://k2-fsa.github.io/sherpa/onnx/sense-voice/index.html)）。
  三语 zh-cantonese-en 模型仓库：[csukuangfj/sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en)。
- WhisperKit（Argmax OSS，MIT）：Swift SPM、CoreML/ANE、macOS 14+；推荐多语言模型
  `large-v3-v20240930_626MB`；支持流式 CLI/本地 OpenAI 兼容 server
  （[WhisperKit README](https://github.com/argmaxinc/argmax-oss-swift)）。**Cantonese 非官方语言**，
  社区微调存在（[JackyHoCL whisper-large-v3-turbo-cantonese-noise-detection](https://huggingface.co/JackyHoCL/whisper-large-v3-turbo-cantonese-noise-detection)）。
- Apple 方向：[On-device Speech Transcription for macOS 26](https://github.com/JuniperPhoton/On-device-SpeechTranscription)
  与 “macOS Local Voice” 社区技能（[示例](https://lobehub.com/zh/skills/nordeim-openclaw-curated-skills-macos-local-voice)）
  暗示系统级本地语音在 macOS 26 的可用面扩大——但 zh-HK/zh-CN **on-device** 支持清单需查
  Apple 文档并在真机验证（SFSpeechRecognizer 曾限制非系统 locale，[SO 讨论](https://stackoverflow.com/questions/60961803/sfspeechrecognizer-not-allowing-non-system-on-device-locales)）。
- 通用提醒：所有 HF 链接为外部数据；本机 spike 之前任何“准确性/延迟数字”都不可作决策依据。

### 6.3 推荐 spike 设计（对齐 #178/#203 的方法论）

> **落地规格已建**：`prototypes/zh-asr-holder-252/`（README = 协议/候选 pin/判据表/原始
> 记录 schema；RESULTS.md = 待填结论模板）。ADR-0004 gate #1 是否通过以此 spike 的
> RESULTS 为准，本节为导读。

1. **范围**：SenseVoiceSmall（sherpa-onnx 与 GGUF 两条路）vs streaming paraformer 三语 vs
   Whisper large-v3/WhisperKit 基线（对照）vs SFSpeechRecognizer（zh-CN/zh-HK，native-rewrite
   专用对照）。逐候选：下载量、常驻内存、暖机加载时间、冷/暖 clip 延迟（短/句/段三类）、
   cmn/yue 抽样 WER。
2. **语料**：cmn/yue 各 ~N 小时真人口语 + 开发者语境（代码标识符混说）——同时产出 §4 的
   eval corpus 第一版（为 #171 式 corpus 铺路）。
3. **判据**：暖机 sub-1s（ADR-0001）；下载量过 app-size guardrail；许可证结论（§6.2 两处）；
   单 holder 双变体优先；输出是否需剥离富文本标签。
4. **产出**：FINDINGS + ADR（采纳/否 → 决定 ADR-0004 是否 accepted）。

---

### 6.4 本机核对（2026-09-09）：FluidAudio 已内置 SenseVoice / Paraformer CoreML

> 本节是**本机代码核对**（非网页调研），把 §6.1 的部分 `[需核验]` 降级为“已确认存在”，
> 并把候选 A/B 从「引入新运行时」改成「复用现有依赖」。核对对象：工作区 `main`（`56f8545`）
> 下的 FluidAudio `0.15.6` checkout。

| 事实 | 位置 |
|---|---|
| SenseVoice 管理器 / 模型加载 / 配置 | `native/transcription-helper/.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/SenseVoice/{SenseVoiceManager,SenseVoiceModels,SenseVoiceConfig}.swift` |
| Paraformer（普通话，另一条路） | `.../ASR/Paraformer/` |
| 权重仓库名 | `ModelNames.swift`：`senseVoiceSmall = "FluidInference/sensevoice-small-coreml"`、`paraformerLargeZh = "FluidInference/paraformer-large-zh-coreml"`；同文件另有 `nemotronMultilingual`、`cohereTranscribeCoreml`、`canary1bV2` |
| 语言覆盖 / 形态 | `Documentation/ASR/SenseVoice.md`：zh / yue / en / ja / ko 最强，`language = 0` 自动检测；非自回归 CTC（encoder+CTC 单次前向），ANE |
| 精度与硬件约束 | `SenseVoiceEncoderPrecision`：`.fp16`（默认，**必须 ANE**）、`.int8`（约半体积、ANE）、`.fp32`（非 ANE 回退）；fp16 在 CPU/GPU 路径会 NaN |
| 模型缓存与完整性 | `~/Library/Application Support/FluidAudio/Models/<repo>/`；`ModelHub.loadWithRecovery` 完整性校验 + 损坏重下 |
| 语言枚举的坑 | `Shared/TokenLanguageFilter.swift` 的 `Language`（约 25 种欧洲语言）是 Parakeet/多语 TDT 的过滤枚举；SenseVoice 走 `Int32` 语言索引，两者别混用 |

对 §6.1 候选表的修订：

- **A / B 合并为 A0（FluidAudio 原生）**：C2（NDJSON 壳）只需在现有 `transcription-helper`
  143 行范式上加“按语言选 manager”；C6（下载/镜像）由 FluidAudio `ModelHub` 承担；
  C7（不双常驻）与现 supervisor 一致（profile 切换 = 重启 holder）。
- **C（sherpa-onnx 三语 Paraformer）降为 fallback**：仅在 A0 的 yue 精度或许可证不过关时启用。
- **D（whisper large-v3 / WhisperKit）保留为对照**（#310 的负面先例仍须重测，但不再是首选）。
- **许可证闸门不变**：SenseVoice 权重适用 FunASR Model License v1.1（署名 / model-name 条件），
  与 FluidAudio 运行时的 MIT 是两件事——P1 仍须按 `docs/research/model-licensing.md` 的立场单独
  尽调，**不会因为打包进 FluidAudio 而消失**。
- **`zh-Hans` 输出**：SenseVoiceSmall 官方以简体中文为主；繁体 / 粤语口语字形的真实输出由 spike 的
  O1 行实测（`smoke/` 的 TTS 样本即可给出第一手结论，但**不计入准确率线**）。

> **可执行的冒烟路径**：本机 `say` 有 `Tingting`（zh_CN）与 `Sinji`（zh_HK），可先在
> `prototypes/zh-asr-holder-252/smoke/` 生成 16 kHz mono WAV，用 A0 打通“加载 → 转写 →
> 体积/延迟/字形/标点”这一串，把 L2/O1/O2/O3/S1/M1 变成实测值；A1/A2 的准确率线仍必须用
> 真人 cmn/yue 语料（§5.9）。

> **A0 冒烟已跑（2026-09-23；TTS 粗筛，不计入准确率线）**：M2 / 24 GB、macOS 26.6.2。
> 暖机推理 **131–280 ms**（2.9–26.0 s，含段落类），缓存加载 **465–658 ms**，首次含下载
> **720.9 s**（fp16 路径 471.5 MB，经 `REGISTRY_URL=https://hf-mirror.com`）。输出为简体
> 字形、**完全无标点**、**无 ITN**（口语数字原样输出，§5.3 pass 4 全归规则引擎）、无 `<|zh|>`/情绪标签；`yue` 输出是**粤语白话文**（`呢个系…嘅`）
> 而不是标准书面中文 → 新增开放问题 §5.8。
>
> **内存（M1，实测）**：holder 进程峰值 RSS 仅 **49 MB**（当前 Parakeet 为 38 MB——ANE
> 权重不计入进程 RSS），上游转换卡给出 **fp16 峰值 0.54 GB / int8 0.32 GB**；改写角色
> `llama-server` + SmolLM2 **实测 1463 MB**（`app-size.md` 的 ~1 GB 估计偏低约 45%）。
> **建议产品接线改用 int8 编码器**（225 MB 磁盘、上游验证精度中性）。
>
> **许可证（P1）**：权重为 **FunASR Model License v1.1**——§2.1 允许使用/修改/分发；
> **§2.2 必须署名来源/作者并保留模型名**；**无** "Built with" 展示义务、**无** AUP 使用
> 限制（这两条正是 `model-licensing.md` 拒绝 Llama 的理由）；§4.2 有禁止贬损条款、§7 管辖地
> 留空。结论：**可接受但需在 README/About 署名**，§4.2/§7 值得法务一眼。
>
> 完整表格、原始记录与判据对照见
> [`prototypes/zh-asr-holder-252/RESULTS.md`](../../prototypes/zh-asr-holder-252/RESULTS.md)。

---

## 7. 与并行会话的待办交接（requirements §5.13 checklist）

| 待办 | 状态（2026-09-09） |
|---|---|
| ADR 重开 ADR-0002（zh 入范围） | ✅ `ADR-0004`（proposed）已建，ADR-0002 头部已注 partially superseded |
| requirements §5 扩展规格 | ✅ 已在 `requirements.md`（未生效，§5.13 门控） |
| CONTEXT 加“profile/spoken variety/written output language” | ⬜ 未做（本文用了这三个词，采纳时补） |
| native-swift-rewrite §2(a) 修订 + 端口面/工时 | ⬜ 未做（§3.2 给出要点） |
| ROADMAP #252 收窄到本扩展 | ⬜ 未做 |
| holder spike + cmn/yue 语料 | ◐ A0 冒烟已跑（TTS：L1/L2/O1–O3/S1/M1/P1 全部落定，见 §6.4 与 RESULTS.md）；**真人 cmn/yue 语料未采集**——A1/A2 准确率线是 gate #1 唯一剩余缺口（采集规范：`prototypes/zh-asr-holder-252/samples/README.md`） |
| 断句 gate（#3，SmolLM2 zh） | ✅ 已测 **FAIL**（2026-09-23：格式 100%/句1 违规 0/与作者基准 0/50 吻合/8 次超 300 ms）→ **v1 zh 固定 prose**，无需 zh prompt 或换模型；结果与脚本在 `prototypes/zh-asr-holder-252/RESULTS.md` §Gate #3 |

---

*本文档与 ADR-0004 同生命周期：ADR-0004 accepted → 本文升级为实施基线并把 §6 换成 spike 结论；
被否 → 本文降级为研究记录。*
