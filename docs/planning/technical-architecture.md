# OpenStream 技术原理与架构总览（Technical & Architectural Deep Dive）

> **Status**: living reference, written 2026-09-08 against `main` (`56f8545`)；正文经对源码
> 的逐文件细读与多人（多代理）交叉核对，锚点为文件相对路径 + 行号。
>
> **Session note (2026-09-09)**：编写期间，仓库文档集新增了中文扩展规格——[`requirements.md`](requirements.md)
> §5（Extension — Chinese input/output support）与 [`ADR-0004`](../adr/0004-mandarin-cantonese-dictation.md)
> （status: **proposed**，普通话/粤语 → 简体中文），并把 [`ADR-0002`](../adr/0002-no-one-model-dictation-engine.md)
> 标为 partially superseded。**代码（`main` `56f8545`）未变**：本文档的管道/架构事实照旧成立；
> 语言范围表述已按“扩展已拟议、尚未生效”更新（§2.1 / §9.2 / §17.2 / §18.3）。
> **配套文档**：[`zh-extension-impact.md`](zh-extension-impact.md) = 中文扩展对架构/原生改写的
> 影响分析与替代转录模型调研（SenseVoiceSmall / sherpa-onnx 三语 Paraformer / Whisper / SFSpeechRecognizer…）。
> **Purpose**: 系统性讲清 OpenStream「功能特性 → 技术原理 → 架构设计」，作为后续
> **原生 Swift 改写（native rewrite）与迭代**的工程地基。建议先通读一遍再当参考书用。
>
> 与三份文档配合阅读：
> - [`docs/planning/requirements.md`](requirements.md) —— 逐条功能/UI 规格（从当前 `main`
>   1:1 抽取；本文件 §3 是其浓缩导读，冲突时以 requirements 与代码为准）
> - [`docs/planning/native-swift-rewrite.md`](native-swift-rewrite.md) —— 原生改写可行性研究
>   （「四桶拆分」与风险清单；本文件 §17 与其衔接并细化成行动项）
> - [`docs/progress/phase-{1..4}-progress.md`](../progress/) —— 工程沿革/深度回顾
>   （每个设计决策背后的实测与事故）
>
> 术语表见 [`CONTEXT.md`](../../CONTEXT.md)（**角色命名、避免用词**都必须遵守）。

---

## 目录

