import SwiftUI

/// Renders the Markdown that AI answers use — headings, bullets, numbered steps, to-dos, code blocks
/// and inline bold/italic/code/links — with native typography.
struct MarkdownText: View {
    let source: String
    var fontSize: CGFloat = 13

    private enum Block: Hashable {
        case heading(String, Int), bullet(String, Int), numbered(String, String), todo(String, Bool)
        case code(String), quote(String), paragraph(String), gap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(Self.inline(text))
                .font(.system(size: fontSize + (level <= 1 ? 5 : level == 2 ? 3 : 1), weight: .semibold))
                .padding(.top, 6)
        case .bullet(let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).monospacedDigit().foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
        case .todo(let text, let done):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor)
                Text(Self.inline(text)).strikethrough(done, color: .secondary)
            }
        case .code(let text):
            Text(text)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .gap:
            Spacer().frame(height: 2)
        }
    }
    // Font is applied by the caller via the environment.

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var code: [String]?
        for raw in source.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if blocks.last != .gap && !blocks.isEmpty { blocks.append(.gap) }
            } else if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level))
            } else if line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") || line.hasPrefix("- [X]") {
                blocks.append(.todo(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces), !line.hasPrefix("- [ ]")))
            } else if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
                blocks.append(.bullet(String(line.dropFirst(2)), indent >= 2 ? 1 : 0))
            } else if let r = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                blocks.append(.numbered(String(line[r]).trimmingCharacters(in: .whitespaces), String(line[r.upperBound...])))
            } else if line.hasPrefix(">") {
                blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        while blocks.last == .gap { blocks.removeLast() }
        return blocks
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
