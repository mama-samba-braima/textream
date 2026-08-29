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
        let lines = text.components(separatedBy: .newlines)
        guard lines.contains(where: { headingLevel(of: $0) == 2 }) else { return [] }

        var sections: [ScriptSection] = []
        var title = "Intro"
        var body: [String] = []

        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                body = []
                return
            }
            sections.append(ScriptSection(id: sections.count, title: title, body: text))
            body = []
        }

        for line in lines {
            switch headingLevel(of: line) {
            case 1:
                // The document title belongs to the writer, not the read.
                continue
            case let level? where level >= 2:
                flush()
                title = headingText(of: line)
            default:
                body.append(stripInline(line))
            }
        }
        flush()

        // Renumber, since empty sections are dropped rather than kept as gaps.
        return sections.enumerated().map { index, section in
            ScriptSection(id: index, title: section.title, body: section.body)
        }
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
