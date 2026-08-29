//
//  MarkdownPreviewView.swift
//  Textream
//

import SwiftUI

/// One rendered piece of a script: a heading, a run of prose, a bullet or a quote.
struct MarkdownBlock: Identifiable {
    enum Kind {
        case title
        case heading(level: Int)
        case prose
        case bullet
        case quote
        case rule
    }

    /// Where the block starts in the page text. Doubles as its identity, so the sidebar can scroll
    /// the preview to a heading by character offset.
    let id: Int
    let kind: Kind
    let text: String
}

/// The current page as rendered Markdown: headings become headings, `**bold**` becomes bold, and
/// the syntax gets out of the way so the script can be read rather than parsed.
struct MarkdownPreviewView: View {
    let text: String
    var fontSize: Double
    /// Character offset of a heading to scroll to, cleared once the scroll has happened.
    @Binding var scrollTarget: Int?

    private static let cuePattern = try! NSRegularExpression(pattern: "\\[[^\\]]+\\]")

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks) { block in
                        blockView(block)
                            .id(block.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .textSelection(.enabled)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                DispatchQueue.main.async { scrollTarget = nil }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .title:
            Text(styled(block.text))
                .font(.system(size: fontSize * 1.7, weight: .bold, design: .rounded))
                .padding(.bottom, 10)

        case .heading(let level):
            let scale = level <= 2 ? 1.2 : 1.05
            VStack(alignment: .leading, spacing: 6) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                Text(styled(block.text))
                    .font(.system(size: fontSize * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

        case .prose:
            Text(styled(block.text))
                .font(.system(size: fontSize, design: .rounded))
                .lineSpacing(fontSize * 0.35)
                .padding(.bottom, 10)

        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\u{2022}")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                Text(styled(block.text))
                    .font(.system(size: fontSize, design: .rounded))
                    .lineSpacing(fontSize * 0.35)
            }
            .padding(.bottom, 6)

        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: 3)
                Text(styled(block.text))
                    .font(.system(size: fontSize, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(fontSize * 0.35)
            }
            .padding(.bottom, 10)

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 12)
        }
    }

    // MARK: - Parsing

    private var blocks: [MarkdownBlock] {
        Self.blocks(from: text)
    }

    /// Splits a script into rendered blocks, keeping each block's offset in the source so the
    /// preview can be scrolled to a heading the same way the editor is.
    static func blocks(from text: String) -> [MarkdownBlock] {
        let ns = text as NSString
        var lineRanges: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            lineRanges.append(range)
        }

        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var proseStart = 0

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            prose = []
            guard !joined.isEmpty else { return }
            blocks.append(MarkdownBlock(id: proseStart, kind: .prose, text: joined))
        }

        for range in lineRanges {
            let line = ns.substring(with: range)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let level = MarkdownScript.headingLevel(of: line) {
                flushProse()
                let title = MarkdownScript.headingText(of: line)
                blocks.append(MarkdownBlock(
                    id: range.location,
                    kind: level == 1 ? .title : .heading(level: level),
                    text: title
                ))
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                flushProse()
                blocks.append(MarkdownBlock(id: range.location, kind: .rule, text: ""))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushProse()
                blocks.append(MarkdownBlock(
                    id: range.location,
                    kind: .quote,
                    text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                ))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushProse()
                blocks.append(MarkdownBlock(
                    id: range.location,
                    kind: .bullet,
                    text: String(trimmed.dropFirst(2))
                ))
                continue
            }

            if trimmed.isEmpty {
                flushProse()
                continue
            }

            if prose.isEmpty { proseStart = range.location }
            prose.append(trimmed)
        }
        flushProse()

        // Blocks are identified by source offset, and an empty script would give none at all.
        return blocks.isEmpty ? [MarkdownBlock(id: 0, kind: .prose, text: "")] : blocks
    }

    /// Inline Markdown, with `[direction cues]` dimmed the same way the editor dims them.
    private func styled(_ source: String) -> AttributedString {
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(source)
        }

        let plain = String(attributed.characters)
        let matches = Self.cuePattern.matches(
            in: plain,
            range: NSRange(location: 0, length: (plain as NSString).length)
        )
        for match in matches {
            guard let stringRange = Range(match.range, in: plain),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].foregroundColor = .secondary
            attributed[lower..<upper].font = .system(size: fontSize).italic()
        }
        return attributed
    }
}
