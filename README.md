# Solas

Solas (Irish for "light") is a macOS menu-bar explainer card. Summon it with one keystroke, type a concept, get a concise explanation, dismiss — without leaving flow.

## How it works

Solas shells out to your existing [`opencode`](https://github.com/sst/opencode) binary (`opencode run`, headless), so it inherits your auth, providers, and models. No second API key.

## Features

- **Global hotkey** `⇧⌃Space` summons the card from anywhere (`⌘Space` is never touched).
- **Concept explainer**: bold essence line, 2–4 bullets with key terms, optional analogy — under ~120 words.
- **Model picker**: pre-selects a free model on first launch; never blocks asking; "follow opencode default" escape hatch.
- **Sticky answers**: hiding or switching apps never clears a finished answer; plain text is auto-copied to the clipboard.
- **Hotkey diagnostics**: the shortcut help card shows build, last-received time, capture trust, and tap status, with one-click diagnostics copy.

## Getting Started

Requirements: macOS 14+, Xcode command-line tools (Swift 6), `opencode` installed and authenticated (`opencode auth login`).

```sh
git clone <this-repo>
cd Solas
sh scripts/package.sh
cp -R Solas.app /Applications/
open /Applications/Solas.app
```

`scripts/package.sh` builds release, stamps the build ID, and signs with your Apple Development identity when available (keeps the Accessibility grant stable across rebuilds).

Grant **Accessibility** (and **Input Monitoring**, if prompted) when enabling Keyboard Capture — summoning inside editors/terminals that swallow keys depends on it.

## Usage

1. Press `⇧⌃Space` (Shift + Control + Space) from any app.
2. Type a concept (e.g. `gravity`), press `⏎`.
3. Read the answer (plain text is already in your clipboard). `Esc` clears/closes.

Logs live at `~/Library/Logs/Solas.log`. If the hotkey ever stops working, open the shortcut help card → Copy diagnostics.

## Tech Stack

Swift 6, SwiftUI + AppKit (`NSPanel` launcher card), Carbon `RegisterEventHotKey`, `NSEvent` monitors, `CGEvent` session tap. Zero dependencies.

## Known Limitations

- macOS only.
- Requires a working `opencode` setup with at least one model.
- In-editor summoning needs Accessibility/Input Monitoring grants.
- While Secure Input is active (password field, `sudo` prompt), no global hotkey on the system can fire.
