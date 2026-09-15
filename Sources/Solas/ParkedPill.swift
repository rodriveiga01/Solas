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

    /// Adaptive pill width so the bubble hugs its word: padding + optional
    /// icon + text + padding, clamped to [minWidth, maxWidth]. Only the
    /// error state shows an icon — thinking/ready pay no icon budget.
    /// The panel and the view share this so the frame and the truncation
    /// agree.
    nonisolated static func pillWidth(
        for text: String,
        showsIcon: Bool = false,
        minWidth: CGFloat = 80,
        maxWidth: CGFloat = 320
    ) -> CGFloat {
        let t = truncate(text)
        let font = NSFont.systemFont(ofSize: 14, weight: .regular)
        let textW = (t as NSString).size(withAttributes: [.font: font]).width
        // 14 padding + (16 icon + 8 spacing | 0) + text + 14 padding.
        let w = ceil(14 + (showsIcon ? 24 : 0) + textW + 14)
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

/// Spring flight for the panel frame (pure logic — unit-tested).
/// WWDC23 "Animate with springs" simplified model: response (speed) +
/// dampingRatio (1 settles clean, <1 carries a whisper of overshoot).
/// Integrated per-frame; retargets keep position+velocity, so a mid-flight
/// peek redirects instead of snapping (WWDC18 interruption rule).
struct PanelFlight {
    var rect: CGRect
    var target: CGRect
    var vel: (dx: CGFloat, dy: CGFloat, dw: CGFloat, dh: CGFloat)
    var response: Double
    var dampingRatio: Double

    nonisolated static let settlePosition: CGFloat = 0.3
    nonisolated static let settleVelocity: CGFloat = 30

    var isSettled: Bool {
        abs(target.minX - rect.minX) < Self.settlePosition &&
        abs(target.minY - rect.minY) < Self.settlePosition &&
        abs(target.width - rect.width) < Self.settlePosition &&
        abs(target.height - rect.height) < Self.settlePosition &&
        abs(vel.dx) < Self.settleVelocity &&
        abs(vel.dy) < Self.settleVelocity &&
        abs(vel.dw) < Self.settleVelocity &&
        abs(vel.dh) < Self.settleVelocity
    }

    /// Redirect mid-flight: new destination + curve, live position and
    /// velocity preserved — continuity, never a snap.
    mutating func retarget(from live: CGRect, to t: CGRect, response: Double, dampingRatio: Double) {
        rect = live
        target = t
        self.response = response
        self.dampingRatio = dampingRatio
    }

    mutating func step(dt: CGFloat) {
        let w = 2 * Double.pi / response
        let stiff = w * w
        let damp = 2 * dampingRatio * w
        // Two substeps keep explicit Euler stable at 60Hz for snappy curves.
        let h = dt / 2
        for _ in 0..<2 {
            vel.dx += (CGFloat(stiff) * (target.minX - rect.minX) - CGFloat(damp) * vel.dx) * h
            vel.dy += (CGFloat(stiff) * (target.minY - rect.minY) - CGFloat(damp) * vel.dy) * h
            vel.dw += (CGFloat(stiff) * (target.width - rect.width) - CGFloat(damp) * vel.dw) * h
            vel.dh += (CGFloat(stiff) * (target.height - rect.height) - CGFloat(damp) * vel.dh) * h
            rect.origin.x += vel.dx * h
            rect.origin.y += vel.dy * h
            rect.size.width = max(1, rect.size.width + vel.dw * h)
            rect.size.height = max(1, rect.size.height + vel.dh * h)
        }
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
    var length: Double = 0.36

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ring = RoundedRectangle(cornerRadius: 20, style: .continuous)
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
/// error. Width hugs the word (80–320pt); no × — dismiss via
/// peek → Esc/× on the card, cancel from the expanded card.
/// Fixed 40pt height, same material + stroke language as the card.
/// Click = peek/expand.
struct ParkedPillView: View {
    let question: String
    let isReady: Bool
    let hasError: Bool
    let onPeek: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slide = 0.0
    @State private var arrived = false
    @State private var draw = 0.0

    private var status: PillStatus { ParkedPill.status(isReady: isReady, hasError: hasError) }

    /// Neutral base ring — always present, the settled color draws over it.
    private var neutralEdge: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(.white.opacity(0.16), lineWidth: 1)
            .padding(1)
    }

    /// Settled state ring: green draws itself in once on arrival,
    /// orange appears instantly on error (errors get no theater).
    @ViewBuilder
    private var settledEdge: some View {
        if status == .ready {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .trim(from: 0, to: draw)
                .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
        } else if status == .failed {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.orange.opacity(0.45), lineWidth: 2)
                .padding(1)
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(ParkedPill.truncate(question))
                    .font(.system(size: 14, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 80, maxWidth: 320, minHeight: 40, maxHeight: 40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(neutralEdge)
            .overlay(settledEdge)
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
            // Fresh pill each park (branch swap = new identity).
            if status == .thinking {
                // Start the slide (static arc under Reduce Motion).
                if !reduceMotion {
                    slide = 0
                    withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                        slide = 1
                    }
                }
            } else if isReady {
                // Reparked onto an already-ready answer: rest state only,
                // no replay — the performance belongs to the arrival.
                draw = 1
                arrived = true
            }
        }
        .onDisappear { slide = 0 }
        .onChange(of: isReady) { _, ready in
            // The arrival: bounce + slow edge draw-in, once.
            // Reduce Motion: everything simply appears.
            if ready {
                if reduceMotion {
                    draw = 1
                    arrived = true
                } else {
                    draw = 0
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
                        arrived = true
                    }
                    withAnimation(.easeInOut(duration: 0.9)) {
                        draw = 1
                    }
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
