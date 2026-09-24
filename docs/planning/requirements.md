# OpenStream — Functional & UI Requirements

> **Purpose.** This is the requirements spec for a native-Swift re-implementation
> (no Electron, no Node, no JS at runtime). It is extracted 1:1 from the current
> `main` (`56f8545`) so the native build is a *translation*, not a redesign. Where a
> behaviour is subtle or issue-driven, the issue number is cited — the port must
> preserve it.
>
> Companion docs: `docs/planning/native-swift-rewrite.md` (feasibility & phasing),
> `CONTEXT.md` (glossary — use its vocabulary), `AGENTS.md` (hard invariants),
> `docs/design/visual-identity.md` (UI tokens), `docs/adr/` (decisions).
>
> **Extension (2026-09-08): §5 adds Chinese input/output support.** §0–§4 are the
> untouched 1:1 translation baseline; §5 is a scoped extension layered on top of it
> and says so wherever it changes a §0–§4 requirement. "Chinese" here means spoken
> **Mandarin (普通话) and Cantonese (广东话)** delivered as written **Simplified
> Chinese** — no Traditional-Chinese output profile. The extension deliberately
> conflicts with ADR-0002's "English-only stands" position and is **not in force until
> that ADR is revisited** — the required follow-ups are in §5.13.

---

## 0. Product definition & invariants

OpenStream is a **local-first, push-to-talk voice dictation app for macOS**. The
user holds a key, speaks, releases, and the cleaned text lands at the cursor in
whatever app is frontmost. Nothing leaves the machine; there is no account.

**One dictation act** (`CONTEXT.md`): begins at push-to-talk key-down, ends when
text lands (or is held). The **dictation latency budget** is *end-of-speech to
text-ready under 1 second* (ADR-0001).

**Hard invariants** (non-negotiable, from `AGENTS.md` + `CONTEXT.md`):

1. **The desktop window must never be opened or focused from the dictation
   pipeline.** `createWindow()` / `win.show()` / `win.focus()` / `app.focus()` are
   reachable *only* from explicit user actions: tray item, Dock `activate`, second
   launch, first run, or an app-menu item. Nothing in the dictation/voice-edit/
   capture/hotkey/overlay path may raise or focus the window.
2. **Deny-by-default break-safety.** A literal line break can execute a half-typed
   terminal command or send an unfinished message, so *every* app not on the
   break-safe allow-list is treated as unsafe.
3. **No LLM rewrites dictated words.** Cleanup is a deterministic rules engine
   (< 1 ms). The only model that runs during dictation is the rewrite model, which
   answers *where paragraph breaks go* as sentence indices and never returns text.
4. **Process isolation is deliberate.** Hotkey and text injection run as *separate
   processes* so a stalled Accessibility call cannot starve the hotkey tap. A native
   merge must re-provide this isolation (dedicated thread / serial AX queue with
   deadlines) or re-justify it — see `native-swift-rewrite.md` risk #2.

---

## 1. Functional requirements

### F1 — Push-to-talk dictation (core loop)

- Hold the global push-to-talk key → recording starts; release → recording stops and
  the transcript is processed; the result is injected at the cursor in the frontmost
  app.
- **Escape cancels** a recording in progress: audio is thrown away, nothing is
  processed, no "recording-complete" fires. The Escape handler is registered only
  while recording, so it never hijacks Escape from the target app otherwise.
- If the key goes down while text is **selected** (1…5000 chars), the recording is a
  **voice edit** (F4), not dictation. The selection read happens async at key-down and
  must never delay recording; a failed read just means "ordinary dictation".
- **Stuck-recording safety**: if key-up never arrives, recording is force-stopped
  after a timeout and the event is logged (never silently left recording forever).

### F2 — Rules cleanup engine (deterministic, < 1 ms)

Applied to every dictation transcript in this order (`rules.js`): trim → collapse the
transcriber's hard line-wraps to spaces → self-correction → spell-out → strip fillers
→ collapse repeats → spoken punctuation → emoji → quote markers → currency → strip
leading fillers → sentence segmentation (skipped in one-line fields) → capitalise →
fixed-vocab casing → terminal punctuation → collapse double spaces.

**Spoken punctuation** (word → mark). Break commands (`new paragraph`, `new line`,
`bullet point(s)`/`new|next bullet(s)`, `tab`/`indent`) are gated: they only become a
literal `\n`/`\n\n`/`\n- `/`\t` when the frontmost app is **break-safe**; otherwise
they degrade to a space. All others always apply.

| Spoken | Result |
|---|---|
| new paragraph / new line | `\n\n` / `\n` (break-safe only) |
| bullet point(s) · new/next bullet(s) | `\n- ` (break-safe only) |
| tab · indent | `\t` (break-safe only, clause-start only) |
| full stop · period | `.` |
| comma | `,` |
| question mark | `?` |
| exclamation mark · exclamation point | `!` |
| colon · semicolon | `:` · `;` |
| open/close paren(thesis) | `(` / `)` |
| dash · slash | `-` / `/` |
| percent · dollar sign · at sign · hashtag | `%` `$` `@` `#` |
| open/close brace · open/close bracket | `{` `}` `[` `]` |

**Emoji** (every trigger ends in the word "emoji"; never gated): smiley/smiling face
🙂, heart ❤️, thumbs up 👍, thumbs down 👎, laughing 😂, crying 😢, fire 🔥,
(one) hundred 💯.

**Self-correction** ("scratch that"/"delete that"): deletes the clause immediately
before the trigger — but only when followed by a pause (punctuation/end), and only
one clause back. "delete that file"/"delete that branch" are left alone.

**Spell-out** ("spell j o h n"): 2+ single-letter tokens after the trigger assemble
into a word, capitalised as a proper noun (`John`). Letter-name disambiguation and
confirmation-code casing are explicitly out of scope.

**Fillers** — standalone (`um uh erm er ah hmm mhm`), phrase (`you know`, `i mean`,
`kind of like`, `sort of like`), and leading (`so okay ok well right now basically
actually literally anyway like`, stripped only at sentence start and never to empty).

