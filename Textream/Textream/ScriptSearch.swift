//
//  ScriptSearch.swift
//  Textream
//

import Foundation

/// Finding text in a script.
enum ScriptSearch {

    /// Every hit for `query` in `text`, in reading order.
    ///
    /// Case and accents are ignored, since a script is dictated as often as it is typed and
    /// nobody hunting for a line wants to match its accents exactly.
    static func matches(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var start = 0

        while start < ns.length {
            let remaining = NSRange(location: start, length: ns.length - start)
            let found = ns.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: remaining
            )
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            // A hit can come back empty width against some inputs; stepping at least one
            // character keeps this from spinning.
            start = found.location + max(1, found.length)
        }
        return ranges
    }
}
