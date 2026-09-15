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

/// A short arc window sliding around the pill edge. Built from trims so
/// the speed is arc-length uniform — constant flow on straights and
/// curves alike. Wraps seamlessly: at the loop point the window splits
/// into head + tail across the seam.
struct CometRing: Shape {
    /// 0→1 position of the window head along the perimeter.
    var progress: Double
    /// Window length as a fraction of the perimeter.
    var length: Double = 0.28

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ring = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let end = progress + length
        if end <= 1 {
            return ring.trim(from: progress, to: end).path(in: rect)
        }
        // Straddles the seam: head runs to 1, tail continues from 0.
        var p = ring.trim(from: progress, to: 1).path(in: rect)
        p.addPath(ring.trim(from: 0, to: end - 1).path(in: rect))
        return p
    }
}

/// The parked pill: always the prompt text (`black holes`). While thinking,
/// a short arc slides around the edge at constant speed (modern loader,
/// no spinner); when done the edge settles green, or orange + warning on
/// error. Width hugs the word (120–320pt); no × — dismiss via
/// peek → Esc/× on the card, cancel from the expanded card.
/// Fixed 48pt height, same material + stroke language as the card.
/// Click = peek/expand.
struct ParkedPillView: View {
    let question: String
    let isReady: Bool
    let hasError: Bool
    let onPeek: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slide = 0.0
    @State private var arrived = false

    private var status: PillStatus { ParkedPill.status(isReady: isReady, hasError: hasError) }

    /// The edge is the signal: sliding comet while thinking, settled
    /// green when done, settled orange + warning icon on error (errors
    /// keep the redundant cue). No badges otherwise.
    private var edge: Color {
        switch status {
        case .thinking: return .white.opacity(0.16)
        case .ready: return .green.opacity(0.6)
        case .failed: return .orange.opacity(0.45)
        }
    }

    private var edgeWidth: CGFloat {
        switch status {
        case .thinking: return 1
        case .ready, .failed: return 2
        }
    }

    /// Flow layer: a short arc sliding at constant path speed while
    /// thinking (trim is arc-length uniform — no curve speed-up).
    /// Static arc under Reduce Motion.
    @ViewBuilder
    private var flowOverlay: some View {
        if status == .thinking {
            // Inset 1pt keeps the 2pt stroke's overhang off the clip
            // bound — no more cut corners.
            CometRing(progress: reduceMotion ? 0.15 : slide)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
        }
    }

    var body: some View {
        Button(action: onPeek) {
            HStack(spacing: 8) {
                // Errors keep their icon; ready needs none — the settled
                // green edge says it. VoiceOver labels cover every state.
                if status == .failed {
                    Image(systemName: ParkedPill.iconName(for: status))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
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
                    .stroke(edge, lineWidth: edgeWidth)
                    .padding(1)
            )
            .overlay(flowOverlay)
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
            // One soft bounce on ready arrival. Static under Reduce Motion.
            .scaleEffect(arrived && !reduceMotion ? 1 : (isReady && !reduceMotion ? 0.96 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Activates the Solas card")
        .accessibilityAddTraits(.isButton)
        .onAppear {
            // Fresh pill each park (branch swap = new identity): start the
            // slide. Removed with the overlay when the run finishes.
            if status == .thinking, !reduceMotion {
                slide = 0
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    slide = 1
                }
            }
            if isReady, !reduceMotion {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
                    arrived = true
                }
            }
        }
        .onDisappear { slide = 0 }
        .onChange(of: isReady) { _, ready in
            if ready, !reduceMotion {
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