**Repeats**: `"the the problem"` → `"the problem"`; runs repeatedly so triples
collapse; contractions collapse too.

**Quote markers**: `quote … end quote` → `"…"`; non-greedy so multiple pairs match
separately; never gated.

**Currency**: `fifty dollars` → `$50`; `three dollars and twenty cents` → `$3.20`;
`fifty cents` → `$0.50`. Parses standard number words up to thousands; unrecognised
phrases are left as-is.

**Sentence segmentation** (long dictation only): if ≥ 25 words, split run-on
sentences at `so/and/but/because` only when both sides are long enough to stand alone
(≥ 12 / ≥ 8 words). Known weakness: can land a boundary mid-clause (accepted).

**Capitalisation & terminal punctuation**: capitalise `i` → `I` and `i'm/i've/i'll/i'd`;
capitalise each sentence start (skipping a leading `- `, quote, or tab); ensure the
result ends in `. ! ? :` (add `.` if missing) — except in one-line fields.

**Fixed vocabulary** (always applied, after sentence capitalisation so settled casing
wins): `lama server`/`lama-server`/`llama server` → `llama-server`, `macos` → `macOS`, `ram` →
`RAM`, `hot key` → `hotkey`, `auto update` → `auto-update`, `rules based` →
`rules-based`, `git hub` → `GitHub`, `java script` → `JavaScript`, `type script` →
`TypeScript`.

**One-line field** (`AXTextField` single-line role): no sentence breaks, no final
full stop, no newline — a one-line field cannot hold a newline even in a break-safe
app.

### F3 — Paragraph-break placement (rewrite model server)

- Eligible only when: frontmost app is **break-safe** AND not a one-line field AND
  the raw transcript had **no** explicit break command AND the cleaned text has
  **≥ 3 sentences**.
- The rewrite model (`llama-server`) is asked *which sentence numbers* take a break;
  it answers with **sentence indices, never text**. Contract (`paragraphBreaks.js`):
  ```
  BREAKS: 3, 7        (or "none")
  LIST: 5-8           (optional second line, or "none")
  ```
  A bare `3, 7` reply (the older single-purpose contract) is still accepted whole.
- Replies are **repaired, fail-closed**: indices are clamped to `(1, sentenceCount]`,
  de-duplicated, sorted; a `LIST` range is clamped to `[1, sentenceCount]` and needs
  ≥ 2 items or it is dropped to ordinary prose. A malformed reply degrades to prose,
  never errors.
- List detection is parsed and its diagnostics emitted but **rendering is gated off**
  by default (the current prompt is break-only); a `LIST` line that cannot be read
  cleanly never corrupts the breaks.

### F4 — Voice edit (selection transform)

Triggered when text is selected at key-down. Transcribes the spoken command, matches
it against a fixed finite grammar (`voiceEditCommands.js`), applies a deterministic
transform to the selection captured at key-down, and delivers in place. No model.

**Grammar** (aliases → command):

| Command | Spoken aliases | Result |
|---|---|---|
| snake case | "snake case", "snakecase", "snake case that" | `get_user_name` |
| camel case | "camel case", "camelcase" | `getUserName` |
| pascal case | "pascal case", "upper camel case", "pascalcase" | `GetUserName` |
| kebab case | "kebab case", "dash case", "hyphen case" | `get-user-name` |
| constant case | "screaming snake case", "constant case", "upper snake case" | `GET_USER_NAME` |
| title case | "title case" | `Get User Name` |
| upper / lower | "upper case", "uppercase", "all caps" / "lower case", "lowercase" | `GET USER NAME` / `get user name` |
| wrap | "wrap in quotes"·"add quotes"·"quote that"·"wrap in single quotes"·"wrap in backticks"·"wrap in code"·"wrap in parentheses/brackets"·"wrap in square brackets"·"wrap in braces/curlies" | wraps selection in `""`, `''`, `` ` ` ``, `()`, `[]`, `{}` |
| bullet / numbered list | "bullet list"·"bullet points"… / "numbered list"·"ordered list" | `- item` / `1. item` lines |
| copy that | "copy that", "copy this", "copy it", "copy" | selection → clipboard; document untouched |

- **Identifier-case guard**: an identifier case on obvious prose is a mistake — the
  transform is *declined* if the selection contains punctuation (`[,;:!?(){}\[\]"'`\n]`)
  or has > 6 words. Lists are declined if the selection has a newline or fewer than 2
  comma/`and`/`or`-separated items.
- **Carrier phrases** are tolerated and stripped: "please …", "make this …",
  "turn this into …", "change this to …", "convert this to …", "put this in …",
  and "wrap this/it in …" → "wrap in …".
- **Unrecognised** command → selection left untouched, overlay shows "Command not
  recognised". **Declined** → shows the reason. **Held** when the transform needs
  newlines (a list) but the target can't take them.

### F5 — Paste command

A *bare* whole-utterance "paste" command (`paste`, `paste that`, `paste it`,
`paste clipboard`, `paste the clipboard`, `paste from clipboard`, `paste from the
clipboard`) puts the clipboard at the cursor. "paste the report" types literally.

- Empty clipboard → "Nothing on the clipboard to paste".
- Clipboard > 10,000 chars → refused with a message.
- Multi-line clipboard → only in a break-safe app; otherwise held ("won't paste
  multi-line text into …").
- Delivered through the same injection path; success shows "Pasted".

### F6 — Context detection & break-safety

- Resolve the frontmost app's **bundle id** and the focused field's **AX role** via
  the Accessibility API. Report `bundleId`, `isOneLineField`, and `axReady` (whether
  the role was a real read or a guess).
- **Break-safe** = bundle id is on the allow-list (F10). Deny-by-default.
- **One-line guess override (#307)**: when `isOneLineField` was only a *guess*
  (`axReady === false`) and the app is break-safe, don't let the guess suppress
  spoken break commands — the frontmost thing is almost always the document body.
- **App-switch guard (#355)**: if the frontmost bundle id at transcript-time differs
  from the one captured at key-down, do **not** inject — hold the (safely-cleaned)
  text for manual copy, with a reason naming both apps. Same hold on a failed context
  read (`#227`): keep the words, clean with safe defaults, hold for manual paste.

