import AppKit
import SwiftUI

/// Parked-pill state machine (pure logic — unit-tested, no AppKit).
///
/// Flow: `idle → thinkingParked → auto-expand OR readyParked → expanded`
/// - `idle`: full card centered, nothing in flight.
/// - `thinkingParked`: pill top-right, spinner, run in flight.
/// - `readyParked`: pill top-right, answer waiting, click to view.
/// - `expanded`: pill tapped / hotkey peeked → full card again.
/// An uncleared answer keeps its home in the pill: open answer → hotkey
/// re-parks instead of hiding; only a blank/idle card hides.
enum ParkPhase: Equatable {
    case full
    case thinkingParked
    case readyParked(hasError: Bool)
}

/// Layered state signal. The pill text is always the prompt — state is
/// carried by three stacked layers so no single cue is load-bearing:
/// base icon (works for everyone), magic glow+motion (progressive
/// enhancement, off under Reduce Motion), static tint fallback.
enum PillStatus: Equatable {
    case thinking
    case ready
    case failed
}

enum ParkedPill {
    /// 42-char preview budget, shared with the full card's thinking row.
    nonisolated static func truncate(_ s: String, limit: Int = 42) -> String {
        let q = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count > limit ? String(q.prefix(limit)) + "…" : q
    }

    /// Adaptive pill width so the bubble hugs its word: icon + spacing +
    /// text + padding, clamped to [minWidth, maxWidth]. The panel and the
    /// view share this so the frame and the truncation agree.
    nonisolated static func pillWidth(
        for text: String,
        minWidth: CGFloat = 120,
        maxWidth: CGFloat = 320
    ) -> CGFloat {
        let t = truncate(text)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textW = (t as NSString).size(withAttributes: [.font: font]).width
        // 14 padding + ~16 icon + 8 spacing + text + 14 padding.
        let w = ceil(14 + 16 + 8 + textW + 14)
        return min(max(w, minWidth), maxWidth)
    }

    /// Maps parked state → pill status. Pure — unit-tested.
    nonisolated static func status(isReady: Bool, hasError: Bool) -> PillStatus {
        if !isReady { return .thinking }
        return hasError ? .failed : .ready
    }

    /// SF Symbol for the base layer. Never emoji: spinner while thinking,
    /// check when done, warning on error.
    nonisolated static func iconName(for status: PillStatus) -> String {
        switch status {
        case .thinking: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Smart-expand decision. Auto-expand only when the user is still
    /// waiting: same frontmost app as at submit, no Secure Input, <30s.
    /// When unsure, stay parked (non-evasive wins).
    ///
    /// - Returns: `(expand, reason)` — reason is logged as `smart:reason`.
    nonisolated static func shouldAutoExpand(
        frontAtSubmit: String?,
        frontAtDone: String,
        secureInputOn: Bool,
        elapsed: TimeInterval
    ) -> (expand: Bool, reason: String) {
        if secureInputOn {
            return (false, "secure-input-on")
        }
        guard let submit = frontAtSubmit, !submit.isEmpty else {
            return (false, "unknown-submit-front")
        }
        if submit != frontAtDone {
            return (false, "front-changed \(submit)->\(frontAtDone)")
        }
        if elapsed >= 30 {
            return (false, "elapsed \(String(format: "%.1f", elapsed))s>=30s")
        }
        return (true, "still-waiting front=\(frontAtDone) elapsed=\(String(format: "%.1f", elapsed))s")
    }
}

/// The parked pill: always the prompt text (`black holes`), state carried
/// by icon + a whisper of glow. Width hugs the word (120–320pt); no × —
/// dismiss via peek → Esc/× on the card, cancel from the expanded card.
/// Fixed 48pt height, same material + stroke language as the card.
/// Click = peek/expand.
struct ParkedPillView: View {
    let question: String
    let isReady: Bool
    let hasError: Bool
    let onPeek: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var arrived = false

    private var status: PillStatus { ParkedPill.status(isReady: isReady, hasError: hasError) }

    /// One color cue per state, never doubled: thinking breathes accent,
    /// done/failed rest on the neutral card stroke — the icon alone
    /// carries ready/failed color.
    private var edge: Color {
        status == .thinking ? .accentColor : .white.opacity(0.16)
    }

    private var iconColor: Color {
        switch status {
        case .thinking: return .secondary
        case .ready: return .green
        case .failed: return .orange
        }
    }

    var body: some View {
        Button(action: onPeek) {
            HStack(spacing: 8) {
                // Base layer: icon, never the sole carrier alone — text +
                // VoiceOver label always disambiguate.
                if status == .thinking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: ParkedPill.iconName(for: status))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                }
                Text(ParkedPill.truncate(question))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 120, maxWidth: 320, minHeight: 48, maxHeight: 48)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(edge.opacity(reduceMotion ? 0.35 : (status == .thinking ? (pulse ? 0.45 : 0.2) : 1)), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
            // Magic layer: breathing pulse while thinking, one soft bounce
            // on ready arrival. Static under Reduce Motion.
            .opacity(status == .thinking && !reduceMotion && pulse ? 0.85 : 1)
            .scaleEffect(arrived && !reduceMotion ? 1 : (isReady && !reduceMotion ? 0.96 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Activates the Solas card")
        .accessibilityAddTraits(.isButton)
        .onAppear {
            guard !reduceMotion else { return }
            if status == .thinking {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else if isReady {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
                    arrived = true
                }
            }
        }
    }

    private var accessibilityLabel: String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case .thinking:
            return q.isEmpty ? "Solas is thinking. Activate to peek." : "Solas is thinking about \(q). Activate to peek."
        case .ready:
            return "Solas answer ready for \(q). Activate to view."
        case .failed:
            return "Solas finished with an error for \(q). Activate to view."
        }
    }
}
