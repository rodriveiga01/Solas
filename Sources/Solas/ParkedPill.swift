import SwiftUI

/// Parked-pill state machine (pure logic — unit-tested, no AppKit).
///
/// Flow: `idle → thinkingParked → auto-expand OR readyParked → expanded`
/// - `idle`: full card centered, nothing in flight.
/// - `thinkingParked`: pill top-right, spinner, run in flight.
/// - `readyParked`: pill top-right, `✓ ready` badge, run done, awaiting click.
/// - `expanded`: pill tapped / hotkey peeked → full card again.
enum ParkPhase: Equatable {
    case full
    case thinkingParked
    case readyParked(hasError: Bool)
}

enum ParkedPill {
    /// 42-char preview budget, shared with the full card's thinking row.
    nonisolated static func truncate(_ s: String, limit: Int = 42) -> String {
        let q = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count > limit ? String(q.prefix(limit)) + "…" : q
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

/// The tiny bubble: `✨ + "gravity…" + spinner + ×` while thinking,
/// `✓ ready — click to view` (or `⚠ — click to view` on error) when done.
/// Fixed 280×48 capsule, same material + stroke language as the card,
/// lighter shadow. Click = peek/expand, × = cancel + hide.
struct ParkedPillView: View {
    let question: String
    let isReady: Bool
    let hasError: Bool
    let onPeek: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounced = false

    var body: some View {
        Button(action: onPeek) {
            HStack(spacing: 8) {
                Text(isReady ? (hasError ? "⚠" : "✓") : "✨")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !isReady {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Thinking")
                }
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isReady ? "Dismiss" : "Cancel")
                .accessibilityHint(isReady ? "Dismisses the ready notice" : "Cancels the running explanation")
            }
            .padding(.horizontal, 14)
            .frame(width: 280, height: 48)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
            .offset(x: bounced && !reduceMotion ? 0 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Activates the Solas card")
        .accessibilityAddTraits(.isButton)
        .onAppear {
            // One soft bounce when arriving in ready state — static badge
            // change only under Reduce Motion.
            guard isReady, !reduceMotion else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
                bounced = true
            }
        }
    }

    private var label: String {
        let q = ParkedPill.truncate(question)
        if isReady {
            return hasError ? "⚠ — click to view" : "✓ ready — click to view"
        }
        return q.isEmpty ? "✨ thinking…" : "✨ \(q)…"
    }

    private var accessibilityLabel: String {
        if isReady {
            return hasError ? "Solas finished with an error. Activate to view." : "Solas answer ready. Activate to view."
        }
        return "Solas is thinking about \(question). Activate to peek."
    }
}