### F7 — Microphone capture

- Capture mono audio at **16 kHz / 16-bit PCM**, encode to **WAV** (44-byte header).
  The mic and audio graph stay alive between dictations; start/stop only mark which
  frames belong to the current recording.
- Stream a **normalised sound level** (RMS, clamped to `[0,1]`) to the overlay while
  recording; send `0` on stop/cancel.
- If the device can't provide 16 kHz, fail with a clear error (not silent resample).

### F8 — Transcription (Parakeet)

- Transcribe via **NVIDIA Parakeet TDT 0.6b v3** as CoreML on the Neural Engine,
  through **FluidAudio** (ADR-0003). Parakeet returns raw text with native
  punctuation and capitalisation. macOS floor is **14** (Swift 6).
- Vocabulary biasing (F11) builds a prompt but Parakeet currently **ignores** it —
  the prompt is still built and passed for future wiring.
- The helper signals `{"event":"ready"}` before a dictation may proceed.

### F9 — Model server lifecycle (supervisor)

- **Two resident model processes**, started once at app startup and kept alive for
  the app's life: the transcription helper (Parakeet) and the rewrite server
  (`llama-server`). At a login-triggered launch, defer start ~3 s so the Metal
  warm-up (~15–20 s) doesn't fight everything else macOS is starting.
- The supervisor owns start/restart-on-crash/stop for each. A health probe
  distinguishes **ready** vs **starting** (for the Home page).
- On quit, both servers stop.

### F10 — Settings persistence

A single JSON file (`userData/settings.json`). Schema:

- `hotkey`: `{ keyCode: number, modifiers: string[] }`. A single standalone key
  (Option / Command / Control / Fn / Caps Lock, or F1–F19). Default: Option.
  Validation: non-negative integer keyCode; modifiers in `{cmd,shift,alt,ctrl}`;
  a modifier-less shortcut must be a supported single key.
- `breakSafeApps`: string[] of bundle ids. Default list:
  TextEdit, Notes, Obsidian, VS Code, Bear, iA Writer, Ulysses, Scrivener, Pages,
  Word, Xcode, Sublime Text, Zed, Notion. De-duplicated and trimmed on save.
- `vocabularyProjectPath`: string | null (default null — opt-in).
- `windowBounds`: `{ width, height, x?, y? }` | null — last window geometry.
- Launch-at-login is an OS login item (`openAsHidden`, so a login launch starts
  silently in the tray), not a settings field.

### F11 — Vocabulary scanning

- Scan a git repo for project-specific identifiers and turn the top terms into a
  transcription prompt. Runs **once on rescan**, never per dictation; every dictation
  reads the cached prompt.
- Source files only (a fixed extension list); skip generated/binary; skip language
  keywords (denylist); min term length 3; skip pure-digit tokens; read ≤ 2000 files,
  ≤ 256 KB each; keep top 150 terms by frequency; build a prompt within an 800-char
  budget (comma-joined).
- Setting the path persists it and triggers a rescan in the same round-trip. A failed
  scan (bad path / not a git repo) rejects and leaves the previous cache + path intact.

### F12 — Model download & first-run

There are **three** weight-fetch paths, with different UX:

