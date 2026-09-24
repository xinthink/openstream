# Feasibility: a full native-Swift rewrite of OpenStream

> Status: **proposal / feasibility study** (no code). Written 2026-09-08 against the
> current `main` (`56f8545`). See `AGENTS.md` for the one hard invariant this
> proposal must honour.

## Summary

OpenStream becomes a **single native macOS app** (Swift + SwiftUI/AppKit). Electron,
Node, and all JS/TS are removed. The three OS-integration helpers (hotkey, AX
injection, Parakeet transcription) are already standalone Swift executables and are
reused. The real work is smaller than a line count suggests, because the Electron
codebase splits into **four buckets with very different fates**:

- **~5,000+ lines — deleted**, not ported: windows, tray, menus, IPC/`contextBridge`,
  the three subprocess supervisors, the overlay/capture renderer windows.
- **~2,000 lines — ported to Swift**: the pure logic that actually runs the product
  (dictation pipeline, rules cleanup, paragraph breaks, voice-edit, settings, model
  download, vocabulary scan).
- **~2,460 lines — rewritten to SwiftUI**: the React renderer. Not a 1:1 port; the
  visual spec already exists (`prototypes/desktop-ui-211/`, issue #211).
- **~60 KB of Swift — reused unchanged**: the three helpers + the FluidAudio ASR
  library.

There is no technical blocker: every macOS capability Electron provides has a direct
native equivalent, and the three hardest parts are already Swift. The dominant risk is
**behavioural fidelity** across that ~2,000-line logic core (which encodes a dense
history of issue-driven edge cases), not technical difficulty.

---

## 1. The decision

Target: a **fully native app**. No Electron, no Node, no JS at runtime. This is the
outcome of an explicit scoping decision — *not* "native UI in front of a headless
Electron/Node backend". The JS logic core is ported to Swift; the rest of Electron is
discarded.

> Rationale worth recording: earlier the question was framed as "keep the Electron
> main process as a headless backend and put a native UI in front of it". That was
> rejected. It would have kept ~180 MB of Electron and a Node runtime alive solely as
> a daemon, and preserved the exact stdio-JSON plumbing a native build can delete.
> The chosen path folds everything into one Swift app.

---

## 2. Current architecture: four buckets

Line counts exclude tests unless stated.

### (a) Already native Swift — reused, not rewritten

| Component | Path | Approx. size | Role |
|---|---|---|---|
| Hotkey matcher (CGEventTap) | `native/hotkey-helper/` | ~11 KB | Global push-to-talk key; Input Monitoring |
| AX injection engine | `native/accessibility-helper/` | ~44 KB | Context detection + text injection + selection read |
| Parakeet transcription server | `native/transcription-helper/` | ~5 KB own code | Wraps FluidAudio; CoreML on the Neural Engine |
| FluidAudio (3rd-party SPM dep) | `.build/checkouts/FluidAudio` | ~139 K lines | All ASR (Parakeet TDT v3), model download |

These already speak a newline-delimited JSON protocol over stdio, each fronted by a JS
"supervisor" in Electron that spawns, restarts, and forwards to it.

### (b) Electron scaffolding — deleted outright

| Component | Path | Lines | Why it dies |
|---|---|---|---|
| Main-process shell | `electron/main.js` | ~1,050 | windows, tray, menus, IPC, lifecycle — all become native |
| IPC surface | `electron/preload.js` + `src/openstreamBridge.d.ts` | — | no `contextBridge` in a native app |
| Helper supervisors | `electron/hotkeyHelper.js`, `accessibilityHelper.js`, `transcriptionHelper.js` | 249 + 204 + 183 | helpers become in-process calls |
| Rewrite-model supervisor | `electron/modelSupervisor.js` | ~50 | subsumed by direct `Process` management |
| Overlay HUD | `electron/overlay/*` | ~100 | native `NSWindow` + `NSVisualEffectView` |
| Mic capture window | `electron/capture/captureWindow.html` | — | `AVAudioEngine` in-process |
| Shortcut capture | `electron/pushToTalkShortcutController.js` + `shortcutCaptureController.js` | ~190 | native key handling |

### (c) Pure logic — ported to Swift

| Component | Path | Lines | Notes |
|---|---|---|---|
| Dictation intake pipeline | `electron/dictationCoordinator.js` | 323 | transcribe → cleanup → break-placement → deliver |
| Rules cleanup engine | `electron/cleanup/rules.js` | 551 | deterministic regex cleanup, <1 ms budget |
| Paragraph-break placement | `electron/paragraphBreaks.js` | 137 | sentence split + break-index repair |
| Voice-edit intake + grammar | `electron/voiceEditCoordinator.js` + `voiceEditCommands.js` | 149 + 158 | deterministic text transforms |
| Settings persistence | `electron/settingsStore.js` | 192 | JSON file |
| Model download | `electron/modelStore.js` | 175 | first-run weights fetch |
| Vocabulary scanner | `electron/vocabularyScanner.js` + `vocabularyCache.js` | ~150 | git-grep based |
| Rewrite model server | `electron/rewriteModelServer.js` | ~106 | supervises `llama-server` |

**≈ 2,000 lines of pure logic** — this is the true port surface, not the full
Electron tree. Much of it is small, deterministic, and already covered by tests.

### (d) The renderer — rewritten to SwiftUI

`src/**` is ~2,464 lines of React/TS: five pages (Home, Commands, Settings,
Permissions, Setup), plus presentational components (`Icons`, `KeyCaps`, `Mark`,
`StatusPill`, `Toggle`) and two feature controls (`HotkeySettings`,
`BreakSafeAppsSettings`, `VocabularySettings`). It is replaced, not translated.

A visual spec already exists and de-risks this: `prototypes/desktop-ui-211/`
(issue #211) defines the design language — Apple system-blue accent (`#007AFF` /
`#0A84FF`), SF, `titleBarStyle: hiddenInset`, vibrancy only on the toolbar strip,
760×580 default — and the issue map (#206 UI map, #209 Dock-app decision, #210 page
model, #212 "the build is a translation job, not a design job") is complete. Note the
spec was scoped to two pages (Home + Settings); the shipped app has since added a
Commands tab and Permissions/Setup pages, so those three need a small design extension
on top of the existing tokens.

---

## 3. Component-by-component mapping to native Swift

| Concern | Today (Electron/JS) | Native rewrite |
|---|---|---|
| App shell / tray / menu | `BrowserWindow`, `Tray`, `Menu`, `app` | `NSApplication`, `NSStatusItem`, `NSMenu`, `NSWindow` |
| Global hotkey | `hotkey-helper` subprocess + `hotkeyHelper.js` | the existing `HotkeyMatcher` called in-process (or a dedicated thread) |
| Text injection / context | `accessibility-helper` subprocess + `accessibilityHelper.js` | the existing `InjectionEngine`/`RealAdapters` called in-process |
| Transcription | `transcription-helper` subprocess + `transcriptionHelper.js` | `FluidAudio` `AsrManager` called in-process (already a SPM dep) |
| Mic capture | Web Audio `getUserMedia` + manual WAV | `AVAudioEngine` input tap → 16 kHz/16-bit PCM → WAV |
| Rules cleanup | `cleanup/rules.js` (regex) | Swift `NSRegularExpression` (ICU — supports lookbehind/backrefs) |
| Dictation pipeline | `dictationCoordinator.js` | a Swift orchestrator (`struct`/`actor`) with the same state machine |
| Paragraph-break placement | `llama-server` subprocess over HTTP | unchanged `llama-server` subprocess, **or** defer (see §4) |
| Settings | JSON via `settingsStore.js` | `Codable` + JSON, or `UserDefaults` |
| Vocabulary scanner | git-grep from Node | `Process` + git, or `git2`/`SwiftGit2` |
| Model download | `modelStore.js` | Swift `URLSession`; **reuse FluidAudio's `ModelRegistry`** (already honours `REGISTRY_URL` mirroring) |
| UI (5 pages) | React + `index.css` | SwiftUI (or AppKit), against `prototypes/desktop-ui-211` |
| Overlay HUD | frameless vibrancy `BrowserWindow` | `NSWindow` + `NSVisualEffectView` (native `hud` material) |
| Permissions | `systemPreferences`, `AXIsProcessTrusted`, `IOHIDCheckAccess` | same APIs, already used in the helpers |

Every row has a direct, well-understood native equivalent. No missing-capability
blockers.

---

## 4. Feasibility per concern

| Concern | Feasibility | Notes / risk |
|---|---|---|
| Hotkey, AX injection, transcription | **Trivial** | Already Swift. In-process call replaces stdio. |
| Mic capture | **Easy** | `AVAudioEngine` is simpler than the current Web-Audio+manual-WAV path. |
| Rules cleanup port | **Medium (labour)** | ~550 lines of regex with lookbehind/backrefs/`g`-replace-callbacks. `NSRegularExpression` (ICU) supports all of it, but the API is far more verbose than JS `String.replace`, and the callback-based rules (`applyCurrency`, `applySpellOut`) become manual match loops. |
| Dictation pipeline | **Medium** | Straightforward state machine, but it encodes ~40 referenced edge cases (`#355` app-switch guard, `#307` one-line guess, `#181` AX-not-ready, paste gating `#375`…). Faithfulness, not difficulty, is the risk. |
| Voice-edit grammar | **Easy** | Finite deterministic grammar (`voiceEditCommands.js`, 158 lines). |
| UI (5 pages + overlay) | **Medium** | Spec exists for the core (Home/Settings); Commands/Permissions/Setup need a small extension. The overlay is arguably *easier* natively (`NSVisualEffectView` vs Electron's vibrancy quirks in `main.js` #300/#350). |
| Settings / model download / vocab scanner | **Easy** | `Codable`/`URLSession`/`Process`+git; model download can reuse FluidAudio's `ModelRegistry` mirror support. |
| Rewrite model server (`llama-server`) | **Defer or subprocess** | `llama-server` is a C++ binary; a native app still runs it as a subprocess (as today) unless `llama.cpp` Swift bindings are adopted later. |
| Packaging / distribution | **Easy** | No `electron-builder`; a signed/notarised `.app` via Xcode archiving. |

**No concern is technically blocked.**

---

## 5. Key risks

1. **Behavioural fidelity is the dominant risk.** `dictationCoordinator.js`,
   `rules.js`, and `paragraphBreaks.js` carry a dense history of subtle, issue-driven
   behaviour (many comments cite `#NNN`). A faithful port must preserve all of it.
   The mitigation is the existing test suites (`rules.test.js`,
   `dictationCoordinator.test.js`, `voiceEdit*`, `paragraphBreaks`, etc.) ported to
   XCTest and made to pass unchanged.
2. **Process isolation is a deliberate design decision, not an accident.** The
   README and `AGENTS.md` record that hotkey and injection run as *separate
   processes* so a stalled AX call cannot starve the hotkey tap. Folding in-process
   removes that isolation; it must be re-provided (dedicated threads / a serial AX
   queue with deadlines, which `InjectionEngine` already uses budgets for) or the
   isolation re-justified. This is the one architectural decision the rewrite must
   make deliberately.
3. **The hard invariant** (`AGENTS.md`): the desktop window must never be opened or
   focused from the dictation pipeline. The native app must preserve this discipline
   (`NSWindow.orderFront` / `NSApp.activate` only from user actions).
4. **Parity of the model-download / first-run flow** (`#249`): packaged app fetches
   weights on first run; source install places them under `resources/models`. The
   rewrite must keep both paths and keep honouring `REGISTRY_URL`/`HF_ENDPOINT`
   mirroring (relevant on restricted networks, as recorded in this repo's run book).
5. **Scope creep.** The rewrite is an opportunity to also fix the known rough edges
   (issue #340). Recommendation: do **not** fold behaviour changes into the port —
   port 1:1 first, then iterate.

---

## 6. Benefits

- Delete ~5,000 lines of Electron scaffolding (windows, tray, IPC, three subprocess
  supervisors, three stdio JSON protocols).
- Drop Electron/Node/Vite/React → a single SwiftPM/Xcode build; ~180 MB smaller
  runtime, lower idle memory, no renderer sandbox/`contextBridge` surface.
- Direct access to the helpers' APIs (no JSON round-trips, no restart race).
- Native UI and vibrancy without Electron's documented quirks.
- Simpler distribution (a single signed/notarised `.app`, no unsigned-DMG caveat the
  current README warns about).

---

## 7. Effort estimate

Rough, for a developer familiar with both codebases:

- Port the ~2,000-line logic core (rules, coordinator, paragraphBreaks, voice-edit,
  settings, vocab, modelStore, rewrite-server supervision) ≈ **1.5–2 weeks**.
- Merge the 3 helpers in-process + remove supervisors ≈ **3–5 days**.
- Rewrite the UI (5 pages + overlay + tray) in SwiftUI, against the existing spec ≈
  **1–1.5 weeks**.
- Port the test suites to XCTest and reach parity ≈ **1–2 weeks**.
- App shell, permissions, packaging, first-run flow ≈ **1 week**.

**Total: roughly 4–7 weeks** for a faithful, tested, shippable rewrite. The
uncertainty is dominated by behavioural parity (risk #1), not by volume — the
~2,000-line core is small but dense.

---

## 8. Recommended approach (if green-lit)

1. **Freeze behaviour.** Port the pipeline and `rules.js` to Swift 1:1 against the
   existing tests (ported to XCTest), with no behaviour changes.
2. **Lift the three helpers in-process** first (highest simplification, lowest
   behaviour risk), then replace the Electron shell around them.
3. **Ship the UI last**, once the dictation core is proven against the test suite.
4. Keep `llama-server` as a subprocess initially; revisit `llama.cpp` Swift bindings
   only after the rest has landed.
5. Decide the process-isolation question explicitly (risk #2) and record it as an ADR
   before the merge.

---

## 9. Open questions

1. **Process isolation**: keep separate processes (hotkey / AX / ASR) or merge
   in-process with thread/queue isolation? (ADR-worthy.)
2. **UI framework**: SwiftUI vs AppKit (the overlay's `hud` vibrancy and the
   "hiddenInset" toolbar favour AppKit's `NSVisualEffectView`; SwiftUI is faster to
   iterate).
3. **Rewrite model server**: keep `llama-server` subprocess, or move to `llama.cpp`
   Swift bindings?
4. **Distribution**: does a signed/notarised build become the supported install path
   (resolving issues #11/#37), or stay source-first?

---

## 10. Conclusion

A full native-Swift rewrite of OpenStream — no Electron, Node, or JS at runtime — is
**feasible today** with no technical blockers: the hard parts are already Swift, the
true port surface is a ~2,000-line logic core, and the UI has an existing design spec.
The real cost is **behavioural fidelity across that core** and the deliberate
preservation of the process-isolation and never-focus-the-window invariants.
Recommended as a **phased port under test parity**, not a big-bang rewrite, with an
estimated **4–7 week** effort.
