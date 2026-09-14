# Design

<!-- impeccable:design-schema 1 -->

## World

Spotlight-native explainer card. The surface IS macOS: `.regularMaterial` card on a transparent borderless key-capable `CardPanel` (the launcher recipe — no titlebar, so no traffic-light overlap and measured height equals visible height), system SF text at Spotlight scale (19 input / 14 answer / 11–12 chrome), SF Symbols only, one breathing shimmer (static when Reduce Motion) as the signature motion. No brand color, no display face — the product's voice is the system's voice, and the *model* supplies the color: up to 3 tinted terms per answer from a fixed palette (ember/gold/leaf/sky/iris/rose), first accent theming the list markers and quote bar.

## First viewport

Centered Spotlight-style card (540pt wide, fixed, top edge parked in the upper third, 20pt continuous corners, 1pt stroke — white 14% or the answer's accent at 40%, 0/24/60 black-35% shadow). Height follows measured content, clamped 150–720pt, growing downward so the input never moves and long answers fit. Single input row (magnifier → "Explain anything" field → clear × / return key cap, Cancel while thinking). Below one divider, exactly one state shows: model picker (first launch only, pre-selected free, never blocks asking; later a slim banner on idle) / crafted answer with images (scroll ≤440pt, plain text auto-copied) / error with Retry + Copy / hotkey help led by ⇧⌃Space (from menu/menu status) / three concept examples (idle). While thinking the card stays visible with an inline spinner and Cancel — no hide/show; a run finishing while hidden reveals the card without reset. Footer: model capsule left; right shows `return = explain · escape = clear/close` hints, transient `checkmark = Copied` confirmation, or an amber hotkey note (tap for help) when degraded.

## Answer typography system

Line-split blocks, each with one voice: paragraph 14/4 leading; bullets and numbered items with theme-colored markers and 14pt depth indent; quotes italic secondary with a 3pt theme bar; code blocks mono 12.5 on quaternary-55 rounded-10; headings (rare by brief) 17/15/14 semibold in primary; images max 2, 190pt rounded-12 with caption, shimmer placeholder, caption-only failure, link-row for non-allowlisted hosts. Inline bold/italic/code/links come straight from Foundation's Markdown parse; unknown accent names render uncolored — never an error.

## Signature interaction

Summon → type → inline spinner → answer lands inline with a spring, plain text already in the clipboard. Appear is a 0.16s fade; the card never hides mid-ask and app switches never dismiss it, so answers survive hide, switch, and reopen. Hiding (×, toggle, Esc on idle) never clears; Esc on a finished answer clears it to blank, Esc mid-think cancels and keeps the card open.

## Rules carried forward

- Panel is borderless and key-capable (`CardPanel.canBecomeKey`, never `.nonactivatingPanel`) and sticky (`hidesOnDeactivate = false`, hiding never clears) — or the field swallows keystrokes / chrome clips content / answers don't survive app switches.
- Status item: left-click toggles instantly; menu exists only for the right-click moment (cleared in `menuDidClose`), every item with an explicit target.
- Hotkey: exactly one — ⇧⌃Space, everywhere (menu, footer, help, empty state). ⌘Space is never registered. Three tiers race with a 250ms dedup: Carbon (the only permission-free global API — same one the industry-standard KeyboardShortcuts package uses), an Accessibility NSEvent monitor, and a pre-dispatch session event tap (fires even when self-drawn editors/terminals consume the key before Carbon; swallows only the hotkey). Handler installed first and retained; every firing logs with its source and persists its timestamp; missing combos retry at 2/6/12s, on every summon, on activation, and every 60s while unowned — an orphaned registration heals itself without relaunch. A held hotkey surfaces a blocking-state row on idle, not a footnote. Ship and run as Solas.app (`scripts/package.sh`, LSUIElement, Developer-ID signed) for a stable hotkey/TCC identity.
- Model default: `opencode/muse-spark-1.3-contributor-free` when present; `nil` selection = follow opencode default.
 - Runner output always passes through `OpencodeRunner.sanitize` (drops only the `> id ·` session header, never `>` quotes) before display; clipboard always gets `AnswerParser.plainText` (images become `[Image: alt]`).
 - Fences: only a bare ```` ``` ```` line closes a code block; unclosed runs to end of input (CommonMark).
 - Panel sizing reads `FitHostingView.fittingSize` after layout (never GeometryReader preferences — measured headlessly, they report 0 for scroll trees while fittingSize is exact) and converges via the <1pt guard.
- No `.accentColor` as `ShapeStyle` (removed in this SDK) — use `Color.accentColor`.
- `ForEach` row bodies must typecheck standalone: a broken row masquerades as a `Binding<C>` overload failure at the `ForEach` head.
