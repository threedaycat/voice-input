<h1 align="center">voice-input</h1>

<p align="center">
  <b>Tap a key on your Mac, speak, and the text lands at your cursor.</b><br>
  Push-to-talk dictation for people who speak Chinese mixed with English tech terms —
  built for coding, talking to Claude Code / ChatGPT, and chat.
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="macOS + Hammerspoon" src="https://img.shields.io/badge/macOS-Hammerspoon-1f425f.svg">
  <img alt="about ¥0.8 per hour of audio" src="https://img.shields.io/badge/cost-~¥0.8%20%2F%20hour%20of%20audio-D97757.svg">
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/panel.png" alt="The panel's stats tab: transcriptions per day over 14 days, colored by model, with a hover tooltip showing per-model counts and that day's cost" width="820">
</p>

## Why

Speech recognizers often mangle English terms inside Chinese speech (I kept getting
"Cloud Code" for "Claude Code"), and the commercial tools are monthly subscriptions hosted abroad. This one:

- **Transcribes with Alibaba Cloud Bailian `qwen3-asr-flash`** — about one second per
  utterance from mainland China, roughly **¥0.8 per hour of audio** at list price.
- **Proofreads with `qwen-plus` under a strict brief**: drop fillers and stutters, fix
  punctuation, normalize English spelling — **never rewrite**. If the output length drifts,
  the proofread is discarded and the raw transcript is used.
- **Vocabulary list**: tell the model the names you use; `wrong => right` rules patch what
  it still gets wrong. A `vocab.local.txt` next to `vocab.txt` is read too, for words
  that should stay on this machine when `vocab.txt` lives in shared dotfiles.
- **Fallback chain**: Alibaba Cloud → Gemini (free tier) → an on-device model (works
  offline). Rate-limited or unreachable models are skipped automatically.
- **Free quota first**: every Bailian model version carries its own new-user free quota.
  Transcription walks two dated `qwen3-asr-flash` versions and `fun-asr-flash`, proofreading two
  `qwen-plus` versions, before the pay-as-you-go main models. Turn on "stop when used up" for
  those in the console's Free Quota page: they then return 403 and the next model takes over.

## Using it

<p align="center"><img src="docs/hud.png" alt="The HUD at the bottom of the screen: recording for 1 second with a live level meter, and a chip saying two earlier clips are still transcribing" width="420"></p>

| Action | Result |
|---|---|
| **Hold right Command, speak, release** | Transcribed and pasted at the cursor (walkie-talkie mode) |
| **Tap right Command, speak, tap again** | Same, for longer passages |
| **Esc** while recording | Cancel (the audio is still kept, recoverable from the menu) |
| **⌃⌥V** | Picker over the last 40 transcripts; choose one to paste |
| Mouse **back button** to talk, **forward button** for Return | Optional, enable in the menu |

- A small HUD at the bottom of the screen shows elapsed time and a live level meter, plus how
  many earlier clips are still being transcribed — you can keep talking while they finish.
- The text **always goes to the clipboard**; it is auto-pasted only if the cursor is still
  in the same input field, otherwise you get a "press ⌘V" hint.
- Saying just "compact" outputs `/compact`, and "继续" ("continue") outputs itself without a
  trailing period — handy for Claude Code.
- Newlines are stripped before pasting, because Claude Code collapses multi-line pastes
  into `[Pasted text]`.

Menu bar mic → **Open panel** to browse history (replay, re-transcribe, copy), see daily
usage and cost, per-model call stats, and edit keys, model order, microphone and vocabulary.

## Install

Requires macOS and [Homebrew](https://brew.sh).

```bash
brew install --cask hammerspoon
brew install ffmpeg jq
git clone https://github.com/threedaycat/voice-input ~/projects/voice-input
~/projects/voice-input/install.sh
```

`install.sh` checks dependencies, copies the example vocabulary to
`~/.config/voice-input/vocab.txt`, and appends two lines to `~/.hammerspoon/init.lua`
that load this repo (your existing config is left alone). Then:

1. Open Hammerspoon and grant it **Accessibility** and **Microphone** in System Settings →
   Privacy & Security.
2. Create an API key on [Alibaba Cloud Bailian](https://bailian.console.aliyun.com/)
   (a few yuan lasts a long time), or a Gemini key.
3. Menu bar mic → Open panel → Settings: paste the key and hit Test.
4. Tap right Command, say something, tap again.

<details>
<summary>Other ways to configure</summary>

- Keys can come from environment variables `DASHSCOPE_API_KEY` / `GEMINI_API_KEY`.
  Hammerspoon doesn't inherit your terminal environment, so put them in `~/.zshenv`
  (or `~/.secrets.zsh`, which is sourced if present).
- Gemini needs a proxy from mainland China — set `https_proxy` in `~/.zshenv`.
  Alibaba Cloud requests always go direct.
- Trigger key: menu → "设置触发键…" (set trigger key); any single modifier works.
- Hide the Hammerspoon menu bar icon: run
  `hs.settings.set("voice.hideHammerspoonIcon", true)` in the console and reload.
- Settings live in `~/.config/voice-input/config.json`.

</details>

### Optional: on-device model

```bash
~/projects/voice-input/local-asr/setup.sh
```

Installs Qwen3-ASR-1.7B (4-bit MLX, Apple Silicon only, ~1.7 GB). It's only loaded when
every cloud model fails. On an M4 over 10 clips: ~1.7 s per clip, 2.5 GB peak memory,
noticeably less accurate than the cloud model — a last resort.

## Cost

Each response reports the billed audio seconds / tokens; the script multiplies by list
price and logs it to `~/.local/state/voice-input/calls.jsonl`. The panel sums those.
**It is an estimate, not your bill** — check the Alibaba Cloud billing console.

## Privacy

- Audio is sent to whichever provider you configure (Alibaba Cloud / Google); the
  on-device model keeps it local.
- History and call logs stay in `~/.local/state/voice-input/`; only the last 10
  recordings are kept (configurable).
- Keys are stored in `~/.config/voice-input/config.json` with mode 600.

## Layout

```
bin/voice-input            recording (ffmpeg), model calls, proofreading, vocab rules — also a CLI
hammerspoon/voice.lua      hotkeys, HUD, menu, pasting
hammerspoon/voice_panel.lua + panel.html   the panel
local-asr/                 optional on-device model
tools/restart-hammerspoon  restart Hammerspoon after edits (refuses while recording)
```

The UI and prompts are in Chinese; the prompts assume mostly-Chinese speech.

## License

MIT
