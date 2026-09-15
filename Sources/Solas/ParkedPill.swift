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

/// The parked pill: always the prompt text (`black holes`). While thinking,
/// a comet arc orbits the pill's edge (modern loader, no spinner); when
/// done the orbit settles to a check (green) or warning (orange) with a
/// neutral edge. Width hugs the word (120–320pt); no × — dismiss via
/// peek → Esc/× on the card, cancel from the expanded card.
/// Fixed 48pt height, same material + stroke language as the card.
/// Click = peek/expand.
struct ParkedPillView: View {
    let question: String
    let isReady: Bool
    let hasError: Bool
    let onPeek: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orbit: Angle = .zero
    @State private var arrived = false

    private var status: PillStatus { ParkedPill.status(isReady: isReady, hasError: hasError) }

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
                // Base layer: check/warning only when finished. While
                // thinking the orbiting edge is the signal (plus VoiceOver).
                if status != .thinking {
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
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            )
            // Orbit layer: comet arc circling the edge while thinking.
            // Static arc under Reduce Motion — meaning never rides on
            // motion alone (icon + VoiceOver label always disambiguate).
            .overlay {
                if status == .thinking {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(lineWidth: 2)
                        .fill(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .accentColor, location: 0),
                                    .init(color: .accentColor.opacity(0.35), location: 0.18),
                                    .init(color: .clear, location: 0.42),
                                ]),
                                center: .center
                            )
                        )
                        .rotationEffect(orbit)
                        .animation(nil, value: status)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
            // One soft bounce on ready arrival. Static under Reduce Motion.
            .scaleEffect(arrived && !reduceMotion ? 1 : (isReady && !reduceMotion ? 0.96 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Activates the Solas card")
        .accessibilityAddTraits(.isButton)
        .onAppear { startOrbitIfNeeded() }
        .onChange(of: isReady) { _, ready in
            if ready, !reduceMotion {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
                    arrived = true
                }
            }
        }
    }

    private func startOrbitIfNeeded() {
        guard status == .thinking, !reduceMotion else { return }
        orbit = .zero
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            orbit = .degrees(360)
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
