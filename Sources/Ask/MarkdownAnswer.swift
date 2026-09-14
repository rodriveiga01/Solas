import SwiftUI

/// Renders one explainer answer as a crafted card: headings, bullets,
/// quotes, and code each get their own voice; the model tints key terms
/// via `^[term](accent: 'name')`, and the first accent sets the card theme
/// (list markers, quote bar). Falls back to plain text if parsing fails.
struct MarkdownAnswer: View {
    let source: String
    @Environment(\.colorScheme) private var scheme

    private var blocks: [AnswerBlock] {
        // The brief allows at most 2 images; extras are dropped, never stacked.
        var images = 0
        return AnswerParser.blocks(from: source).compactMap { block in
            if case .image = block.kind {
                images += 1
                return images <= 2 ? block : nil
            }
            return block
        }
    }

    private var theme: Color {
        guard let first = AnswerParser.accentNames(in: source).first else {
            return .secondary
        }
        return AccentColors.color(first, scheme) ?? .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<blocks.count, id: \.self) { i in
                BlockView(block: blocks[i], theme: theme, scheme: scheme)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct BlockView: View {
    let block: AnswerBlock
    let theme: Color
    let scheme: ColorScheme

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(AnswerStyler.styledInline(block.inlineSource, baseSize: headingSize(level), scheme: scheme))
                .font(.system(size: headingSize(level), weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph:
            Text(AnswerStyler.styledInline(block.inlineSource, baseSize: 14, scheme: scheme))
                .font(.system(size: 14))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme)
                Text(AnswerStyler.styledInline(block.inlineSource, baseSize: 14, scheme: scheme))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .numbered(let depth, let number):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme)
                Text(AnswerStyler.styledInline(block.inlineSource, baseSize: 14, scheme: scheme))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme)
                    .frame(width: 3)
                Text(AnswerStyler.styledInline(block.inlineSource, baseSize: 13.5, scheme: scheme))
                    .font(.system(size: 13.5))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code:
            Text(block.inlineSource)
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .textSelection(.enabled)
        case .image(let alt, let url):
            ImageBlockView(alt: alt, url: url)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 17
        case 2: return 15
        default: return 14
        }
    }
}

/// One freely-licensed picture. Allowed hosts load inline with a shimmer
/// placeholder; anything else degrades to a link row; load failures degrade
/// to the caption. No failure mode can break the card.
private struct ImageBlockView: View {
    let alt: String
    let url: URL

    var body: some View {
        if AnswerParser.isAllowedImageHost(url) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.tertiary.opacity(0.3))
                        .frame(height: 170)
                        .overlay { ProgressView().controlSize(.small) }
                case .success(let image):
                    VStack(alignment: .leading, spacing: 4) {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 190)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel(alt.isEmpty ? "Illustration" : alt)
                        if !alt.isEmpty {
                            Text(alt)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failure:
                    Text(alt.isEmpty ? "Image unavailable" : alt)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.tertiary)
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                    Text(alt.isEmpty ? (url.host ?? url.absoluteString) : alt)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

enum AnswerStyler {
    /// Inline Markdown → AttributedString with palette accents applied and
    /// inline code set in monospace. Base font comes from the surrounding
    /// `Text` view; only the code runs get an explicit font.
    static func styledInline(_ s: String, baseSize: CGFloat, scheme: ColorScheme) -> AttributedString {
        var a = AnswerParser.parseInline(s)
        for run in a.runs {
            if let name = run.accent, let c = AccentColors.color(name, scheme) {
                a[run.range].foregroundColor = c
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                a[run.range].font = .system(size: baseSize - 1, design: .monospaced)
            }
        }
        return a
    }
}

/// Fixed accent colors. Unknown names resolve to nil (rendered uncolored).
enum AccentColors {
    static func color(_ name: String, _ scheme: ColorScheme) -> Color? {
        switch name.lowercased() {
        case "ember": return .orange
        case "gold": return scheme == .dark ? .yellow : Color(red: 0.58, green: 0.4, blue: 0.0)
        case "leaf": return .green
        case "sky": return .blue
        case "iris": return .purple
        case "rose": return .pink
        default: return nil
        }
    }
}