- **Transcription (Parakeet)** — CoreML bundles, ~470 MB, downloaded silently by
  FluidAudio into its own Application Support dir on the transcription helper's first
  run. No progress screen; it surfaces as a "pending" model server until ready
  (first-run parity for this path is tracked under #249).
- **Rewrite (`llama-server`)** — `smollm2-1.7b-instruct-q4_k_m.gguf`, ~1.0 GB, fetched
  by `modelStore.js` with the Setup screen's per-role progress UI.
- **Whisper (`ggml-base.en.bin`)** — ~148 MB, still listed in `modelStore.js` `MODELS`
  and therefore fetched on first run, but **dormant** since ADR-0003 moved
  transcription to Parakeet. A native build should drop it from the fetch list.
- **Source install** places weights under `resources/models`; a **packaged app**
  fetches them on first run to `userData/models` (it can't write its signed bundle).
  `resolveModelPath` prefers the user dir, falls back to bundled.
- A weight is "good enough" if present with the right byte size; full SHA-256 is
  verified once on the download itself (streamed, `.part` file, rename on success).
- Honour `REGISTRY_URL` / `HF_ENDPOINT` mirroring (relevant on restricted networks).
- **Gate**: model servers and the hotkey arm only once weights are in place. A first
  run with missing weights shows the Setup screen with per-role download progress;
  errors are surfaced with a "Try again" retry.

### F13 — Permissions

- **Required**: Accessibility (text injection + context) and Input Monitoring (global
  hotkey). **Optional**: Microphone (prompted on first capture; "pending" until then).
- Verdict shape: `{ ok, grants, blocking, warnings, details }`. `ok` is false when any
  *required* grant is missing; a helper that can't answer leaves its grants "unknown",
  treated as blocking (can't confirm push-to-talk works).
- On startup, if a hard grant is missing, open the window on the **Permissions** page
  (the app silently does nothing on push-to-talk otherwise). A missing grant is also
  reflected in the tray tooltip.

### F14 — App lifecycle & shell

- **Single instance**: a second launch quits immediately (before any setup) and the
  first instance brings its window forward (`second-instance`).
- **Dock app** (regular, not hidden): Dock click with no window re-creates it
  (`activate`); window close **backgrounds** the app — tray, hotkey, and resident
  model servers stay alive. Quit is always explicit (Cmd-Q, app menu, or tray).
- **First launch** (no settings file) opens the window so the user sees it came up
  and learns the shortcut; later launches stay in the tray. A login-triggered launch
  never opens the window (but still surfaces a missing permission).
- **Tray** states: idle (black template glyph), recording (`#5CB8FF`), transcribing
  (`#4FE0D4`); tooltip `OpenStream` (idle) / `OpenStream — recording` /
  `OpenStream — transcribing` (the "editing" voice-edit state reuses the
  transcribing glyph), with `(permissions needed)` appended when degraded. Menu:
  "Open Window", "Quit OpenStream".
- **App menu**: OpenStream (About / Settings… ⌘, / Hide / Hide Others / Show All /
  Quit), Edit (undo/redo/cut/copy/paste/select-all — these roles are what make
  ⌘C/⌘V/⌘A work in the window's fields), Window (minimize/zoom/close).

### F15 — Overlay & held result

- The push-to-talk overlay shows while recording; it also carries the **held result**
  (finished text that couldn't be placed) with Copy / Dismiss, and transient
  voice-edit messages ("Copied", "Pasted", "Command not recognised", a decline
  reason).
- Held-result copy writes to the clipboard and flips the button to "Copied"; dismiss
  hides the panel. The overlay ignores mouse events while idle-recording, and becomes
  focusable/clickable only when showing a held result.
- Overlay is always-on-top, shown on all workspaces (incl. full-screen), positioned
  **bottom-center of the active display**, clear of the Dock, re-positioned on every
  show.

---

## 2. UI requirements

### U1 — App window (chrome)

- macOS chrome kept: traffic lights, **hiddenInset** title bar; the shell paints its
  own toolbar strip behind them. No custom window chrome.
- Runs on native `vibrancy: "hud"` with a **transparent** background; cards/panels are
  a bright near-clear film (`rgba(255,255,255,0.07)`, `blur(8px) saturate(1.7)`) with a
  refracting inset rim, so the desktop reads through as clear glass.
- Default **820×640**, min **560×440** (per `electron/windowState.js`; the
  `prototypes/desktop-ui-211` README's "760×580" is stale). Last bounds persisted and
  sanity-checked against the display before reuse (position kept only if ~80 px of the
  top edge stays on-screen).
- **Reduce Transparency** (`prefers-reduced-transparency`) swaps the whole window to a
  solid navy `#0A1420`. **Reduce Motion** (`prefers-reduced-motion`) calms the
  waveform ripple and mark pulse.

### U2 — Toolbar

Wordmark `~ openstream` (JetBrains Mono, lowercase, shell-prompt prefix) + a
**segmented control** with three tabs: Home, Commands, Settings. (Permissions and
Setup are reachable views, not tabs — navigated to on grant-missing / model-download.)

### U3 — Home page

- **Hero**: the mark (glass tile with a tight blue glow, 32px) + a state-dependent
  headline — "OpenStream is listening" (idle), "Listening…" (recording),
  "Transcribing…" (transcribing), "OpenStream needs a moment" (permission missing) —
  and a hint line showing the current shortcut with `esc` to cancel.
- **Shortcut card**: the push-to-talk key readout + a "Change" link to Settings.
- **System card**: collapsible ("Everything is ready" / "All set") health rows —
  Accessibility, Input Monitoring, Microphone, Transcription model, Rewrite model —
  each with a status pill. When a required permission is missing, the card shows a
  red warning row with a "Fix" button to Permissions. Polls health every ~4 s.
- Live dictation state is reflected from the pipeline (recording / transcribing /
  idle only — not the overlay's fuller vocabulary).

### U4 — Commands page

- A searchable reference of every spoken command, in two sections: **While dictating**
  and **Editing selected text**. Each row: what you say → what it becomes (mono when
  the result is literal output). Filtering matches on either side.
- This is the *human-facing description* of the grammar; its source of truth is
  `rules.js` + `voiceEditCommands.js` and must be kept in step.

### U5 — Settings page

- **Push-to-talk shortcut**: current key readout + guidance, and a "Change shortcut"
  capture flow. Capture listens for a modifier/key (with the Fn standalone transition
  captured natively, since it isn't a reliable key event) and validates the result
  ("Unsupported key" / "unavailable" on conflict).
- **Line breaks by app**: the break-safe allow-list as removable chips, "Add app…"
  (app picker from `/Applications`, resolving a friendly name), "Restore defaults",
  and an advanced "Add by bundle identifier" field.
- **Launch at login**: a toggle (starts silently in the tray; `openAsHidden`).

> **Note — vocabulary UI is unshipped.** The codebase-vocabulary capability (F11) is
> wired end-to-end in the backend and exposed over the IPC bridge, but its settings
> component (`src/VocabularySettings.tsx`) is **not mounted on any page** in the
> current build. The Settings page ships with the three sections above only. A native
> build should decide explicitly whether to surface it.

### U6 — Permissions page

- Two required grants (Accessibility, Input Monitoring) + optional Microphone, each
  with an icon, one-line "why", a status pill (Granted / Not granted / Not asked yet),
  and an "Open Settings" button (deep-links to the right System Settings pane) for
  non-granted required rows.
- A "N of 2 required permissions granted" progress line, a Re-check button, and a
  Continue button when the verdict is OK. Hint about quit-and-reopen / rebuild-resets.

### U7 — Setup page

- First-run model download with per-role progress (Transcription model / Rewrite
  model): phase (check/download/done), percentage, and received/total MB. A one-time
  ~1.2 GB note. On error, a message + "Try again". On `ready`, auto-continues.
  Closing the window does not stop the download.

### U8 — Overlay (push-to-talk HUD)

- A small floating glass panel (resting ~244×50, `hud` material, rounded, shadow,
  always-on-top, click-through) with a status word ("Listening" / "Editing" /
  a voice-edit message) and a **7-bar waveform** drawn in the accent colour. The
  waveform rides a slow idle ripple (Reduce-Motion-aware) rather than going flat when
  the mic is quiet; real levels drive it while recording.
- **Held result** expands the panel (~432×264) to show the unplaceable text (mono)
  with Copy / Dismiss, and makes it clickable.

### U9 — Visual identity (blue glass)

Dark-only. Tokens (from `docs/design/visual-identity.md`, `#350` Liquid):

| Token | Value | Use |
|---|---|---|
| `--bg` | `#0A1420` | solid-navy fallback ground |
| `--screen` / `--screen-2` | `rgba(255,255,255,0.07)` / `0.055` | panels / keycaps, fields, buttons |
| `--rim` | inset `0 1px 0 rgba(255,255,255,0.35)`, `0 -1px 0 rgba(255,255,255,0.06)` | edge light on every glass surface |
| `--acc` | `#8FC4FF` | primary accent (prompts, live state, links, primary button) |
| `--acc-2` | `#52E6D6` | pending / "starting" only |
| `--err` | `#FF6B54` | genuine errors only (missing permission, dead server) |
| `--fg` / `--fg-hi` | `#EAF2FF` / `#FFFFFF` | body / headings |
| `--muted` / `--faint` | `#C2D2E6` / `#93A6BF` | captions / small labels |
| `--line` / `--line-hi` | `rgba(255,255,255,0.12)` / `0.22` | hairlines / borders |
| `--glow` | `rgba(143,196,255,0.5)` | one tight halo on the mark, nowhere else |

- **Type**: system sans (SF) for UI and prose; **JetBrains Mono** (bundled, ~56 KB
  woff2, ligatures off) only where literal characters matter — wordmark, commands
  table, keycaps, hotkey readout. Base 13.5 px, line-height ~1.6. Uppercase labels
  get `letter-spacing: 0.05–0.13em`.
- **Geometry**: `10px` radius (cards/panels/mark), `7px` (buttons/fields/keycaps/tabs),
  `999px` (pills/toggle/tags). Soft, not round.
- **Motion**: one orchestrated moment per surface — the blinking block cursor in the
  wordmark, the mark's pulse while recording, the waveform. Respect
  `prefers-reduced-motion`.
- **Anti-references** (do not): animated grid / "tron" lines, glow on every element,
  gradient-mesh backgrounds, pure `#00BFFF` cyan, a dark-blue tint on every panel,
  `16px+` radius everywhere, a second bright hue.

---

## 3. Non-functional requirements

- **Latency**: end-of-speech → text-ready **< 1 s** (ADR-0001). The cost of placing
  text is *inside* the budget.
- **Cleanup cost**: rules engine **< 1 ms**; deterministic and stateless.
- **Privacy / local-first**: no network except model download (which honours mirror
  env vars); no telemetry; no account. (About text asserts "No telemetry".)
- **Offline**: app and overlay bundle JetBrains Mono locally so an offline first run
  still renders.
- **Memory**: two model servers resident for the app's life; the dictation path holds
  no multi-gigabyte model (ADR-0001).
- **Robustness**: a dictation outcome must never crash the app — transcription,
  context, break-placement, and delivery failures each degrade to a `held` or `failed`
  result, never an uncaught throw.

---

## 4. Explicitly out of scope (current behaviour, not gaps to "fix")

- Semantic voice-edit commands ("make this shorter", "fix grammar") — deliberately
  absent (ADR-0001, `#222`).
- Letter-name disambiguation ("Jay Oh Aitch Enn") and confirmation-code casing in
  spell-out; phone/date numeric entities in currency; bold/italic markdown emphasis.
- List rendering in break placement (parsed, diagnostics emitted, but gated off by
  default until a model prompt exists that handles it).
- A light theme; a rename; a separate native Liquid Glass (`NSGlassEffectView`,
  macOS 26) — that is the very follow-up a native rewrite unlocks.

---

## 5. Extension — Chinese input/output support (普通话 & 广东话 → 简体中文)

> **Status.** Extension spec, 2026-09-08. Layers a **zh profile** on top of the §0–§4
> translation baseline. **Not in force until the ADR-0002 revisit lands (§5.13).**
> Wherever a rule below contradicts §0–§4, the contradiction is stated; the baseline
> section still describes the shipped English behaviour and is not amended.

### 5.1 Scope, definitions & language model

- **"Chinese" in this extension** = two *spoken* varieties — Mandarin
  (**普通话 / `cmn`**) and Cantonese (**广东话 / `yue`**, as spoken in Guangdong and
  Hong Kong) — both delivered as written **Simplified Chinese (`zh-Hans`)**.
- **Written output is Simplified Chinese for both varieties.** There is **no
  Traditional-Chinese (`zh-Hant`) output profile and no script-conversion feature**:
  the app does not add a 简/繁 setting. Delivered script follows the transcription
  holder's default, normalised deterministically to `zh-Hans` where the holder emits
  Traditional or Cantonese-colloquial glyphs (see §5.2.4). "Output" covers text placed
  at the cursor and Held-result copy (§F1/F15); TTS and handwriting/OCR are out of
  scope.
- **Two dictation profiles, not three.** `en` (baseline §0–§4, default) and `zh`
  (`cmn` or `yue` as the active spoken variety). The profile decides: which
  transcription-role holder runs, which cleanup profile applies, and which spoken
  phrases the Commands page advertises. The **command grammars (en + zh) are both
  active regardless of profile** — an utterance may mix languages (English code
  identifiers inside Chinese speech, English commands while dictating zh, and vice
  versa) and must not fail because of the profile.
- **Command matching is textual.** Spoken commands are matched against *transcribed
  characters*, not audio. A phrase written the same way — `句号`, `新段落`,
  `蛇形命名` — therefore works whether pronounced in Mandarin or Cantonese, provided
  the holder transcribes it to those characters (holder accuracy is an eval bar, not a
  grammar concern). Cantonese-colloquial command phrasings (`唔該`-style tokens) are
  out of scope until a corpus shows the need (§5.12).
- **Selection of spoken variety.** Settings carry an explicit
  `dictationLanguage: en | cmn | yue` (default `en`, preserving shipped behaviour);
  per-utterance auto-detection between `cmn` and `yue` is deferred (§5.10). The
  coordinator sends the active code in every `transcribe` request's `lang` field (the
  helper protocol already carries it; the Electron side currently never sets it and
  must start to).
- **Glossary gap.** "profile", "spoken variety" and "written output language" as used
  here are not yet in `CONTEXT.md`; add them when this extension is adopted (§5.13).

### 5.2 Transcription model server — the zh role (deltas to F8/F9/F12)

- **The current role holder does not cover Chinese.** Parakeet TDT 0.6b v3 via
  FluidAudio (ADR-0003) is multilingual across ~25 European languages, with no
  Mandarin or Cantonese support. Filling the transcription role for zh therefore needs
  a different holder — the role keeps its name (`CONTEXT.md`: roles are named by role,
  never by the model).
- **Holder requirements (zh).** Same contract as the current holder: local-first,
  nothing leaves the machine; supervised subprocess speaking the NDJSON-stdio protocol
  (`{"event":"ready"}` on load, id-tagged `transcribe` carrying base64 WAV); input is
  mono 16 kHz / 16-bit PCM WAV (F7 unchanged); output is UTF-8 text; warm
  end-of-speech → text-ready inside the **sub-1s budget**, measured per variety on the
  target hardware (ADR-0001); weights verified on download and fetched through the
  model-store machinery honouring `REGISTRY_URL` / `HF_ENDPOINT` mirrors (F12).
- **Candidate classes (non-binding, before the §5.13 spike):** whisper.cpp
  `large-v3`-class multilingual models (proven Apple Silicon build path already exists
  in this repo; covers both `cmn` and `yue`), and — for the native rewrite —
  Apple's on-device `SFSpeechRecognizer` (`zh-CN` / `zh-HK`), which is Swift-native but
  must be proven against offline, latency, and permission constraints. One holder may
  serve both varieties (variety passed per request); two separate holders are allowed
  only if a single one fails the eval bar, at the RAM cost below.
- **Deterministic `zh-Hans` normalisation.** If the chosen holder emits Traditional or
  Cantonese-colloquial glyphs for `yue`/`cmn` input, a static, deterministic
  hanzi-mapping pass (a lookup table in the rules engine — never a model) converts the
  transcript to `zh-Hans` standard written Chinese before cleanup. No free-form
  "translation" is ever performed.
- **Supervisor & memory.** Never two speech models resident (ADR-0001 consequence,
  F9). Profile switch `en ⇄ zh` restarts the transcription holder under the existing
  supervisor lifecycle; the model-server health state already reports "starting"
  during the load, and the cold-switch cost (seconds) is documented, not hidden.
- **Vocabulary biasing.** The codebase-vocabulary scan (F11) must feed whatever
  boosting/keyword mechanism the zh holder exposes (the FluidAudio keyword-spotter
  route generalised from #322); a holder without one ignores the prompt, matching
  today's Parakeet behaviour.

### 5.3 Rules cleanup — zh profile (delta to F2)

Rules stay deterministic, stateless, **< 1 ms** (ADR-0001). The zh profile runs the
following passes **in place of** the English capitalisation / spell-out / en-currency
passes; the spoken-punctuation and repeat machinery is profile-switched, not duplicated
into a second engine.

**1. zh orthography normalisation (new first pass).** Never insert spaces between CJK
glyphs; never insert a space around CJK punctuation (`。，、；：？！「」《》（）`); collapse
runs of ASCII whitespace; eat a stray ASCII space the holder left inside hanzi runs;
map holder line-wraps to nothing (zh needs no soft-wrap collapse). Mixed runs
(CJK + Latin/digits) are left exactly as transcribed — no auto-spacing either way.

**2. Spoken punctuation → full-width marks** (same trigger model as F2; never gated,
except breaks which are gated as in F2):

| Spoken (zh, either pronunciation) | Result |
|---|---|
| 句号 | `。` |
| 逗号 | `，` |
| 问号 | `？` |
| 感叹号 · 叹号 | `！` |
| 冒号 | `：` |
| 分号 | `；` |
| 顿号 | `、` |
| 省略号 · 点点点 | `……` |
| 破折号 | `——` |
| 左括号 · 右括号 | `（` · `）` |
| 百分号 | `%` |
| 斜杠 | `/` |
| 引号 … 结束引号 (non-greedy) | `“…”` |
| 单引号 … 结束单引号 (non-greedy) | `‘…’` |

**3. Spoken breaks & list markers** (break-safe app AND not a one-line field only;
else the phrase is **dropped** — no space, since zh inserts no word spacing — matching
F2's deny-by-default):

| Spoken | Result |
|---|---|
| 新段落 · 另起一段 | `\n\n` |
| 新行 · 换行 · 换一行 | `\n` |
| 新圆点 · 圆点 · 项目符号 | `\n- ` |
| 缩进 | `\t` (clause-start only) |

As with the Parakeet-era English fix (#320), the zh break/list patterns must eat one
trailing `。！？，；：` and surrounding whitespace that prosody-driven holder
punctuation may leave behind.

**4. Numbers, currency, percent.** A zh number-word parser (Mandarin tokens
`零一二三四五六七八九十百千万亿`) converts cardinal number words to **Arabic digits**
(`一千零二十三` → `1023`). Currency words `元/块/毛/角/分` build `¥`-prefixed amounts
(`五十元` → `¥50`, `三块二` → `¥3.2`, `一块五毛` → `¥1.5`). `百分之五十` → `50%`.
Cantonese-colloquial currency tokens (`蚊`, `蚊雞`) get an initial static mapping list
(`三蚊` → `¥3`), corpus-tuned like every spoken list. Unrecognised phrases stay as-is
(fail-safe, as in F2).

**5. Self-correction.** `划掉` / `删掉` delete the clause immediately before the
trigger, with the F2 guard exactly: only when followed by a pause (punctuation/end),
only one clause back, and never when a noun follows (`删掉那个文件` is untouched).

**6. Fillers.** Initial list, corpus-tuned (zh holder output style determines what
actually appears): standalone `嗯 呃 啊 哎 哦 唔 诶 嗯嗯`; phrase `就是说 怎么说呢
你知道 你懂的`; leading-only (sentence start, never to empty) `那么 然后 其实 对了
好吧 怎么说呢`. A holder that already standardises Cantonese colloquialisms removes
the `嘅/㗎`-class tokens upstream; any that reach cleanup are added to the leading
list. *(Probe 2026-09-23: the A0 candidate — SenseVoiceSmall — does **not** standardise;
every colloquial token passed through verbatim. See
[`zh-extension-impact.md` §5.8](zh-extension-impact.md).)*

**7. Repeats.** Collapse immediate adjacent repeats of one character/word — **except
lexical reduplication, which is grammatical in Chinese and must survive**: AA
verbs/adjectives (`看看 试试 说说 谢谢 常常`), kinship (`爸爸 妈妈 哥哥`), AABB idioms
(`高高兴兴`). The exception list is corpus-driven and lives with the rules, not in a
prompt.

**8. No capitalisation, no forced terminal punctuation.** The zh profile **drops** the
en profile's `i → I` capitalisation and sentence-start caps entirely, and must **not**
append a terminal mark (en appends `.` when missing). Only a spoken `句号` produces
`。`: an auto-appended mark can change meaning and is wrong in code contexts.

**9. Emoji** (never gated): `笑脸` 🙂 · `爱心` ❤️ · `点赞 · 太棒了` 👍 · `火焰` 🔥 ·
`大笑` 😂 · `哭` 😢 — same trigger model as F2.

**10. One-line fields** (`AXTextField` single-line): identical to F2 — no inserted
breaks; and since zh never forces terminal punctuation, there is nothing further to
suppress.

### 5.4 Break placement (delta to F3)

- Eligibility unchanged: break-safe app AND not a one-line field AND no explicit
  spoken break AND cleaned text has ≥ 3 sentences. Sentence counts use **zh hard
  boundaries** `。！？…` (and `；` as a soft boundary) instead of the en sentence
  splitter.
- The rewrite-model contract is unchanged and stays **sentence indices, never text**
  (`BREAKS: 3, 7` / `LIST:`), with the same fail-closed repair (F3).
- **Model-quality gate.** The current rewrite-role holder (SmolLM2-1.7B) is
  English-centric and unverified for Chinese. zh break placement is eligible only once
  the holder passes a zh eval set; until then zh dictation degrades to prose with no
  auto-breaks — deny-by-default, consistent with F3's repair philosophy. A
  zh-verified holder is an open question (§5.12), not an assumption.

### 5.5 Voice edit (delta to F4)

The fixed grammar gains **Chinese aliases**; transforms are unchanged where the target
is an ASCII identifier. Aliases work pronounced in either variety, per §5.1.

| Command | zh aliases (finite set) | Result |
|---|---|---|
| snake case | 蛇形命名 · 下划线命名 · 蛇形 | `get_user_name` |
| camel case | 小驼峰命名 · 驼峰命名 · 驼峰 | `getUserName` |
| pascal case | 大驼峰命名 · 帕斯卡命名 | `GetUserName` |
| kebab case | 短横线命名 · 烤串命名 · 连字符命名 | `get-user-name` |
| constant case | 常量命名 · 大写蛇形命名 | `GET_USER_NAME` |
| title case | 标题命名 | `Get User Name` |
| upper / lower | 全大写 · 全部大写 / 全小写 · 全部小写 | `GET USER NAME` / `get user name` |
| wrap (existing ASCII set) | 加引号 · 用引号包起来 · 加反引号 · 加括号 · 加方括号 · 加大括号 | `""` · backtick pair · `()` · `[]` · `{}` (see F4) |
| wrap — zh prose set | 加中文引号 → `“”` · 加中文单引号 → `‘’` · 加书名号 → `《》` | full-width pairs |
| bullet list | 项目符号列表 · 圆点列表 · 无序列表 | `- ` lines |
| numbered list | 编号列表 · 数字列表 · 有序列表 | `1. ` lines |
| copy that | 复制 · 复制这段 · 复制这个 | selection → clipboard, doc untouched |
| paste | 粘贴 · 粘贴剪贴板 · 粘贴出来 | clipboard → cursor (F5 rules) |

- **Identifier-case guard vs CJK.** A case/naming transform on a selection that
  contains CJK characters is **declined** with a reason (case is meaningless for
  hanzi). Wrap / copy / paste / list commands remain valid on CJK selections.
- Carrier phrases in zh (`请…` `把…` `把它/将…变成…` `转换成…` `改成…` `换成…`) are
  stripped like the en carriers (F4); the aliases table above is the finite set —
  anything else leaves the selection untouched.
- List markers on CJK items use the ASCII `- ` / `1. ` markers in v1; the traditional
  `1、` numbering convention is an open question (§5.12), not a promise.

### 5.6 Paste (delta to F5)

Whole-utterance zh triggers: `粘贴` · `粘贴剪贴板` · `粘贴出来`. `粘贴报告` types
literally (parity with F5). Clipboard payload is text-agnostic — CJK needs no special
path — and the 10,000-char refusal, empty-clipboard message, and break-safe gate for
multi-line content are unchanged.

### 5.7 Context, capture, lifecycle (F6/F7/F9) — no change, one IME note

Context detection, break-safety resolution, and mic capture are language-agnostic and
unchanged. **IME note:** push-to-talk must work while a Chinese input source
(拼音/五笔/粤拼) is active — the hotkey tap is read by Input Monitoring before the IME
consumes it, and the recording-only Escape handler must not fight an IME composition
cancel. Verify on real `zh-CN`/`zh-HK` input sources (§5.9); if a conflict shows up,
it is a new issue with its own fix, not a change to F1.

### 5.8 Settings, model download, overlay, UI (deltas to F10/F12/F15/U4/U5)

- **F10 settings**: add `dictationLanguage: en | cmn | yue` (default `en`; F10's
  schema otherwise unchanged). No script/traditional option is added (per §5.1).
- **F12 downloads**: the zh transcription holder's weights download on first use of a
  zh variety through the same model-store machinery; a source install may stage them
  in `postinstall`. Sizes are unmeasured (large-v3-class weights are multi-GB —
  validate against the `docs/planning/app-size.md` guardrail). Setup-screen per-role
  progress parity with #249 applies to the zh role too.
- **F15 overlay & renderer fonts**: JetBrains Mono has no CJK glyphs. Held-result text
  and any mono surfaces must fall back to a system CJK font (PingFang SC) so Chinese
  renders; overlay width/height layout is re-checked with CJK content.
- **U4 Commands page**: rows are grouped bilingual (English / 中文); filtering matches
  either language. The source-of-truth trio (`rules.js` spoken triggers,
  `voiceEditCommands.js`, `src/commandReference.ts`) gains the zh entries above and the
  page must stay in step (existing U4 discipline).
- **U5 Settings**: the language/variety control (§5.1) joins the existing three
  sections.
- **UI copy stays English.** Localising the renderer to Chinese or to the system
  language is **out of scope** for this extension; only the Commands *content* is
  bilingual.

### 5.9 Testing & acceptance

- **Eval corpora**: a Mandarin (`cmn`) corpus and a Cantonese (`yue`) corpus, built
  like #171 but captured against the zh holder's protocol (the old #171 recipe curls
  whisper-server and is already stale). Acceptance bar per variety: warm latency
  inside the sub-1s budget and a WER/cleanup-quality threshold set before the spike,
  on the target hardware class.
- **Rules parity**: the zh profile gets the same unit-suite treatment as en —
  punctuation, breaks+gating, numbers/currency, fillers, reduplication exceptions,
  self-correction guards, `zh-Hans` normalisation, mixed en/zh utterances.
- **Manual matrix** (mirrors #228's shape): zh voice-edit incl. CJK-decline reasons;
  dictation from IDE terminals into editor/terminal targets with Chinese; IME-active
  dictation; overlay CJK rendering; break-safe both directions with spoken zh breaks.
- CI policy is unchanged (build only).

### 5.10 Explicitly out of scope for this extension

- `zh-Hant` (Traditional) written output and any script conversion setting; per-region
  script auto-selection. (Deterministic normalisation of a holder's output to
  `zh-Hans` is in scope, §5.2.4.)
- Cantonese-colloquial written output (粤语白话文): `yue` speakers receive standard
  written Simplified Chinese.
- Per-utterance auto-detection between `cmn` and `yue` (deferred beyond the explicit
  setting); dialects other than `cmn`/`yue` (闽、吴、客家、…).
- Semantic Chinese voice edits ("写短一点", "改一下语法") — same ADR-0001/#222
  reasoning as English.
- UI localisation / system-language UI; TTS output; handwriting/OCR input.

### 5.11 Delta map (quick reference)

| Baseline | zh change |
|---|---|
| F1 loop | unchanged; coordinator now sends `lang` on every request (§5.1) |
| F2 rules | new zh profile with the §5.3 passes; en profile untouched |
| F3 breaks | zh segmentation + model-quality gate (fail-closed to prose) |
| F4 voice edit | zh alias grammar + CJK-decline guard + zh prose wraps |
| F5 paste | zh whole-utterance triggers |
| F6/F7 context & capture | unchanged (IME verification only) |
| F8 transcription | zh role holder (§5.2), output normalised to `zh-Hans` |
| F9 supervisor | profile switch restarts the transcription holder; never two speech models resident |
| F10 settings | `dictationLanguage: en \| cmn \| yue` |
| F12 downloads | zh weights via model store on first zh use; size spike required |
| F15 overlay | CJK font fallback; Held result copy unchanged |
| U4/U5 | bilingual Commands rows; Settings language control; UI copy stays English |
| NFR | sub-1s and <1 ms budgets hold per profile; memory ceiling unchanged |

### 5.12 Open questions

1. **Transcription holder for zh** — which model/runtime serves `cmn`+`yue` at the
   budget? Benchmark candidates on M-series (mirror the #178/#203 method) before any
   ADR. Single multilingual holder vs two; the `zh-Hans` normalisation table's source.
2. **Rewrite-role holder for zh break placement** — zh-tuned small model, or accept
   prose-with-no-breaks until one exists?
3. **Cantonese token lists** — currency (`蚊…`), fillers, and any colloquialism the
   holder lets through; initial lists above are corpus-seeded, not final.
4. **Numbered-list marker** for zh prose — ASCII `1. ` (v1 default) vs `1、`.
5. **IME interplay** — any real conflict between push-to-talk/Escape and Chinese input
   sources (verification may surface a new issue).
6. **Weight sizes** — zh holder download size vs the app-size guardrail
   (`docs/planning/app-size.md`).

### 5.13 Required follow-ups before this extension is in force

1. **A new ADR revisiting ADR-0002** ("English-only stands … unless revisited on its
   own"): record that zh (`cmn` + `yue` → `zh-Hans`) is now in scope, note the
   grammar/holder consequences, and supersede or amend ADR-0002 accordingly. Also note
   the consequence for ADR-0003 (the transcription role may hold a non-FluidAudio
   model for zh).
2. **`CONTEXT.md`**: add "profile", "spoken variety", "written output language"
   (glossary discipline per `docs/agents/domain.md`).
3. **`docs/planning/native-swift-rewrite.md`**: its §2(a) assumption "reuse FluidAudio
   for ASR" does not cover Chinese — revise the feasibility table and add the zh rules
   (~est. +300–400 lines) and the zh transcription-role question to the port surface
   and effort estimate.
4. **`ROADMAP.md`**: scope the multi-language line (#252) to this extension
   (`cmn`/`yue` → `zh-Hans`) or mark it superseded by this section.
5. **Spike + corpora**: holder benchmark for `cmn`/`yue` (§5.12.1) and the two eval
   corpora (§5.9) — the implementation gate for everything else in §5.
