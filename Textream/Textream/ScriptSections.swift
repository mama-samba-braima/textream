//
//  ScriptSections.swift
//  Textream
//

import Foundation

/// One readable chunk of a script, taken from a Markdown `##` heading.
struct ScriptSection: Identifiable, Equatable {
    let id: Int
    /// Heading text, shown in the section bar. Never read aloud.
    let title: String
    /// The prose under the heading, with Markdown syntax removed, ready for the prompter.
    let body: String
    /// Where each word of `body` sits in the original page text, so a position in the read can be
    /// pointed at in the editor. Empty if the two could not be lined up word for word.
    let wordRanges: [NSRange]
}

/// Turns a Markdown script into sections the prompter can read one at a time.
///
/// A script is written for the eye, with a `#` title and `##` headings that carry timestamps and
/// labels. None of that is meant to be spoken, so headings become navigation and only the prose
/// underneath is ever put on screen.
enum MarkdownScript {

    /// Sections for `text`, or an empty array when it has no `##` headings, in which case the
    /// caller should treat the page as one undivided script exactly as before.
    static func sections(from text: String) -> [ScriptSection] {
        let ns = text as NSString
        let lines = lineRanges(in: ns)
        guard lines.contains(where: { headingLevel(of: ns.substring(with: $0)) == 2 }) else { return [] }

        var sections: [ScriptSection] = []
        var title = "Intro"
        var body: [String] = []
        var ranges: [NSRange] = []

        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                body = []
                ranges = []
                return
            }
            // Only keep the mapping when it lines up word for word with what will be read.
            let aligned = tokenizeText(text).words.count == ranges.count ? ranges : []
            sections.append(ScriptSection(id: sections.count, title: title, body: text, wordRanges: aligned))
            body = []
            ranges = []
        }

        for lineRange in lines {
            let line = ns.substring(with: lineRange)
            switch headingLevel(of: line) {
            case 1:
                // The document title belongs to the writer, not the read.
                continue
            case let level? where level >= 2:
                flush()
                title = headingText(of: line)
            default:
                body.append(stripInline(line))
                ranges.append(contentsOf: wordRanges(in: line, offsetBy: lineRange.location))
            }
        }
        flush()

        // Renumber, since empty sections are dropped rather than kept as gaps.
        return sections.enumerated().map { index, section in
            ScriptSection(id: index, title: section.title, body: section.body, wordRanges: section.wordRanges)
        }
    }

    /// Word ranges for a page with no headings, in the same order the prompter will read them.
    static func wordRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        for lineRange in lineRanges(in: ns) {
            let line = ns.substring(with: lineRange)
            guard headingLevel(of: line) == nil else { continue }
            ranges.append(contentsOf: wordRanges(in: line, offsetBy: lineRange.location))
        }
        return tokenizeText(plainText(from: text)).words.count == ranges.count ? ranges : []
    }

    private static func lineRanges(in ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    /// Ranges of the words in one line, in the original text's coordinates. Tokens that are pure
    /// Markdown punctuation are skipped, since they never become words in the read either.
    private static func wordRanges(in line: String, offsetBy offset: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var start: Int? = nil
        let characters = Array(line)

        func close(_ end: Int) {
            guard let s = start else { return }
            let token = String(characters[s..<end])
            if !stripInline(token).trimmingCharacters(in: .whitespaces).isEmpty {
                ranges.append(NSRange(location: offset + s, length: end - s))
            }
            start = nil
        }

        for (index, character) in characters.enumerated() {
            if character.isWhitespace {
                close(index)
            } else if start == nil {
                start = index
            }
        }
        close(characters.count)
        return ranges
    }

    /// Everything a prompter should say for `text`, with headings and Markdown syntax removed.
    static func plainText(from text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { headingLevel(of: $0) == nil }
            .map { stripInline($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Number of leading `#` characters, or nil when the line is not a heading.
    static func headingLevel(of line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        let rest = trimmed.dropFirst(hashes)
        // "#hashtag" is not a heading; a heading needs a space or nothing after the hashes.
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return hashes
    }

    static func headingText(of line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.drop { $0 == "#" }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Unwraps inline Markdown so the prompter shows words rather than punctuation.
    static func stripInline(_ line: String) -> String {
        var result = line

        // Blockquote and list markers, which are layout rather than speech
        if let range = result.range(of: "^\\s*>\\s?", options: .regularExpression) {
            result.removeSubrange(range)
        }

        for pattern in ["\\*\\*(.+?)\\*\\*", "__(.+?)__", "\\*(.+?)\\*", "`(.+?)`"] {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1",
                options: .regularExpression
            )
        }
        return result
    }
}
