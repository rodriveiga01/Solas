# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos-native — a menu-bar accessory app (Swift SPM, SwiftUI + AppKit). Note: this value deviates from the skill template's web/ios/android/adaptive set because the product is a genuine native macOS utility, not a mobile or web surface.

## Users

Everyone on Mac (confirmed 2026-09-14) — from developers who already run opencode to non-technical users. Situation: mid-task in any app, a question pops up. Job: summon with one keystroke, get one concise answer, dismiss, stay in flow.

## Product Purpose

A single-command floating explainer card. Type a concept ("gravity"), read a vivid compact explanation, close it. Success means: explained in one glance — and in the clipboard as plain text — within seconds, with zero setup beyond an already-working opencode.

## Positioning

The only Mac explainer bar that reuses the user's existing opencode auth, providers, and models — including free Zen/contributor models — instead of demanding a second API key or AI subscription.

## Operating Context

Menu-bar accessory (no Dock icon; shipped as Solas.app via `scripts/package.sh` with LSUIElement for a stable identity). Summon with ⇧⌃Space (works everywhere with zero setup) or ⌃⌥Space; optional Accessibility full-capture from the help card. Centered Spotlight-style card (fixed 540pt wide, top-anchored in the upper third, height follows content 150–720pt). Explanations come from headless `opencode run`, inheriting the user's configured providers and models.

## Capabilities and Constraints

- Concept explainer (confirmed 2026-09-14, pivot from generic Q&A): input is a concept or a question; output is a Markdown explanation under ~120 words — bold essence line, 2–4 bullets with bolded key terms, optional italic analogy. No chat history.
- Creative control belongs to the model within bounds: full inline Markdown (bold/italic/code/links) plus up to 3 tinted terms via `^[term](accent: 'name')`, names constrained to ember/gold/leaf/sky/iris/rose. Rendered natively (AttributedString + block walk, MarkdownBlocks.swift / MarkdownAnswer.swift). Clipboard receives markup-stripped plain text.
- Compact flow (reworked 2026-09-14 after hide-then-pop read as blank): the card stays visible for the whole ask — type → inline spinner with Cancel → answer or error lands inline with a spring. If the run finishes while the card is hidden, the card reveals itself without resetting so the result is seen, never orphaned-then-wiped. Menu icon switches to a filled sparkle while thinking. Esc mid-think cancels and keeps the card open with your question intact.
- Images only when genuinely clarifying, max 2, Wikimedia Commons only (upload/thumb.wikimedia.org allowlist; everything else degrades to a link row, load failures to the caption). Model is briefed to use only Commons URLs it is confident exist, else omit.
- Sticky answers: hiding, switching apps, and reopening never clear anything — the answer is still there when you come back. Esc on a finished answer clears it to blank; Esc on idle closes. No states to understand beyond asking and answered.
- Hotkey: one — ⇧⌃Space. It produces no text, macOS claims nothing like it, and ⌘Space is never touched (Spotlight's key stays Spotlight's). Three tiers race (250ms dedup): Carbon (permission-free), an Accessibility NSEvent monitor, and a pre-dispatch session event tap that fires even inside self-drawn editors/terminals which swallow keys before Carbon ever sees them; every firing is logged (~/Library/Logs/Solas.log, 256KB cap) and the last firing is persisted, so the help card's "last received" line is proof across restarts. If another copy or app holds it, the card says so up front with a fix path.
- Model: first launch shows a model picker once (pre-selected free, never blocks asking — type and press ⏎ immediately); afterwards it collapses to a slim banner on idle until you pick. Default is `opencode/muse-spark-1.3-contributor-free` when the user is Zen-only / has no paid subscription (confirmed 2026-09-14, custom answer). Picker lists detected free/Spark/Zen models plus an "opencode default" escape hatch.
- (Stack section omitted per template: existing Swift SPM codebase already answers it.)

## Brand Commitments

Name "Solas". Pinned by user: Apple-HIG-native, Spotlight-class material, typography, and motion. Keyboard-first: Enter explains, Esc closes.

## Evidence on Hand

Repo root is the project: `Package.swift`, `Sources/Solas/` (`SolasApp.swift`, `ContentView.swift`, `OpencodeRunner.swift`, `ModelStore.swift`, `MarkdownBlocks.swift`, `MarkdownAnswer.swift`). Verified 2026-09-14: `opencode run` headless works; `opencode/muse-spark-1.3-contributor-free` exists in `opencode models`; explainer brief verified live ("gravity" → bold essence + 3 bullets + italic analogy, sky/gold accents, 60 words); sanitize + block-split + accent-decode + plain-text pipeline verified against that output; app launches, both hotkeys register. Research 2026-09-14: Carbon RegisterEventHotKey fully functional on macOS 26, no permission needed (Electron/Chromium approach); bare ⌥Space is consumed as nbsp by text fields before Carbon dispatch — hence the ⌃⌥Space companion; AttributedString `.full` Markdown + `MarkdownDecodableAttributedStringKey` custom attrs power the renderer with zero dependencies. No testimonials, pricing, or benchmarks on hand — future work must not fabricate any.

## Product Principles

1. One keystroke to an explanation, one to close.
2. Zero new credentials — opencode is the account.
3. Answers stick around; hiding never loses them.
4. The model styles the card — Markdown plus a fixed accent palette, restraint reads as craft.
5. Native or nothing — system materials, SF, real keyboard focus.

## Accessibility & Inclusion

Full keyboard operation (input focused on show, Esc closes, visible focus ring). Body and secondary text meet ≥4.5:1 contrast. No product-specific standard established beyond this.