1. [三十秒架构速览](#1-三十秒架构速览)
2. [产品定位与设计立场](#2-产品定位与设计立场)
3. [功能特性总览（功能 → 代码 → 文档映射）](#3-功能特性总览功能--代码--文档映射)
4. [总体架构：分层、进程与协议](#4-总体架构分层进程与协议)
5. [构建、安装与运行](#5-构建安装与运行)
6. [主进程：生命周期、窗口与 IPC](#6-主进程生命周期窗口与-ipc)
7. [一次听写端到端：状态机、时序与结局矩阵](#7-一次听写端到端状态机时序与结局矩阵)
8. [语音编辑与粘贴命令](#8-语音编辑与粘贴命令)
9. [转录层：Parakeet / FluidAudio / transcription-helper](#9-转录层parakeet--fluidaudio--transcription-helper)
10. [规则清理引擎（rules.js）](#10-规则清理引擎rulesjs)
11. [段落断句：改写模型服务器与契约](#11-段落断句改写模型服务器与契约)
12. [上下文检测、换行安全与文本注入（原生层）](#12-上下文检测换行安全与文本注入原生层)
13. [热键系统（hotkey-helper）](#13-热键系统hotkey-helper)
14. [渲染层（React UI）与 Overlay](#14-渲染层react-ui-与-overlay)
15. [模型存储 / 下载 / 词汇扫描 / 权限 / 设置](#15-模型存储--下载--词汇扫描--权限--设置)
16. [测试与质量策略](#16-测试与质量策略)
17. [对原生 Swift 改写的结论与行动项](#17-对原生-swift-改写的结论与行动项)
18. [附录：参考文档、遗留路径与开放问题](#18-附录参考文档遗留路径与开放问题)

---

## 1. 三十秒架构速览

OpenStream 是 **本地优先（local-first）的 push-to-talk 语音听写 App**：按住热键说话，
松手，清理后的文本落到**前台 App 光标处**。声音与文字全程不出本机、无账号、无遥测。

技术形态是「**Electron 外壳 + 三个独立 Swift 原生 helper + 两个模型角色**」：

```
┌────────────────────────────────────────────────────────────────────────┐
│ Electron 主进程 (electron/main.js) —— 窗口/tray/菜单/IPC/生命周期/监督     │
│  ├─ React 主窗口 (src/**)   ├─ push-to-talk overlay 窗   ├─ 隐藏 capture 窗 │
│  └─ spawn 并监督以下子进程                                              │
│       hotkey-helper (Swift)      —— CGEventTap 全局热键, Input Monitoring │
│       accessibility-helper (Swift)—— AX 上下文/选区/注入, Accessibility   │
│       transcription-helper (Swift)—— Parakeet TDT 0.6b v3 转录 (FluidAudio)│
│       llama-server (C++ 预编译)   —— 改写模型角色: 只回"断句句子序号"      │
│       (dormant) whisper-server    —— whisper.cpp 旧转录路径, 保留未接线     │
└────────────────────────────────────────────────────────────────────────┘
```

四条支撑全文的设计立场（各有 ADR / issue 记录，见 §2）：**确定性清理**（规则引擎 <1ms，
ADR-0001/0002）、**deny-by-default 换行安全**（#19/#307）、**进程隔离**（热键与注入分开，
AGENTS.md）、**听写路径永不开/不聚焦桌面窗口**（AGENTS.md）。

**三个层各司其职（理解本架构的关键）**：
- `electron/dictationCoordinator.js` 等 = **结局决策状态机**（hexagonal、adapters 注入、纯逻辑）；
- `electron/main.js` = **端到端编排**（热键/窗口/时序胶水、监督子进程）；
- 三个 Swift helper = **原生能力**（热键 tap / AX 注入决策 / 转录），Electron 只做监督与
  stdio 协议客户端——注入的最终决策其实在 Swift 侧 `InjectionEngine`。

---

## 2. 产品定位与设计立场

### 2.1 一句话定位与目标用户

本地优先、为开发者设计的 macOS 语音听写：在 VS Code / 终端 / Notes / 聊天框里
按住快捷键说话，松手文字落到光标处。相比 Wispr Flow（订阅+账号+云端）与系统自带听写，
差异点是**本地、免费、可审计**，以及一个很窄但很关键的安全立场（§2.2 I2）。
当前语言范围：**English-first**（产品层仅英语；底层 Parakeet v3 多语言但未接出，见 §9.2）。
> ⚠️ 会话期间仓库新增**拟议**中文扩展（requirements §5 + ADR-0004，尚未生效）：计划加 zh
> profile（普通话/粤语 → 简体 zh-Hans）；若采纳，本节与 §9.2 需随之修订（见文首 Session note）。

### 2.2 四条不可动摇的设计立场（invariants）

| # | 立场 | 一句话 | 记录位置 |
|---|---|---|---|
| I1 | **确定性清理，不改写用户文字** | 听写管道里没有 LLM 重写：规则引擎 <1ms 完成清理；断句模型只回句子序号、永不回文本 | ADR-0001（+#45 部分取代）、ADR-0002、`CONTEXT.md`、`electron/cleanup/rules.js` |
| I2 | **deny-by-default 换行安全** | 文字中的字面 `\n` 可能执行半截命令/发出未完成消息 → 只有白名单 App（break-safe）才允许换行 | `CONTEXT.md`（Break-safe application）、`electron/breakSafety.js`、#19/#307 |
| I3 | **进程隔离是刻意的** | 热键（Input Monitoring）与 AX 注入/上下文（Accessibility）是两个独立 Swift 进程：一次卡死的 AX 调用不能拖垮全局热键 | `native/hotkey-helper` 头注释、README、phase-1 §3、native-swift-rewrite risk #2、AGENTS.md |
| I4 | **听写路径永不开/不聚焦桌面窗口** | `createWindow/show/focus` 只允许从用户动作触发（tray / Dock activate / second-instance / 首启 / 菜单） | `AGENTS.md`、`docs/research/issue-208-electron-dock-focus.md`、requirements 不变式 1 |

**连带的设计语言**（issue-driven 历史，改/写时必须保留）：

- **名词按角色、不按模型**：Transcription model server（现 Parakeet）、Rewrite model
  server（现 llama-server + SmolLM2）——模型是谁是独立开放问题（ADR-0002/0003）。
- **显式触发词，绝不做意图猜测**：所有口语命令（标点/emoji/纠错/列表）都要明确的短语；
  一个误判会静默污染已听写文字，比“没帮上忙”严重得多。
- **失败要可诊断、结局要可分类**：一次听写的结局是 `delivered / held / failed(stage) /
  no-speech / empty / info / pasted` 之一；转录成功的文字**永远不许丢**——放不下就 Held。
- **改一次行为先看对应文档**：`CONTEXT.md`（术语）、`docs/adr/`（为什么）、
  `docs/progress/`（历史），`AGENTS.md` 是硬约束。
- **显式 + 可复现的构建**：模型/二进制从 pinned revision 获取并 SHA-256 校验；任何“同一产物
  两条获取路径”都会导致诡异事故（#172 双构建系统）。

### 2.3 用户故事速览

1. **普通听写**：按住热键说一段话 → 文字落在当前编辑器/文档光标处。
2. **终端安全**：在 iTerm/VS Code 终端里说 "new paragraph" 不会被换行提交命令——非
   break-safe App 中显式断句命令**降级为空格**并打诊断日志。
3. **语音编辑**：先选中代码，说 "snake case" / "wrap in backticks" / "bullet list" /
   "copy that" → 确定性变换后落回原位。
4. **语音粘贴**：整句只说 "paste" → 剪贴板内容经注入管道到光标处（多行同受换行安全约束）。
5. **放不下的结果**：目标切换、AX 读不到、目标不接受换行 → 文字保留在 overlay 面板
   Copy / Dismiss 手动处理（Held result / Held edit）。
6. **首次使用**：模型缺失 → Setup 页下载（rewrite 角色）；权限缺失 → Permissions 页。

---

## 3. 功能特性总览（功能 → 代码 → 文档映射）

> 浓缩导读 `docs/planning/requirements.md`（F1–F15、U1–U9）；行为细节与历史 issue 以
> requirements 与代码为准。

### 3.1 功能需求 F1–F15

| 编号 | 功能 | 一句话 | 主要实现 | 备注 |
|---|---|---|---|---|
| F1 | Push-to-talk 听写（核心闭环） | 按住说话→松手处理→注入光标；Escape 取消；卡键超时强制停止；有选区则走语音编辑 | `dictationCoordinator.js`、`pushToTalkCoordinator.js`、`capture/capture.js` | #134/#140/#355；详见 §7 |
| F2 | 规则清理引擎 | 确定性清理每段听写，<1ms；除断句外全部由它做 | `cleanup/rules.js` | 详见 §10；ADR-0001 |
| F3 | 段落断句（改写模型） | break-safe+非单行+无显式断句+≥3 句时问模型“哪些句号后分段”，只回序号 | `paragraphBreaks.js`、`rewriteModelServer.js`、`breakPlacementHttpAdapter.js` | 详见 §11；#67/#125 |
| F4 | 语音编辑（选区变换） | 对已选文本说命令做确定性变换，无模型 | `voiceEditCommands.js`、`voiceEditCoordinator.js` | 详见 §8；#17/#222 |
| F5 | 粘贴命令 | 整句只说 paste 时把剪贴板放光标（空/超长/多行各有限制） | `dictationCoordinator.js`（paste 分支） | #375；详见 §8 |
| F6 | 上下文检测与换行安全 | AX 解析前台 App bundleId + 焦点字段角色；白名单 deny-by-default | `accessibilityHelper.js` ↔ `native/accessibility-helper`、`breakSafety.js` | #181/#307/#355/#227；详见 §12 |
| F7 | 麦克风采集 | 16kHz/16-bit PCM mono WAV；音频图常驻、电平 RMS 归一化 | `capture/capture.js` | #33；research/issue-33 |
| F8 | 转录（Parakeet） | Parakeet TDT 0.6b v3 CoreML/ANE via FluidAudio；stdio JSON helper | `native/transcription-helper`、`transcriptionHelper.js` | ADR-0003；详见 §9 |
| F9 | 模型服务器生命周期 | 两个常驻模型进程随 app 启停；监督重启；health 区分 ready/starting | `main.js`、`modelSupervisor.js` | 详见 §15 |
| F10 | 设置持久化 | 单个 JSON（hotkey/breakSafeApps/vocabularyProjectPath/windowBounds） | `settingsStore.js` | 详见 §6.4/§15 |
| F11 | 代码词汇扫描 | git 扫描标识符→top150 词→<800 字符 prompt→缓存 | `vocabularyScanner.js`、`vocabularyCache.js` | 后端+IPC 完整、UI 未挂载（§14.5） |
| F12 | 模型下载与首启 | rewrite 权重源码安装即 stage/打包首启下载；转录权重 FluidAudio 自动下载 | `modelStore.js`、`scripts/*` | 详见 §15；#249 |
| F13 | 权限（TCC） | Accessibility + Input Monitoring 必需、Mic 可选；启动探测并门控 | `permissions.js`、accessibility-helper `permissions`、`scripts/doctor.mjs` | #47/#46/#88；详见 §15 |
| F14 | App 生命周期与外壳 | 单实例、Dock App、关窗退 tray、Quit 显式、首启开窗 | `main.js`、`windowState.js` | 详见 §6 |
| F15 | Overlay 与 Held result | 录音 HUD；Held 结果面板 Copy/Dismiss；置顶/跨桌面/贴底 | `overlay/*`、`overlayPosition.js`、`heldResultController.js` | 详见 §14 |

### 3.2 界面需求 U1–U9（概要）

| 编号 | 内容 | 说明 |
|---|---|---|
| U1 | 主窗 chrome | macOS 原生窗口（traffic lights + hiddenInset），`vibrancy: hud` + 透明，820×640 / min 560×440，几何持久化 `windowState.js` |
| U2 | 工具栏 | wordmark `~ openstream` + 分段控件 Home / Commands / Settings（Permissions、Setup 是 gate 页非 tab） |
| U3 | Home | hero（状态文案 + Mark）、shortcut card、System card 健康行（~4s 轮询）、live dictation 状态 |
| U4 | Commands | 可搜索“说什么→变什么”参考，数据源 `commandReference.ts`（真源 rules.js / voiceEditCommands.js） |
| U5 | Settings | 快捷键捕获、按 App 换行白名单 chips、开机自启（vocabulary UI 未挂载） |
| U6 | Permissions | 两个必需 grant + Mic，状态 pill、深链系统设置、Re-check / Continue |
| U7 | Setup | 首启模型下载进度（单活动角色：check/download/done、百分比、重试）；关窗不停下载 |
| U8 | Overlay HUD | 玻璃小面板 ~244×50：状态词 + 7-bar 波形；Held result 扩为 ~432×264 可交互 |
| U9 | 视觉 | dark-only “blue glass”（`#0A1420` 底 + 蓝 accent），JetBrains Mono 仅用于字面字符 |

---

## 4. 总体架构：分层、进程与协议

### 4.1 分层总览

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 1. UI 层（Electron 渲染进程）                                              │
│    · 主窗口：React 18 + TS + Vite (src/**)，五视图（Home/Commands/         │
│      Settings + gate 页 Permissions/Setup），经 preload contextBridge       │
│      暴露的 window.openstream 与主进程通信                                 │
│    · push-to-talk overlay 窗 (electron/overlay/*)：录音 HUD + Held 面板     │
│    · capture 窗（隐藏，electron/capture/*）：Web Audio 采麦克风 → WAV        │
├──────────────────────────────────────────────────────────────────────────┤
│ 2. 协调层（Electron 主进程, electron/main.js 为主）                         │
│    · 生命周期/窗口/tray/菜单/单实例/错误处理                                 │
│    · IPC 注册（ipcMain ↔ renderer/overlay/capture）                        │
│    · 监督全部子进程；把 helper 事件转成听写/语音编辑状态机                    │
│    · 纯逻辑核心（hexagonal，可注入 adapters）：dictationCoordinator、       │
│      voiceEditCoordinator、cleanup/rules、paragraphBreaks、breakSafety、   │
│      settingsStore、modelStore、permissions、appBundleId、windowState…     │
├──────────────────────────────────────────────────────────────────────────┤
│ 3. 原生集成层（独立 Swift 可执行文件，stdio JSON lines 协议）                │
│    · hotkey-helper        —— CGEventTap 全局热键（Input Monitoring）        │
│    · accessibility-helper —— AX 上下文/选区读取/文本注入（Accessibility）    │
│    · transcription-helper —— Parakeet TDT 0.6b v3（FluidAudio, CoreML/ANE） │
├──────────────────────────────────────────────────────────────────────────┤
│ 4. 模型层                                                                    │
│    · llama-server（C++ 预编译, resources/bin/llama/）—— 改写模型角色：        │
│      HTTP chat-completions，只答断句序号                                     │
│    · FluidAudio（SPM 依赖）—— Parakeet CoreML bundle 下载/加载/推理           │
│    · （dormant）whisper-server —— whisper.cpp 旧转录路径，保留未接线           │
└──────────────────────────────────────────────────────────────────────────┘
```

### 4.2 常驻进程/组件清单

| 组件 | 语言 | 权限 | 谁拉起 | 就绪信号 | 通信 | 崩溃策略 |
|---|---|---|---|---|---|---|
| Electron 主进程 | JS (CJS) | — | `electron .` | — | ipcMain + spawn | 见 §6.6 |
| 主窗口渲染进程 | React/TS | — | main.js | did-finish-load | window.openstream 桥 | Electron 默认 |
| overlay 渲染进程 | 原生 JS | — | main.js | — | 桥 + ipcMain | 同上 |
| capture 渲染进程 | 原生 JS (Web Audio) | Microphone | main.js（隐藏） | — | ipcMain | 同上 |
| hotkey-helper | Swift | Input Monitoring | main.js（`hotkeyHelper.js`） | stdout `ready` | 单向事件 stdout | supervisor 1s 重启 |
| accessibility-helper | Swift | Accessibility | main.js（`accessibilityHelper.js`） | stdout `ready` | 请求/响应 stdio JSON（id 配对，3s 超时） | supervisor 1s 重启 |
| transcription-helper | Swift | Microphone(经宿主) | main.js（`transcriptionHelper.js`，权重就绪后） | stdout `ready`（模型加载后才发） | 请求/响应 stdio JSON（id 配对，30s 超时） | 1s 重启；加载失败 exit(1) |
| llama-server | C++ | — | main.js（`rewriteModelServer.js` + modelSupervisor） | HTTP 可应答 | HTTP（`breakPlacementHttpAdapter`） | 1s 重启 |
| whisper-server（dormant） | C++ | — | （未接线，回退路径） | — | HTTP /inference（旧） | — |

> 每个子进程 stdout 带**角色名前缀**写入主进程日志，保证可归因；spawn →
> 崩了等固定 1s 重启是统一模式（无退避、stop 前不停止；同一时刻至多一个待重启计时器）。

### 4.3 三套进程间协议（形状是刻意的）

1. **单向事件（hotkey-helper）**：`{"event":"down"|"up","ts":epoch}` 只出不进。
2. **请求/响应 JSON lines（accessibility- & transcription-helper）**：每行一个 JSON，请求带
   `id`、回复带同一 `id`。`id` 配对是为了**避免 head-of-line blocking**：一次慢请求不能卡住
   其后请求，回复可乱序到达并正确配对 Promise。协议命令与字段见 §9/§12。
3. **HTTP（模型层）**：llama-server 走 chat-completions（§11）；whisper-server 旧 `/inference`（dormant）。

### 4.4 代码地图：live / dormant / dead

**Live —— 逻辑主干（改写要保留/移植，详见 §17）**

```
electron/                        —— 见各章；核心文件名（行数）：
  main.js (1053)  dictationCoordinator.js (323)  voiceEditCoordinator.js
  voiceEditCommands.js  cleanup/rules.js (551)  paragraphBreaks.js (137)
  breakSafety.js  breakPlacementHttpAdapter.js  modelStore.js  modelSupervisor.js
  rewriteModelServer.js  hotkeyHelper.js  accessibilityHelper.js  transcriptionHelper.js
  pushToTalkCoordinator.js  pushToTalkShortcutController.js  shortcutCaptureController.js
  hotkeyDefinitions.js  capture/*  overlay/*  overlayPosition.js  heldResultController.js
  settingsStore.js  permissions.js  appBundleId.js  paths.js  windowState.js  preload.js
src/                         —— React UI（页面/组件/命令参考/样式/字体/桥类型）
native/hotkey-helper | accessibility-helper | transcription-helper   —— Swift（§9/§12/§13）
scripts/                     —— 构建/拉取/doctor/验证（§5）
```

**Dormant —— 保留作回退、当前未接线（ADR-0003）**

```
electron/whisperServer.js、transcriptionHttpAdapter.js     —— 旧 whisper HTTP 路径
scripts/build-whisper.sh                                   —— 不在 postinstall
resources/bin/whisper-server + libggml*/libwhisper* dylibs —— 已构建未运行
resources/models/ggml-base.en.bin (141M)                   —— modelStore 仍列条目（打包首启还下载，浪费）
scripts/model-artifacts.mjs 的 transcription 角色          —— 仍在编译 whisper-server（疑似死角色，#172 同构）
```

**Dead —— 无人引用的早期实验（删除候选，含测试一起评估）**

```
src/dictation/（coordinator.ts / cleanup.ts / paragraphBreaks.ts / breakSafety.ts / types.ts
               及 *.test.ts）—— 早期 “Establish dictation coordinator seam”(0571845) 的 TS
               原型，全仓除自身测试外零 import；职责已被 electron/dictationCoordinator.js 等取代
src/VocabularySettings.tsx（87 行）—— 功能完整但 Settings 页不挂载它（vocabulary UI 未接线）
```

---

## 5. 构建、安装与运行

### 5.1 前置要求

Apple Silicon（arm64）、macOS 14+（FluidAudio/Swift 6 门槛）、Node ≥ 22.12、npm、
Xcode Command Line Tools。无 x86/Intel 与 Linux/Windows 支持（ROADMAP 明示不做）。

### 5.2 `npm install`（postinstall 全链）

| 步骤 | 脚本 | 做什么 | 网络 |
|---|---|---|---|
| setup:git-hooks | `scripts/setup-git-hooks.sh` | 装 `.githooks/`（prepare-commit-msg 剥 Co-authored trailer） | 否 |
| prepare:electron | `node node_modules/electron/install.js` | 下载 Electron 二进制 | 是 |
| prepare:model-artifacts | `scripts/prepare-model-artifacts.mjs` | whisper 角色：pinned vendor/whisper.cpp(v1.9.3, commit 371b5a7) cmake Metal 编译 whisper-server + stageDylibs(@loader_path) + 下载 ggml-base.en.bin(sha256) | 是 |
| build:hotkey-helper / accessibility-helper | 对应 `scripts/build-*.sh` | swift build → `resources/bin/*-helper` | 否 |
| build:transcription-helper | `scripts/build-transcription-helper.sh` | swift build（FluidAudio SPM 静态链入）→ `resources/bin/transcription-helper` | 首次 resolve 需网 |
| build:llama | `scripts/fetch-llama.sh` | 下载 llama.cpp release b10625 tarball（三重 sha256）解到 `resources/bin/llama/` + smollm2 GGUF 到 `resources/models/`（pinned rev + sha256） | 是（~1GB） |

关键事实：
- llama-server 是**预编译二进制**（非源码编译）；dylib 是 `@loader_path` 相对、**必须整目录
  随行**。⚠️ **同一产物只能有一条获取路径**——#172 曾因 model-artifacts.mjs 残留的旧编译
  角色与 fetch-llama.sh 并存，导致“修了两次都没修好”的诡异事故。
- 转录权重（Parakeet CoreML ~470MB）不由仓库打包：FluidAudio 在 transcription-helper
  **首次运行**时下载到 `~/Library/Application Support/FluidAudio/Models/`（无进度 UI）。
- whisper 路径整体 dormant；`model-artifacts.mjs` 的 transcription 角色疑似可删（§18.2）。

### 5.3 运行/开发/发布命令

```bash
npm start        # production: NODE_ENV=production electron .（源码直跑）
npm run dev      # 开发：Vite dev server(5173) + wait-on + electron
npm run build    # tsc --noEmit && vite build
npm run typecheck
npm test         # vitest run && node --test "electron/**/*.test.js"
npm run doctor   # 终端查三个权限（spawn accessibility-helper 问 permissions）
npm run dist     # build + electron-builder → release/ 未签名 arm64 DMG
```

首次启动：按引导授予 Accessibility / Input Monitoring（+ Mic 首录时）；模型缺失则 Setup 页
下载。**源码构建的授权随每次 rebuild 重置**（无签名 → CDHash 变，TCC 绑旧二进制）——
升级后需在 系统设置→隐私与安全性 删旧条目再授权（§15.4）。

---

## 6. 主进程：生命周期、窗口与 IPC

> 行号锚点指 `electron/main.js`。这是「外壳」层里行为最密集的部分：删掉 Electron API 之外，
> 几十条行为细节必须在原生架构里一一对应（§6.7 与 §17）。

### 6.1 启动时序与门控

```
模块级: requestSingleInstanceLock() 失败→quit（先于一切）
whenReady:
  1. 装 CSP → 读 settings.json → 记 isFirstLaunch / launchedAtLogin
  2. 建 settingsStore、应用菜单、pushToTalkShortcut 控制器
  3. setBreakSafeApplications(settings)（白名单可编辑）
  4. vocabulary 首扫（fire-and-forget）
  5. createTray / createCaptureWindow / createOverlayWindow / accessibilityHelper.start
  6. 模型门: modelsMissing() ?
       真 → createWindow + openWindowTo("setup")；bringUpModels().then(checkPermissionsAndSurface)
       假 → launchedAtLogin ? 延迟 3s bringUpModels（避开 Metal warm-up）: 立即 bringUpModels
  7. 权限门: !verdict.ok → openWindowTo("permissions")
       否则仅 isFirstLaunch && !launchedAtLogin 才开主窗（日常启动静默驻 tray）
```

- **单实例**：第二实例 quit，并把首实例窗带上前台（`second-instance`）。
- **热键武装条件**（maybeStartHotkey）：`!hotkeyStarted ∧ captureReady（capture 窗报 ready）
  ∧ modelsReady（bringUpModels 成功）∧ pushToTalkShortcut`。
- **login item**：`openAtLogin` + `openAsHidden`（登录启动静默进 tray，永不开 Home 窗）。
- **tray**：三态 idle/recording/transcribing（voice-edit 复用 transcribing）；tooltip
  `OpenStream — state`，权限降级追加 `(permissions needed)`；菜单 = Open Window / Quit。

### 6.2 窗口体系与“永不失焦”约束

| 窗 | 关键参数/行为 |
|---|---|
| 主窗 | bounds 经 `sanitizeWindowBounds` 对主屏 workArea 校验（保尺寸、~80px 可见判定）；820×640 / min 560×440；ready-to-show 才 show；`titleBarStyle:'hiddenInset'`；`vibrancy:'hud'` + 透明底；contextIsolation 开；几何 move/resize 400ms 防抖持久化、close flush |
| capture 窗 | 永久隐藏 BrowserWindow 承载 Web Audio（音频图常驻）；收 `capture-ready`/`recording-complete`/`sound-level`/`recording-error` |
| overlay 窗 | frameless+transparent+hud vibrancy；`focusable:false`、alwaysOnTop、skipTaskbar；常态 `setIgnoreMouseEvents(true)`（点击穿透）、全空间；resting 244×50；录音时按**光标所在屏**底部居中后 `showInactive`；held 态扩至 432×264 并临时可聚焦可点 |

**AGENTS.md 硬不变量的执行点**：`createWindow/show/focus` 只被 tray、Dock `activate`、
`second-instance`、首启/权限门/Setup 门、应用菜单调用；听写/语音编辑路径只碰
`overlay.showInactive`，绝不聚焦主窗。

### 6.3 IPC 通道全清单

三个 contextBridge 面：`window.openstream`（主窗）、`window.capture`、`window.openstreamOverlay`；
主进程对 `on` 型通道校验 sender。

| 方向 | 通道 | 负载 → 返回 | 消费方 |
|---|---|---|---|
| main→shell | `navigate` | page 名 | 页面切换（gate 页） |
| main→shell+overlay | `dictation-state` | shell 收 coarse(idle/recording/transcribing)；overlay 收 raw(含 editing/held) | Home / overlay |
| main→shell | `setup-progress` | SetupProgress | Setup 页 |
| main→shell | `settings:shortcut-captured` | 捕获到的键 | HotkeySettings |
| main→capture | `capture:start/stop/cancel-recording` | timing | capture.js |
| capture→main | `capture-ready` / `recording-complete` / `sound-level`(0..1) / `recording-error` | wav+timing / level / msg | 主进程 |
| overlay→main | `copy-held-result` / `dismiss-held-result` | — | heldResultController |
| main→overlay | `held-result` / `held-result-copied` / `voice-edit-message` | text | overlay 面板 |
| shell→main(invoke) | `settings:get` / `app:get|set-login-item` / `app:check-permissions` / `app:open-privacy-settings(key)` / `app:get-health` / `app:get-setup-progress` / `app:retry-model-download` | 见 §14.3 | 各页 |
| shell→main | `settings:set-shortcut` / `settings:start|stop-shortcut-capture` / `settings:set|reset-break-safe-apps` / `settings:pick-break-safe-app` / `settings:set-vocabulary-path` / `vocabulary:rescan|get-status|choose-folder` | 各类结果 | 设置相关 |

### 6.4 settings.json（schema/校验/原子写）

- 默认：`hotkey {keyCode:58 独立 Option, modifiers:[]}`、breakSafeApps = 14 默认 bundleId、
  `vocabularyProjectPath:null`、`windowBounds:null`。
- 读：merge `{...defaults, ...parsed}`；任何读/解析异常**静默回退默认**（无损坏告警，脆弱点）。
- 写：tmp + rename 原子写；校验失败不污染 cache 与盘；breakSafeApps trim + Set 去重；
  shortcut keyCode 非负整数、modifiers ⊆ {cmd,shift,alt,ctrl}、空修饰需受支持独立键。

### 6.5 权限判定（permissions.js）

- verdict：`{ok, grants{accessibility,inputMonitoring,microphone}, blocking[], warnings[],
  details[]}`。
- 判定：accessibility granted/missing；inputMonitoring granted/missing/unknown
  （**unknown 也 blocking**——无法确认 PTT 可用）；microphone granted/missing/pending
  （missing 仅 warning）。blocking = accessibility + inputMonitoring。
- 数据：accessibility/inputMonitoring 来自 accessibility-helper `permissions` 命令（读宿主被
  归属的授权）；mic 来自 `systemPreferences.getMediaAccessStatus`。
- 启动只查一次（用户中途授权需手动 Re-check）。

### 6.6 错误处理与退出

- uncaughtException：记 `[main]` 日志（带 shutdown 标记），仅非 shutdown 弹对话框
  （#330/#294/#295 teardown-race 处理）；unhandledRejection 只记日志。
- before-quit 置 quitting；SIGTERM/SIGINT/SIGHUP 置 quitting + quit（编辑器关终端场景）。
- will-quit：unregister 快捷键 → stop fn 捕获 → stop PTT shortcut → stop
  accessibility/transcription helper、rewriteModelServer。
- 日志前缀约定：`[startup] [main] [security] [dictation] [voice-edit] [settings] [permissions]
  [setup] [vocabulary] [transcription-helper]`；每次听写一行 `[dictation] outcome: …` 可 grep。
- Escape 仅录制期临时占用（#134）；keyUp 超时 60s 强制停止（#140）。

### 6.7 「删除 vs 保留」判定（本节小结）

- **外壳-删**：三 BrowserWindow + webPreferences/preload/CSP、capture 窗内 Web Audio 采集、
  tray/Menu/Dock/activate/second-instance/window-all-closed 全套、三份 contextBridge、dev/prod
  加载逻辑。
- **纯逻辑-移植**：`windowState.sanitizeWindowBounds`、`overlayPosition`（bottom-center+32px）、
  `permissions.evaluatePermissions`、`settingsStore` 全套、breakSafety 名单、`heldResultController`、
  `VOICE_EDIT_MAX_CHARS=5000`、电平 0..1 归一化。
- **行为-保留**：关窗退 tray / Quit 仅显式；overlay 点击穿透、全空间、held 态临时可交互、
  按光标屏重定位、一律 showInactive；热键双门控与启动决策树；held 语义（hold 不改剪贴板、
  copy 单次、dismiss 防陈旧）；recordStartBundleId 防错投；Escape 仅录制期；日志可 grep；
  tray tooltip 权限降级提示。
- **Swift 映射提醒**：`window-all-closed + activate 重建` → NSApplicationDelegate
  (`applicationShouldHandleReopen` / `applicationShouldTerminateAfterLastWindowClosed`)；
  `openAsHidden` → 不激活的登录启动语义；#208 焦点不变量移植时必须同步进架构文档。

## 7. 一次听写端到端：状态机、时序与结局矩阵

> 三层分工（再强调）：**结局决策状态机** = `electron/dictationCoordinator.js`（hexagonal、
> adapters 注入、纯逻辑）；**端到端编排** = `electron/main.js`；**注入最终决策** = Swift
> `InjectionEngine`。改写时保持这个分层。

### 7.1 时序（一次普通听写）

```
keyDown ─ hotkey-helper NDJSON {"event":"down","ts"} → hotkeyHelper.js → PTT 控制器
   → beginPushToTalk (main.js)
       ├─ 异步发起 getSelection()（#17 判定语音编辑）与 getFocusContext().bundleId（#355 快照）
       │   —— 刻意不 await：慢/失败的读取绝不能延迟录音启动
       └─ pushToTalkCoordinator.keyDown() → capture 窗 start-recording
           · 同时 arm 全局 Escape = “取消”（仅录制期，#134）
           · overlay 显示 recording（定位到光标所在屏底部）
说话中   · capture 只缓冲音频帧 + 算 RMS 电平 → sound-level IPC(0..1) → overlay 波形
          · provisional text 永不产生/展示/注入（文本只在交付后出现）
keyUp ─ {"event":"up"} → pushToTalkCoordinator.finishRecording(releasedAtMs=now())
   → capture 停 → 内存编码 WAV（16kHz/16-bit/mono, 44B 头）→ recording-complete IPC(wav,timing)
   → handleCompletedRecording
       ├─ pendingSelectionRead 有 0<len≤5000（VOICE_EDIT_MAX_CHARS）选区 → applyVoiceEdit（§8）
       └─ 否则 transcribeAndPrint(wav, timing, recordStartBundleId)（§7.2）
```

- **FIFO 串行**：coordinator 内部 `queue = queue.then(...)`——两次录音完成严格排队，
  单个 bug 的 rejection 在队列自身被吞，不影响其后录音。
- **卡键兜底**：`maxRecordingMs=60_000`；Escape → cancel（清音频、无完成事件、不处理，#134）。
- **latency 起点 = keyUp 时间戳**；预算 sub-1s（日志断言 `release-to-insertion:`）。

### 7.2 管道内的五阶段（dictationCoordinator.js）

```
1) 转录     wav>44B? → vocabulary.getPrompt()(#16) → transcription.transcribe(wav, prompt)
            空文本 → no-speech；适配器异常 → failed("transcription")
2) 上下文   转录之后才读 focusContext（校验形状）；诊断 context.bundleId/axReady
            · #355 app-switch guard：recordStartBundleId ≠ 当前 bundleId
              → 安全默认 cleanup 后 held（“前台 App 在听写期间变了”）
            · context 整体失败（helper down/无前台）→ 同样 cleanup 后 held（#227，绝不丢字）
3) cleanup  isBreakSafeApplication(bundleId) + #307 单行猜测覆盖
            → cleanup(rawText, {oneLineBox, breakSafe})（rules.js，<1ms）
            · #307：break-safe App 里 AX *猜测的* one-line（axReady=false）不压制显式断句命令
              —— 否则 Notes 里说 new paragraph 会静默变空格
            · 非 break-safe 且有显式断句词 → 打 context.breakCommandDropped 诊断（#307）
4) 断句     仅当 breakSafe ∧ !oneLine ∧ 无显式断句命令 ∧ 分句 ≥3（§11）
            placeParagraphBreaks(sentences) → repair（fail-closed）→ render
            模型不可用/超时/畸形回复 → 原样 prose 交付，绝不阻塞注入
5) 交付     delivery.deliver(finishedText, bundleId)（#355：给 helper 新基线做注入期中止）
            inserted → delivered / held → held / 异常 → held
另：#375 paste 分支在 cleanup 之前——整句为裸 paste 短语时直接走剪贴板（§8.4）
```

### 7.3 结局矩阵（coordinator status → 用户可见）

| status | 触发 | 用户可见 | 日志 |
|---|---|---|---|
| `delivered` | 注入确认（rung1 需读回验证） | idle，无 overlay 文本 | `[dictation] outcome: delivered` + release-to-insertion ms |
| `pasted` | #375 裸 paste 成功 | “Pasted” 2s | outcome: pasted |
| `info` | 剪贴板空 / 超 10000 字符 | 对应 message | outcome: info |
| `held` | 目标切换(#355)/context 失败(#227)/delivery held（AX 失败、多行放不进、settle 超时、注入中切换）/voice-edit 需换行但目标不安全 | overlay 扩 432×264 可聚焦：全文 + Copy/Dismiss；Copy 单次翻 “Copied”；下次录音自动 dismiss | outcome: held + reason |
| `failed` | transcription/context 适配器异常 | 仅 console（静默 idle） | outcome: failed stage=… |
| `no-speech`/`empty` | 空转录 / wav≤44B | idle | 一行 |

> Held 语义：**转录成功的文字永远不许丢**；hold 不改剪贴板、copy 显式单次、dismiss 防陈旧。
> overlay 只 showInactive、永不聚焦（AGENTS.md）。

### 7.4 一次听写内的全部时间约束

| 段 | 预算 | 位置 |
|---|---|---|
| 端到端 release→insertion | <1000ms（日志断言） | main.js |
| AX context 读取 | deadline 150ms + 重试预算 250ms | Config.swift |
| 注入 settle guard | 稳定 400ms / 上限 1200ms | Config.swift |
| 注入 focus 重试 | 200ms | Config.swift |
| 剪贴板还原 | restoreMs 300ms | Config.swift |
| accessibility 请求总超时 | 3000ms | accessibilityHelper.js |
| 断句 HTTP | 300ms | breakPlacementHttpAdapter.js |
| 转录单请求 | 30s（暖机实测 150–300ms） | transcriptionHelper.js |
| 卡键录制上限 | 60s | pushToTalkCoordinator.js |

---

## 8. 语音编辑与粘贴命令

### 8.1 为什么语音编辑是确定性的

原计划是“选区 + 自然语言指令 → 改写模型就地改写”；`prototypes/voice-edit-fidelity-222`
实测 SmolLM2-1.7B：**6–7/15 原样返回、加示例后过拟合乱打** → 结论：固定命令集用模型是错的。
v0.3 改为**固定语法 + 纯字符串变换、零模型**；语义类（“shorter/fix grammar”）明确
out of scope（#222，等更强模型进 rewrite 角色）。

### 8.2 触发与流程（voiceEditCoordinator；与听写共用几乎全部设施）

```
keyDown: 异步发起 accessibility-helper `selection` 命令（不阻塞录音）
keyUp → recording-complete：
  · 选区 0<len≤5000（VOICE_EDIT_MAX_CHARS, main.js:203）→ voice edit，否则 dictation
    1. 转录命令（同一转录适配器，无 vocab prompt）
    2. interpretVoiceEditCommand：normalise（小写/trim/去尾标点/折叠空白/carrier 剥离）→ 匹配别名表
    3. 命中 → 对 key-down 快照的选区做纯 string→string 变换（亚毫秒）
       未命中 → unrecognised（选区不动）   · 形状不符 → declined（带 reason）
    4. 结果含换行（bullets/numbered）但目标非 break-safe 或 one-line → held（不拍平）
    5. 交付走同一注入引擎；settle guard 覆盖转录 300ms 内的焦点移动
```

- 语法表真源 `electron/voiceEditCommands.js`；人类可读版 `src/commandReference.ts`
  （改代码必须同步它）。
- **voice edit 无 #355 重查**（选区与 focusContext 均为 key-down 快照）；FIFO 队列与听写相同。
- **copy（#374）**：永不 rewrite/注入，选区原样写剪贴板；无 clipboard adapter 时
  → `failed("copy")`。

### 8.3 命令语法全表（别名 → 结果）

| 类别 | 命令 | 别名要点 | 结果 / 守卫 |
|---|---|---|---|
| identifier case | snake/camel/pascal/kebab/constant | snake case·snakecase·snake case that；upper camel case；screaming snake case… | `get_user_name`/`getUserName`/`GetUserName`/`get-user-name`/`GET_USER_NAME`；**guard**：去单尾句点后含 `[,;:!?()[\]{}"'`\n]` 或词数 0/>6 → declined |
| 全量 case | title/upper/lower | title case / all caps / lowercase… | 无 guard（含标点全量变换） |
| 包裹 | wrap（6 对） | quotes/add quotes/quote that；single quotes；backticks/code/code that；parentheses/parens/brackets；square brackets；braces/curly braces/curlies | `"" '' `` () [] {}`，原样包、不 trim |
| 列表 | bullets / numbered | bullet list/bulleted list/bullet points/make a bullet list；numbered/number list/ordered list | `- item\n…`/`1. item\n…`；含 `\n` 或切分 <2 项 → declined |
| 复制 | copy | copy that/this/it/copy | 选区→剪贴板，文档不动 |

- **tokenise**：按空白/`_-`/camel 边界/acronym 切（`getUserID→get_user_id`、
  `HTTPServerError→http-server-error`）。
- **carrier 剥离**：please / make this / turn this into / change this to / convert this to /
  put this in …；`^wrap (this|it) in` 规整为 `wrap in`。
- overlay 反馈：unrecognised → “Command not recognised”；declined → 显示 reason；
  copied → “Copied”；需要换行的结果在非 break-safe → held overlay（vc:88-98）。

### 8.4 粘贴命令（F5/#375，dictationCoordinator 内分支）

- **裸整句匹配**：`paste / paste that / paste it / paste clipboard / paste the clipboard /
  paste from (the) clipboard`（小写+trim+去尾标点后全等）；“paste the report” 逐字打出。
- 空剪贴板 → info；>10000 字符（`PASTE_MAX_CHARS`）→ info 含长度；含 `[\r\n]` 且非 break-safe
  → held（reason 点名 bundleId）；只受 breakSafe 门控、不看 one-line。
- 注入 = 同一 `delivery.deliver(clipboardText, bundleId)`；成功 → `pasted` + “Pasted” 2s。
- 无 clipboard adapter 时整句退化普通听写。

---

## 9. 转录层：Parakeet / FluidAudio / transcription-helper

### 9.1 形态

转录角色 = `native/transcription-helper`（Swift，143 行薄封装）；Electron 侧
`transcriptionHelper.js` 只做监督与 stdio 客户端（**既是服务器也是转录适配器**；旧 whisper
HTTP `/inference` 契约已删——ADR-0003）。模型 = **NVIDIA Parakeet TDT 0.6b v3** CoreML/ANE，
经 FluidAudio 0.15.6（纯 Swift SPM、静态链入、无 dylib staging）。

### 9.2 协议与门控

```
-> {"id":"1","cmd":"transcribe","wav":"<base64 WAV>"}   （lang 可选，JS 从不发送 → 默认 .english）
<- {"id":"1","status":"ok","text":"...","ms":312}
-> {"id":"1","cmd":"ping"}    <- {"id":"1","status":"ok"}
启动: {"event":"ready"}（模型加载成功后才进命令循环） 或  {"event":"error"} 后 exit(1)
```

- **ready 门在 Swift**：模型**阻塞加载于 readLine 循环之前**；加载失败 = 无限 1s 重启重试，
  期间 `whenReady()` 挂起、健康探针显示 “starting”（Home 模型 pill 决定整页 ready）。
  未就绪时 transcribe 请求积压 stdin pipe（无 JS 队列，30s 超时兜底）。
- 每次 transcribe：wav>44B 守卫 → 写临时 WAV（用完删）→ AsrModels/AsrManager
  （TdtDecoderState）→ 回 text+ms。单请求串行（“one request at a time is exactly right”）。
- **prompt 被忽略**：Parakeet 无 whisper 式 initial_prompt（#16 词表偏置不适用）；FluidAudio
  keyword-boosting 是未来路径（#322）。
- **模型下载**：FluidAudio 首跑自动下 CoreML bundles（~470MB）到
  `~/Library/Application Support/FluidAudio/Models/`——无进度 UI（#249 parity follow-up）。
- **语言**：Parakeet TDT 0.6b v3 官方定位 multilingual（~25 欧洲语言、自动检测），但产品
  **English-first**（JS 不传 lang → helper 默认 .english；语音命令语法/清理规则全是英文）。
  多语言 + 自动检测在 roadmap v1.1（#252）。**当前不支持中文/CJK**；⚠️ 2026-09-09 新增拟议
  扩展（requirements §5 + ADR-0004, proposed）：计划加 zh profile（`cmn`/`yue` → `zh-Hans`，
  换 transcription holder、规则引擎加 zh profile、`lang` 字段开始发送、CJK 字体回退），
  落地前本节不变。

---

## 10. 规则清理引擎（rules.js）

> `electron/cleanup/rules.js`（551 行）是**最大的单块纯逻辑**（改写移植主战场之一）。
> 它是 `spike/llm-cleanup-latency` 里 Python 原型的“忠实移植”——行为经实测验证、不是拍脑袋。
> 全链 stateless、无 I/O、预算 0.1–1.0ms（ADR-0001/0002 的落点：听写路径无 LLM）。

### 10.1 执行顺序（代码真实顺序，rules:485-523）

入口 `cleanup(text, {oneLineBox, breakSafe})`；`allowNewlines = breakSafe && !oneLineBox`。

| # | 函数 | 要点 |
|---|---|---|
| 0 | trim | rules:491 |
| 1 | 硬换行折叠 | `\s*\n\s* → " "`（whisper/Parakeet 换行伪影最先清） |
| 2 | applySelfCorrection | #127/#174，见 §10.2 |
| 3 | applySpellOut | #132：≥2 单字母 token 拼词、首字母大写 |
| 4 | stripFillers | 三类口头禅，见 §10.3 |
| 5 | collapseRepeats | while 到不动点（`the the`→`the`） |
| 6 | applySpokenPunct | 口语标点表；4 条换行产物受门控，见 §10.4 |
| 7 | applySpokenEmoji | 永不门控 |
| 8 | applyQuoteMarkers | 非贪婪配对 |
| 9 | applyCurrency | 三段回调式替换，见 §10.5 |
| 10 | stripLeadingFillers | 句首逐词剥、绝不剥空 |
| 11 | segmentSentences | **仅 `!oneLineBox`**，见 §10.6 |
| 12 | capitalise | `i→I`、句子起点大写（跳过 tab/bullet 标记/开引号） |
| 13 | applyVocab | 固定词表（句子大写后执行，保 macOS/GitHub 定型） |
| 14 | 结尾 | one-line：去尾句点+尾空白；否则 terminalPunct 补 `.` |
| 15 | 收尾 | `/ {2,}/→" "`（**只清空格不清 \t**，保护 #129 双 tab 缩进）；trim |

⚠️ 步骤 2→5 的顺序是硬约束（rules:496-501）：拼读 `b o o k` 若先过 collapseRepeats，
`o o` 会被折成 `bok`。

### 10.2 自纠错（scratch/delete that）

`SELF_CORRECTION`（rules:177-178）→ 删空。四道闸：
- 只回退**同一标点串内紧邻上一子句**（懒扫描 + 最多单个句读）；
- **后须停顿**（前瞻要求触发词后接标点或行尾）——“delete that file/branch” 是内容（#127）；
- #174：前界放宽到 `[.!?,]\s`，让 Parakeet 独立断句的 “X. Scratch that.” 能删 X；
  但仍跨不过第二个句号（“A. B. Scratch that.” 只删 B——#125 之后才走模型）；
- 左起最左触发：连续两次纠错依次清空。
- 例：`"buy milk, scratch that, buy oat milk"` → `"Buy oat milk."`。

### 10.3 fillers / repeats / quote

- fillers 三类：STANDALONE `um uh erm er ah hmm mhm`（仅整词、须空格/串首前界）；
  PHRASE `you know / i mean / kind of like / sort of like`；均吃尾随可选逗号+空白。
  LEADING `so okay ok well right now basically actually literally anyway like` 只在句首
  逐词剥、**绝不剥空**。
- collapseRepeats：`([\w']+)(\s+\1)+` 含 `'` 词符 → `let's let's` 也折叠；lookbehind/lookahead
  + `\1` 反向引用（Swift 需手写）。
- quote：#128 `/\bquote\b\s+(.+?)\s+\bend quote\b/gi` 非贪婪+g → 多对各自配对；未闭合原样。

### 10.4 口语标点与换行门控（deny-by-default 在文本层）

- SPOKEN_PUNCT 表（rules:38-104）：full stop/period→`.`、comma→`,`、question mark→`?`、
  exclamation→`!`、colon/semicolon、paren/brace/bracket、dash/slash、percent/dollar sign/
  at sign/hashtag…
- **仅 4 条受 `allowNewlines` 门控**（replacement ∈ `\n \n\n \n-  \t`，rules:215-217）：
  非 break-safe 一律替换为 `" "`（deny-by-default，#45）；`new paragraph`→`\n\n`、
  `new line`→`\n`、`bullet points?|(new|next) bullets?( points?)?`→`\n- `、
  `tab|indent`→`\t`（**仅从句首**，`(?:^|(?<=[.!?,{[(\n]))`，普通名词 “switch to the other
  tab” 永不误伤，#129）。
- **#320（Parakeet 句点残留）**：BREAK_LEAD 吃前导 `,;:`（**绝不吃 `.`**——真句号闭合上句）、
  BREAK_TAIL 吃单个尾标点+两侧空格；降级为空格时同一正则仍吞标点 → 结果干净无 “-” 泄漏。
- **one-line field 优先级高于 break-safe**；emoji 与 quote **永不门控**（无提交表单风险，#131/#128）。
- break-safe 名单见 §15.5（14 项；终端/聊天/浏览器故意排除，注释写明原因）。

### 10.5 currency / 回调式替换（Swift 移植重点）

- **applyCurrency**（#130）：三段 `String.replace` **回调式**替换——Swift 无此 API，须改
  手写 scan+range 替换循环（parse 失败原区间跳过）：① `N dollars? and N cents?` → `$N.cc`
  （cents>99 或 parse null 不动）→ ② `dollars?` → `$N` → ③ `cents?` → `$0.cc`。
- `parseNumberWords`：标准英文数词文法至 thousand；`a/an`=1、hundred/thousand 叠乘、`and`
  跳过、**未知词返 null 绝不猜**。`"fifty dollars"`→`$50`；`"twenty dollars and fifty cents"`
  →`$20.50`；`"fifty cents"`→`$0.50`。
- spell-out（#132）：`/\bspell(?: that)?:?\s+([a-z]\b(?:[\s-]+[a-z]\b)+)/gi` → join 后
  首字母大写余部小写；分隔符在重复组内 → “spell a b three…” 干净停在 b；不做字母名消歧。

### 10.6 句子切分与大小写

- **segmentSentences**（rules:407-440）：全文 <25 词直接返回；逐句 <30 词不动（**实际被切句
  须 ≥30 词**——requirements F2 漏了这道内层门槛）；对 ≥30 词句子逐词扫，bare ∈
  {so,and,but,because} 且前段 ≥12 词、剩余 ≥8 词（连接词计入、其后实际 ≥7）才切：前段去尾
  逗号补 `.`、连接词领起新句。已知弱点：可能从句中落界（#45 接受）。
- capitalise：全文档 `i→I`（含 `i'm/i've/i'll/i'd`）；按 `SENT_BOUNDARY_SPLIT` 分段，句首
  跳过 `tab / "- " bullet 标记 / 开引号` 后再大写。
- terminalPunct：末字符 ∉ `.?!:` 补 `.`；one-line 分支只去尾句点+尾空白（无换行/无句号）。
- **VOCAB 固定词表**（rules:134-145，句子大写后执行）：`lama[- ]server|llama server`→
  `llama-server`、`macos`→`macOS`、`ram`→`RAM`、`hot key`→`hotkey`、`auto update`→
  `auto-update`、`rules based`→`rules-based`、`git hub`→`GitHub`、`java script`→`JavaScript`、
  `type script`→`TypeScript`（幂等：规范形不被规则再碰）。

### 10.7 Swift 移植工程提示

- 除 `breakSafety` 的可写 Set 外**无共享可变状态**；建议签名 `cleanup(String,
  oneLineBox:Bool, breakSafe:Bool) -> String`、`parseNumberWords(String) -> Int?`，各
  `apply*` 保持同名 `String->String` 便于与 `rules.test.js` 逐条对拍。
- **JS 特有正则 → Swift 重写**：lookbehind 出现于 SELF_CORRECTION / stripFillers /
  collapseRepeats / tab 规则 / SENT_BOUNDARY_SPLIT / tidy——Swift 改手写方向扫描；
  `\1` 反向引用与非贪婪 `.+?` NSRegularExpression 可支持；`\b` ICU 基本等价但逐条核验。
- 回调式 replace（currency/spell-out/quote）→ 手写 scan+range 替换循环。
- 测试对齐清单：rules.test.js 断言了完整输出（fillers/repeats/标点 12 例/emoji 10+反例/
  vocab 9/self-correction 4+#174 2+guard 2/i-I/one-line/break-safe deny-allow-override/
  bullet 全变体+“bulletin” 反例/#320/currency 7/spell-out 4/quote 4/性能 <5ms@200 次/
  samples 全集不变式）；real-dictation fixture 空数组被 skip（#171）。

---

## 11. 段落断句：改写模型服务器与契约

### 11.1 触发与降级

触发（dictationCoordinator）：`breakSafe ∧ !oneLine ∧ 无显式 “new line/paragraph” 命令 ∧
分句 ≥3`。**模型不可用/超时/畸形回复一律 fail-closed**——原文 prose 交付，断句绝不阻塞注入
（诊断记 `paragraphBreaks.*`）。

### 11.2 分句与契约

- `splitSentences`：`(?<=[.!?])\s+` 切分（lookbehind），先拍平换行。
- HTTP（llama-server，见 §15）：system prompt 只教输出 `none` 或 `2, 5, 9` 式**句子序号**
  （禁句 1、禁未给出序号）；user = “N. 句” 逐句编号；max_tokens 32、temperature 0。
- **双行契约（#125）**：`BREAKS: 3, 7` / `LIST: 5-8`（各行可 none）。两维独立解析/修复：
  `repairBreakIndices` 只读 BREAKS 行（防 LIST 数字泄漏为断句）；有 LIST 无 BREAKS → 无断句；
  兼容旧裸 `3, 7`。
- **repair fail-closed**（#90 规则）：越界/重复/乱序 → clamp 到 (1, sentenceCount]、去重、
  排序；读不清 → 降级 prose，绝不报错。
- **LIST 维度 dormant**：解析与 diagnostics 照跑，`listDetection=false` 默认（#125 spike：
  SmolLM2 过度触发列表）——渲染门控关着。渲染 `renderStructuredText`：列表段 `- ` 子弹
  （#124）、段间空行、列表内断句丢弃、尾段重定基。

### 11.3 监督与已知疑点

- llama-server 由 `rewriteModelServer.js`（spawn 配置）+ `modelSupervisor.js`（通用监督）
  托管：`--model <gguf> --host 127.0.0.1 --port 8179 --ctx-size 2048`；health `GET /health`、
  推理 `POST /v1/chat/completions`；退出 1s 后重启（固定延迟、无退避）。
- ⚠️ **疑点**：注释称必须“从解压目录运行”（@loader_path rpath），但 spawn 未显式设 cwd
  （继承 Electron）——移植前核实（§18.3）。

---

## 12. 上下文检测、换行安全与文本注入（原生层）

> 本节主体在 `native/accessibility-helper`（Swift）：Electron 只做监督与协议客户端；
> **注入/上下文决策真正发生在 Swift**。注入引擎面向 protocols（可注入 fakes）→
> 决策逻辑可完整单元测试（17 个 @Test）。

### 12.1 角色与协议

accessibility-helper 持 **Accessibility** 授权（绝不碰 Input Monitoring——#26 两 helper 拓扑）。
stdout 先发 `{"event":"ready"}`，随后 stdin 命令循环（请求/回包同 `id`，3s 超时）：

| 命令 | 用途 | 关键回包字段 |
|---|---|---|
| `context` | 前台 App + 焦点字段上下文 | ok: bundleId/isOneLineField/axReady；error: reason+trusted |
| `insert`/`inject` | 注入文本（可带 expectedBundleId → #355 中止） | outcome（delivered/held + method/verified/reason） |
| `permissions` | 被动查两授权（AXIsProcessTrusted + IOHIDCheckAccess，不 claim IM） | accessibility/inputMonitoring |
| `selection` | 读焦点字段当前选区（key-down 判定语音编辑） | ok: text/bundleId/isOneLineField；empty |

### 12.2 frontmost app 与焦点解析（踩坑后的现状）

- **前台 App 用轮询不用通知**：#113/#173 教训——`NSWorkspace.didActivateApplication` 投递在
  主线程 runloop，而 helper 主线程**永远停 readLine()、从不 pump** → 独立 Thread 每 250ms
  轮询 `frontmostApplication`（带锁；该线程跑自己的 runloop）。
- **frontmost app 用 AX 系统级读**（#318）：`kAXFocusedApplicationAttribute`（从终端启动会
  冻结在启动时 App——#307 Notes bug 的根）；-25204（kAXErrorCannotComplete，瞬态）在预算内
  每 40ms 重试（#319）、超时回退 tracker 并 log。
- **focusContext 永不硬失败**（#181）：焦点 AX 不就绪 → 返回安全默认
  `(bundleId, isOneLineField=true, axReady=false)`，由 JS 决定怎么用这个“猜测”。
- **warmUp**（#329/#331/#228）：启动后独立线程跑最多 60s 的“解冻”循环（app-scoped 读才是
  真正解冻通道的动作）；不阻塞 ready 行。
- isOneLineField = role ∈ {AXTextField, AXComboBox}。

### 12.3 InjectionEngine.decide() —— 守卫与三级回退

```
1. settle guard: 距前台切换 < settleMs(400) → 最多等 settleBudgetMs(1200)；仍动 → held
2. focus 解析: resolveFocusedElement(deadlineMs:150) 在 axInjectBudgetMs(200) 内每 40ms 重试
3. 解析失败 → "盲贴 gate": 仅当 tracker 稳定 ≥ stableForBlindPasteMs(800) 且知 App 名
   → 盲贴 delivered（"App 已知稳定" > "焦点还在动"）；否则 held
4. pasteFirst（bundle ∈ Config.pasteFirstBundleIds——#368 Google Docs 等 canvas 编辑器）
   → 跳过 rung1，睡 browserPasteSettleMs(400) 后走 rung2
5. #355 app-switch 中止: expectedBundleId ≠ 当前 ownerBundleId → held
6. rung1 直接写: 字段 settable 且现值 ≤ axValueMaxChars(2000)（防终端 scrollback，#28）
   → 写 kAXSelectedText + 读回验证 contains(text) 才算 delivered
7. rung2 剪贴板+⌘V: 借板 → setString → 合成 ⌘V → 睡 restoreMs(300) → changeCount 未动才还原
   用户剪贴板 → 可读字段读回验证。⌘V 用 .privateState 事件源（#368：.hidSystemState 会把
   PTT 释放后沉降中的硬件修饰 OR 进事件，变成 "Cmd+修饰+V"）
8. rung3 逐字符键入: 仅当 rung2 可验证且确证失败（绝不向未知字段盲打——vim/自动补全会制造
   任意输入）；每字符前 poll shouldAbort（#355 中断→held）；>longTextChars(120) 附警告
   （逐字对长文本可能丢/重排字符）
```

结局 = `delivered`（含方法+是否验证）或 `held(reason)`；JS 把 held 转 overlay Held result。
**多行文本放行判断在 JS 上游**（break-safe + oneLine，§7/§11），helper 不判断新行；
rung3 对 U+000A 按普通 unicode 键发出，行为取决于目标 App（脆弱点）。

### 12.4 Config 阈值（Config.swift）

| 常量 | 值 | 含义 |
|---|---|---|
| settleMs / settleBudgetMs | 400 / 1200 | 注入前前台稳定要求 / 总预算 |
| axDeadlineMs | 150 | 单次 AX messaging 超时 |
| axReadyBudgetMs | 250 | context 路径 #181 重试预算 |
| axInjectBudgetMs | 200 | 注入路径 #227 重试预算（更短：延迟敏感） |
| restoreMs | 300 | 剪贴板还原窗口 |
| axValueMaxChars | 2000 | 判定“可写字段”而非 scrollback |
| longTextChars | 120 | rung3 逐字超长告警 |
| stableForBlindPasteMs | 800 | 盲贴稳定要求（2×settleMs） |
| pasteFirstBundleIds / browserPasteSettleMs | 浏览器集 / 400 | #368 canvas 编辑器 |
| maxRecordingMs / 请求超时 | 60s / 3s(helper) | 见 §7.4 |

### 12.5 TCC 归属（关键认知）

macOS 把授权归属到“**spawn helper 的宿主（Electron host）**”（main.swift 注释，#47/#46）——
`permissions` 命令读到的即管道真正依赖的状态。**rebuild 后 ad-hoc 签名 CDHash 不稳定 → 每次
重建都重绑权限**（与进程数无关、与签名有关）；进程内化不改变此问题（§15.4/§17）。

## 13. 热键系统（hotkey-helper）

### 13.1 角色与协议

- 持 **Input Monitoring**，绝不碰 AX（#26 拓扑；隔离理由见 §17 risk 2）。
- spawn：`hotkey-helper --keycode N --modifiers cmd,alt,…`（默认独立 Option，keyCode 58）。
- stdout 单向事件 `{"event":"ready"|"down"|"up","ts":epoch}`；stdout 全缓冲 → 每次 fflush。
  事件顺序与 `ts` 是 latency 预算起点。
- 退出/重启：tap 创建失败 exit(1)；任何退出/未 ready 超时(5s)/error → 1s 重启；ready 前事件丢弃。

### 13.2 实现要点

- **CGEventTap**：会话级 `.cgSessionEventTap` + `.headInsertEventTap` + **listenOnly**
  （纯监听不吞键，回调恒 passRetained）。macOS 超时杀 tap
  （.tapDisabledByTimeout/.tapDisabledByUserInput）→ `CGEvent.tapEnable` 重新启用。
- **两类匹配**：目标 flags 空 → standalone 修饰键触发（Option 58/61、Cmd 55/54、Ctrl 59/62、
  Fn 63）：修饰键**没有 keyDown/keyUp、只有 flagsChanged**——用 previousFlags 状态跃迁识别
  “本键刚按下/抬起且不带其它修饰”（只靠键盘事件必然漏 Option 单键 PTT）；
  非空 flags → legacy 组合键：keyDown 要求 keyCode+flags 完全相等、拒 autorepeat/重入。
- **CapsLock** alpha-shift 标志只报锁状态非物理边沿 → 当普通键对（57）处理；
  **Fn** 走 `.secondaryFunction`。F1–F19 逐键配对。Fn/CapsLock/F 键可达性依赖键盘与系统
  拦截——manual-check 文档标为 “conditional hardware results”。
- **runloop/线程**：tap 回调挂主线程 CFRunLoop（.commonModes），进程级常驻。
- 权限：启动即 CGPreflight/CGRequestListenEventAccess（弹窗时机 = 进程启动）。

### 13.3 热键生命周期（JS 侧）

`pushToTalkShortcutController.js` 解析 settings.hotkey；**更换热键 = 停旧+起新原子操作**
（hotkeyHelper.js）；`settings:set-shortcut` 校验（独立键集合 + modifiers 白名单）；
Fn 等 native-only 键经 `shortcutCaptureController` 一次性捕获（须主窗 sender 防冒充）；
Escape 只在录制期临时作取消（#134）。键码映射在 `src/hotkey/keycodeMap.ts`（DOM ↔ Carbon
kVK）+ `electron/hotkeyDefinitions.js`（独立键集合）——原生改写时是两边的桥。

---

## 14. 渲染层（React UI）与 Overlay

### 14.1 导航模型

- `src/nav.ts`：`Page = "home"|"commands"|"settings"|"permissions"|"setup"`；`TAB_PAGES` 只含
  前三个（Permissions/Setup 是 gate 页非 tab）；`coercePage` 校验主进程导航消息。
- `App.tsx`：单一 `useState<Page>("home")`；订阅 `onNavigate`；无路由库、无 URL。
- **主进程驱动 gate**：`openWindowTo` 在 `did-finish-load` 后补发 navigate → 首启
  Permissions/Setup 页可靠出现。

### 14.2 各页面与数据来源

| 页 | 状态/数据 |
|---|---|
| Home | 一次性 `settings.get()`；health 轮询 4s（无 push 型 health 事件）；订阅 onDictationState（coarse 三态，editing 折叠为 transcribing）；hero Mark 状态机；shortcut card；System 卡 5 行健康（3 权限+2 模型），`permissionsNeedAttention`→Fix；折叠态存 localStorage |
| Commands | 纯静态 `commandReference.ts`（真源 rules.js/voiceEditCommands.js）；客户端子串搜索 |
| Settings | HotkeySettings（DOM keydown + native capture 双通道，Fn 需 native）+ BreakSafeAppsSettings（chips + 原生 app picker + bundle id 手输 + Restore）+ Startup（login item）；**VocabularySettings 未挂载** |
| Permissions | 进入即 checkPermissions；required 排除 mic（标 “Optional now”）；深链系统设置；Re-check；verdict.ok 才 Continue |
| Setup | 先 `getSetupProgress()`（latched）再订阅；**单进度槽**（SetupProgress 每次描述当前活动角色）；pct/4% 占位/indeterminate 滑条；ready 后 600ms 自动 onDone；错误 → retryModelDownload |

### 14.3 contextBridge 暴露面与类型（改写 = 新的 IPC/事件模型）

`window.openstream`（preload.js）+ 类型面 `src/openstreamBridge.d.ts`（GrantState 四值、
PermissionVerdict、SetupProgress、VocabularyStatus…）。要点：
- **无 push 型 health/权限事件**——health 只能 4s 轮询、权限只能按钮重查（native 改写成
  推送更优，§14.5）；dictation-state 不含 held（held 只达 overlay/tray）。
- overlay 是独立桥 `window.openstreamOverlay`（只监听 + 两个 send，sender 校验）。
- 完整 IPC 方法/事件表见 §6.3（每行对应 preload 方法与 main.js handler 行号）。

### 14.4 组件与视觉 token

组件：`Mark`（圆环+单波，state 换色 + recording 脉冲）、`KeyCaps`、`StatusPill`（四色）、
`Toggle`（role=switch）、`Icons`（svg 工厂 11 个）。视觉（index.css ~800 行，blue-glass）：
JetBrains Mono 本地 woff2（只给“字面字符”：commands 表/键帽/热键读数/held text）；
UI/prose 用系统 SF；`--bg:#0a1420`、`--screen`、`--acc #8FC4FF`、`--acc-2 #52E6D6`、
`--err #FF6B54`；两条系统媒体查询：reduce-motion（停 mark 脉冲/进度滑动/波形涟漪）、
reduce-transparency（整树换实色兜底）。

### 14.5 SwiftUI 映射清单与死代码

**页面 → view**：Home→HomeView、Commands→CommandsView（数据可转 Bundle 资源）、
Settings→SettingsView（Form/List 天然对应 .setting-item）、Permissions→PermissionGateView、
Setup→SetupProgressView。gate 流判定保留 main.js 决策树。
**事件 → 异步流**：dictation-state → NotificationCenter/AsyncStream（把 editing→transcribing
折叠收进主状态机）；health 4s 轮询 → 主进程推送（需新增 IPC 或 Combine 侧 poll）；
setup-progress → 保留 “latched last” 语义（先拉快照再订阅）；overlay 状态推送独立通道。
**overlay → NSPanel**：7-bar 延迟历史 → CADisplayLink/Timer + 环形缓冲；RMS×5 放大 +
idle 涟漪；`setIgnoreMouseEvents` ⇔ `ignoresMouseEvents`（held 时开交互）；hud 材质 →
NSVisualEffectView；只 showInactive。
**必须保留 UX**：reduce-motion/reduce-transparency 兜底（@Environment + NSWorkspace 监听）、
键帽渲染与 formatHotkey、mark 脉冲、System 卡折叠持久化（@AppStorage）、Setup 4% 占位 +
600ms 延迟跳转、toolbar hiddenInset、overlay 绝不 activate/focus 主窗（AGENTS.md）。
**死代码**：`src/dictation/*`（孤儿 TS 原型，测试跑在无用实现上——删或把测试映射到
electron/ JS 语义）；`VocabularySettings.tsx`（功能完成未接线——原生侧显式决定是否上线）。

---

## 15. 模型存储 / 下载 / 词汇扫描 / 权限 / 设置

### 15.1 模型/产物清单（实测字节）

| 角色 | 产物 | 状态 | 位置 | 大小 | 获取 |
|---|---|---|---|---|---|
| transcription | Parakeet TDT 0.6b v3 CoreML (FluidAudio) | active | `~/Library/Application Support/FluidAudio/Models/` | ~470MB | helper 首启自动（无进度 UI） |
| transcription | transcription-helper 二进制 | active | resources/bin/ | 16.3MB | postinstall swift build |
| transcription（旧） | whisper-server + libwhisper/ggml dylibs | dormant | resources/bin/ | ~3MB | model-artifacts.mjs 编译 |
| transcription（旧） | ggml-base.en.bin | dormant（MODELS 仍列） | resources/models/ | 141MB | 源码 stage / **打包首启仍下载（浪费）** |
| rewrite | smollm2-1.7b-instruct-q4_k_m.gguf | active | resources/models/ 或 userData/models | 1.0GB | fetch-llama.sh / ensureModels |
| rewrite | llama.cpp b10625 整目录 | active | resources/bin/llama/（@loader_path 自包含） | ~52MB | fetch-llama.sh 解包 |

打包 extraResources **只拷 resources/bin，模型永不入包** → 打包首启 ~1.2GB 下载
（Setup 文案一致）。dev 下 `resources/models` 已有两权重（源码安装路径）。

### 15.2 modelStore：路径/完整性/下载

- `resolveModelPath`：userData/models 优先 → 回退 resources/models；路径一律 `start()` 时解析
  （#249 后首启才存在）。
- good-enough = exists ∧ size===bytes；下载 = **每次删旧 .part（无断点续传）→ 流式 sha256+
  写 .part → 校验通过 rename**；redirect ≤5 跳；checksum 失败删 .part 抛错；`modelsMissing()`
  只查存在性（坏文件由 ensureModels 的 size 判定触发重下）。
- **镜像缺口（文档/代码不一致）**：JS modelStore 与 fetch-llama.sh **未实现**
  REGISTRY_URL/HF_ENDPOINT（requirements F12 声称已 honor）；镜像只在 FluidAudio
  ModelRegistry（REGISTRY_URL/MODEL_REGISTRY_URL 优先级，不读 HF_ENDPOINT）——**受限网络
  部署时注意**。

### 15.3 启动 gating 与 Setup

`modelsMissing()` → 主窗开 Setup → `bringUpModels()`：`ensureModels(onProgress=sendSetupProgress,
latch lastSetupProgress)` → modelsReady → startModelServers（transcription-helper + llama-server）
→ `maybeStartHotkey`。热键武装四条件：`!hotkeyStarted ∧ captureReady ∧ modelsReady ∧ shortcut`。
两条路径：源码（postinstall stage，无网络首启）vs 打包首启（Setup 进度、Try again 重跑、关窗
不中断——下载在主进程跑）。

### 15.4 权限（TCC）与 doctor

必需 Accessibility + Input Monitoring、可选 Mic（首录时系统内联重询）。verdict 逻辑 §6.5；
数据 = accessibility-helper `permissions` + systemPreferences。`npm run doctor` 用同一判定
（helper 起不来 exit 2）。**rebuild 重置授权**：ad-hoc 签名 CDHash 不稳（#88）→ 每次重建
TCC 绑旧二进制；修法：删旧条目再授权。签名（#11，v2.0）才根治。

### 15.5 词汇扫描（F11）与设置

- 常量：20 扩展名、~70 关键词黑名单、min 3 字符、单文件 ≤256KB、≤2000 文件、top150、
  800 字符 prompt。流程：`git ls-files` → 过滤 → 频率降序 → buildPrompt。缓存纯内存；
  rescan 失败保留旧缓存。每句听写 `getPrompt()` → 当前被 Parakeet 忽略（§9.2）。
- **现状**：后端+IPC+handler 完整，`VocabularySettings.tsx` 无人 import（UI 未挂载）。
- settings.json：schema/校验/原子写见 §6.4。
- **break-safe 默认名单（14）**：TextEdit / Notes / Obsidian / VS Code / Bear / iA Writer /
  Ulysses / Scrivener / Pages / Word / Xcode / Sublime Text / Zed / Notion——
  **无终端、无聊天、无浏览器**（新行可能提交半成品，注释写明）。

---

## 16. 测试与质量策略

### 16.1 分层

| 层 | 手段 | 覆盖 | 局限 |
|---|---|---|---|
| 纯逻辑 | `npm test` = `vitest run && node --test "electron/**/*.test.js"` | rules（全规则输出级断言 + 性能 <5ms@200 次）/ voiceEdit / coordinator 结局矩阵 / paste 7 态 / supervisor 重启 / settingsStore / permissions / modelStore / windowState / overlayPosition… | 无法覆盖真实麦克风/热键/AX/跨 App 注入 |
| Swift | Swift Testing `@Test` | InjectionEngine 17 例（fakes，SimulatedTime 把 400–1200ms 压微秒）、HotkeyMatcher 12 例 | 决策逻辑可测、真实 AX/CGEvent 不可测 |
| 类型/构建 | `tsc --noEmit` + Vite build | CI 只跑 `npm ci && npm run build` | **CI 不跑测试套件**（已知缺口） |
| 手工 | `docs/testing/*`、`verify-dictation-pipeline.sh`、`npm run doctor` | 热键/权限/波形/跨 App 注入/首启/延迟（#228 验证报告：暖机 150–260ms） | 需真人真机 |

### 16.2 已知缺口

CI 不跑 npm test；无自动化延迟回归（看日志行）；realDictation fixture 空 → 一例 skip（#171）；
`src/dictation/*.test.ts` 测死代码；UI 行为（轮询/页面/chips/setup/permissions 渲染）基本无测试；
转录 helper 无 Swift 测试（仓库未见 Tests 目录）。

### 16.3 方法论资产（改架构先读）

`spike/llm-cleanup-latency`（ADR-0001）、`spike/break-position-67`、`spike/list-boundaries-125`、
`prototypes/injection-62|thresholds-74`、`electron-ax-tree-10`（AX 就绪延迟）、
`ax-notification-terminal-173`、`voice-edit-fidelity-222`（语音编辑该不该用模型 → 否）、
`tcc-attribution-46`。原则：**改行为先找对应 spike 的数据，别拍脑袋**。

---

## 17. 对原生 Swift 改写的结论与行动项

> 承接 [`docs/planning/native-swift-rewrite.md`](native-swift-rewrite.md) 的“四桶拆分”；
> 本节的每一行都由本文件 §4–§15 的源码级细读支撑。改写目标 = 单 Swift app，
> 纯逻辑移植、Electron 脚手架删除、三 helper 复用/进程内化（隔离决策是 ADR 级开放问题）。

### 17.1 四桶拆分（更新版，附实测行数）

| 桶 | 内容 | 处置 |
|---|---|---|
| **A. 已原生（Swift）→ 复用** | hotkey-helper（~163 行 matcher + 145 main）、accessibility-helper（InjectionEngine 168 + RealAdapters 437 + Config + main 156）、transcription-helper（143，FluidAudio AsrManager 已在 SPM） | stdio 删除、改进程内调用；保留协议语义（§17.3） |
| **B. 纯逻辑 → 移植 Swift** | `cleanup/rules.js`(551)、`dictationCoordinator.js`(323)、`voiceEditCoordinator.js`、`voiceEditCommands.js`、`paragraphBreaks.js`(137)、`breakSafety.js`、`hotkeyDefinitions.js`、`pushToTalkCoordinator.js`、`heldResultController.js`、`settingsStore.js`、`permissions.js`、`windowState.js`、`overlayPosition.js`、`appBundleId.js`、`vocabularyScanner/Cache`、paste/#375 分支、`commandReference.ts` 数据 | 全部无 Electron 依赖（可注入 adapter 接口）；各文件均已有 node:test 全量行为锚点 → XCTest 对拍 |
| **C. Electron 脚手架 → 删除** | main.js 的窗口/tray/菜单/单实例/IPC/登录项/CSP、三份 preload+contextBridge、capture 窗 Web Audio（→AVAudioEngine）、overlay 窗（→NSPanel/NSVisualEffectView）、dist/5173、三个 JS supervisor/HTTP 适配层、Setup/Permissions 页（→SwiftUI gate） | 行为清单见 §17.2，逐条对应 |
| **D. 模型层 → 保留/策略** | llama-server 子进程 + 整目录分发（llama.cpp Swift bindings 可后置）；Parakeet 整体进程内（FluidAudio ModelRegistry/ModelHub 复用，env 镜像 REGISTRY_URL） | modelStore 下载逻辑 URLSession 重写，语义保真（§15.2） |

### 17.2 跨模块“不可丢行为”总清单（改写的验收单）

- **不变式**：I1 无 LLM 重写、I2 deny-by-default 换行、I3 进程隔离或等效替代、I4 听写路径
  绝不开/聚焦主窗（#208）——进 AGENTS/架构文档。
- **结局语义**：delivered/pasted/info/held/failed/no-speech/empty 全矩阵 + held 规则
  （hold 不改剪贴板、copy 单次、dismiss 防陈旧、下次录音自动 dismiss）+ 日志单行可 grep
  （含 release-to-insertion 延迟断言、`[dictation] outcome`、`[voice-edit]`）。
- **上下文/安全**：#181 unknown-field 安全默认、#307 break-safe App 内 AX 猜测不压制断句、
  #355 双层 app-switch guard（coordinator 快照 + helper 注入中 abort，rung3 逐字符 poll）、
  #227 context/注入失败 → held 不丢字、#375 粘贴多行仅 break-safe、14 项默认白名单。
- **文本层**：rules.js 全规则顺序与门槛（§10，尤其 spell-out 必须在 collapseRepeats 前）、
  断句 BREAKS/LIST 契约 + fail-closed + LIST dormant、vocab 固定词表、one-line 语义。
- **原生层**：settle guard（400/1200）、rung 链（rung1 读回验证、rung2 .privateState ⌘V +
  changeCount 还原、rung3 仅“可验证且失败”）、盲贴 gate（800ms）、pasteFirst（#368）、
  Config 全阈值、tracker 轮询线程/warmUp 60s、热键 standalone 修饰键 flagsChanged 语义、
  Fn/CapsLock/F 键可达性、热键更换原子性。
- **生命周期**：启动决策树（模型门/权限门/首启/登录 3s 延迟）、热键四条件门控、tray
  tooltip 权限降级、关窗退 tray、overlay 点击穿透/全空间/held 临时可交互/按光标屏重定位、
  Escape 仅录制期、模型加载失败恒 starting、Setup 关窗不中断 + 进度 latch、单实例语义。
- **语言/边界**：English-first（Parakeet 多语言未接出）；short-clip 专有名词、数字拼写为
  v1.1 已知粗糙（#321/#322/#332）。⚠️ 语言范围正在被 ADR-0004（proposed）部分重开：zh
  profile 若采纳，本清单新增“zh 规则 profile（~+300–400 行）、zh 转录 holder、CJK 字体
  回退、`lang` 字段发送、IME 验证”等验收项（见 requirements §5）。

### 17.3 进程隔离决策（ADR 级，改写最先要定）

- **论据**（AGENTS.md/README/phase-1 §3/requirements）：单进程持双权限时，一次卡死的 AX
  调用能拖死全局热键 tap；helper 主线程停 readLine、从不 pump runloop 是结构性事实。
- **内化可用依据**：InjectionEngine 已全 protocol（可注入 real/fake）、budget/deadline 机制
  齐备（Config 表）、HotkeyMatcher 是纯状态机、FluidAudio 已是 SPM。
- **内化必须重供**：AX 串行队列 + 每调用 deadline（AX 无取消 API，只有 messaging timeout）；
  tracker 轮询/warmUp 各自需要会 pump 的线程；**热键 tap 必须独占一个 pump CFRunLoop 的
  线程**（现即独立进程主线程）；CGEvent.post 注入与 tap 并存的事件次序。
- **TCC 含义**：内化 = 回到 #26 否决的“单二进制持 IM+AX”拓扑，隔离靠线程/队列而非 TCC；
  权限归属收敛为单一二进制身份，但 rebuild 重绑权问题（#88）与签名相关、不随内化消失。
- **stdio 删除后保留语义**：id 乱序回包、请求超时 reject、ready 门、崩溃重启 + pending
  fail-fast、delivered|held 文案、down/up 顺序与 ts、热键更换原子性。

### 17.4 推荐行动顺序（对齐 native-swift-rewrite §8 并细化）

1. **先定进程隔离**（§17.3）并记 ADR——它决定三个 helper 的接入形态。
2. **冻结行为、先移植纯逻辑**：rules.js → voiceEditCommands/Coordinator → paragraphBreaks →
   dictationCoordinator → 附属纯模块；把 node:test 逐条搬成 XCTest（§10.7/§16 是对拍清单）。
3. **再把 helper 进程内化**（或保留进程）：transcription（删 blocking() 桥改 async，最易）→
   accessibility（先跑通 InjectionEngine 注入 real adapters）→ hotkey（独立线程 + 事件源）。
4. **替换外壳为 SwiftUI/NSPanel**：gate 状态机 → Home/Commands/Settings/Permissions/Setup；
   overlay 用 NSPanel；事件模型改推送（§14.5）。
5. **模型/下载重写**：URLSession 版 modelStore（保真 §15.2）、llama-server 维持子进程、
   修掉遗留不一致（§18.2）。
6. **清理**：删 dormant whisper 路径（#326）、dead `src/dictation`、未接线 Vocabulary UI 决策。

### 17.5 风险（相对原风险清单的更新）

- **行为保真仍是头号风险**：移植面虽小但 issue 密度极高（本文件到处是 #NNN）。缓解 =
  测试对拍 + 保留诊断事件名。
- **代理细读发现的待修不一致**（顺手可修）：JS modelStore 未 honor 镜像 env（requirements
  F12 不符）；Home.tsx 转录行副标题仍是 “Local · whisper.cpp”（陈旧文案）；打包首启仍下载
  141MB whisper 死权重；`resources/bin` 根散落 ggml0.20.2/libwhisper dylibs（whisper dormant
  产物）；`rewriteModelServer` spawn 未显式设 cwd（与 @loader_path 注释矛盾，[UNKNOWN] 待核实）；
  requirements F2 的分句门槛漏了“被切句须 ≥30 词”与 remainder 计数口径（文档更新）；
  commandReference 把 F2 句点切分与 F3 段落放置混述（文档措辞）。
- 其余风险沿用 native-swift-rewrite §5：行为保真、隔离再论证、模型下载 parity（#249 转录
  无进度屏）、scope creep（先 1:1 再迭代）、以及 TCC/签名（v2.0）。

---

## 18. 附录：参考文档、遗留路径与开放问题

### 18.1 必读文档（含本文档关系）

| 目的 | 文档 |
|---|---|
| 术语与避免用词 | `CONTEXT.md` |
| 硬不变式与工程规范 | `AGENTS.md`、`docs/agents/*` |
| 决策记录 | `docs/adr/0001`（无 LLM 清理）、`0002`（两段式）、`0003`（Parakeet） |
| 功能/UI 规格 | `docs/planning/requirements.md` |
| 中文扩展影响分析 | [`docs/planning/zh-extension-impact.md`](zh-extension-impact.md)（ADR-0004 配套） |
| 改写可行性 | `docs/planning/native-swift-rewrite.md`、本文档（本文件是其“源码级展开”） |
| 沿革 | `docs/progress/phase-{1..4}-progress.md`（§13 为最新，覆盖旧文冲突） |
| 研究 | `docs/research/issue-33-electron-mic-capture.md`、`issue-208-electron-dock-focus.md`、`model-licensing.md`、`whisper-cleanup-configuration.md`、`prompted-local-model-cleanup.md` |
| 手工验证 | `docs/testing/*`（含 #228 验证报告） |
| 竞品/营销 | `docs/competitive/opensuperwhisper.md`、`docs/marketing/spread-the-word.md` |

### 18.2 遗留/半成品路径（改动前先读）

| 路径 | 状态 | 处理建议 |
|---|---|---|
| `whisperServer.js`、`transcriptionHttpAdapter.js`、`build-whisper.sh`、`whisper-server` + ggml/libwhisper dylibs、`ggml-base.en.bin`、modelStore whisper 条目、model-artifacts.mjs transcription 角色 | dormant/疑似死角色 | #326 移除；改写一并清（注意 postinstall 现仍编译 whisper-server——浪费时间与网络） |
| `prepare-model-artifacts.mjs` vs `fetch-llama.sh` | 曾致 #172 事故 | 保持“一产物一路径” |
| `src/dictation/*` | dead 孤儿 TS | 删除或把测试映射到 electron/ JS 语义 |
| `VocabularySettings.tsx` + bridge/IPC | 功能完成未接线 | 改写时显式决定是否上线（F11/U5） |
| 签名/公证/Homebrew/自动更新 | 无（v2.0，#11） | 与 TCC 授权稳定性直接相关（#46/#88） |
| Home.tsx “whisper.cpp” 副标题、镜像 env 缺口 | 陈旧/不一致 | 顺手修 |

### 18.3 开放问题

1. **进程隔离**：合入进程 vs 保留进程/专用线程队列（§17.3，ADR 级）。
2. **UI 框架**：SwiftUI vs AppKit（overlay hud 材质、hiddenInset toolbar 偏向 AppKit 包一层）。
3. **改写模型服务器**：llama-server 子进程保留 vs llama.cpp Swift bindings。
4. **分发**：签名/公证后是否转“下载安装”主路径（影响 TCC 与首启下载 UX）。
5. **断句 LIST 维度**：#125 契约与诊断保留、渲染门控关——原生侧是否启用取决于
   是否存在模型能稳定处理的 prompt。
6. **llama-server spawn cwd**：注释要求从解压目录运行而代码未设 cwd——移植前核实。
7. **语言范围**：ADR-0002 已由 ADR-0004（proposed，2026-09-09 出现在仓库）部分取代——
   zh profile（`cmn`/`yue` → `zh-Hans`）已拟议但**未生效**（requirements §5.13 门：转录
   holder 基准、双 eval 语料、断句模型 zh gate）；#252 的剩余范围（自动检测等）仍开放。

---

*本文件应与代码保持同步：行为变更时更新对应章节；原生改写落地后，把 §17 及其四桶清单逐步标记为
“已执行”，并把它从“现状文档”改造成“改写验收单 + 新架构文档”的过渡物。*
