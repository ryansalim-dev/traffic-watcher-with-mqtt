import Foundation

/// URL patterns shared by breakpoints and map/rewrite rules. `*` matches any run of characters; a
/// pattern without a scheme matches http and https. Matching covers the whole URL, ignores case and
/// a trailing `/`.
public enum URLPattern {
    public static func matches(_ pattern: String, url: String) -> Bool {
        guard let pattern = normalized(pattern) else { return false }
        var text = url.lowercased()
        if text.hasSuffix("/") { text.removeLast() }
        return wildcard(Array(pattern.utf8), Array(text.utf8))
    }

    /// The text each `*` of `pattern` matched in `url`, in order; nil when it doesn't match.
    /// A pattern without a scheme gets an implicit leading `*://`, whose capture is dropped.
    public static func captures(_ pattern: String, url: String) -> [String]? {
        guard matches(pattern, url: url), let normalized = normalized(pattern) else { return nil }
        let implicitScheme = !pattern.contains("://")
        var regex = "^"
        for character in normalized {
            regex += character == "*" ? "(.*?)" : NSRegularExpression.escapedPattern(for: String(character))
        }
        regex += "/?$"
        guard let expression = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) else { return nil }
        var groups: [String] = []
        for index in 1..<max(1, match.numberOfRanges) {
            guard let range = Range(match.range(at: index), in: url) else {
                groups.append("")
                continue
            }
            groups.append(String(url[range]))
        }
        return implicitScheme ? Array(groups.dropFirst()) : groups
    }

    /// Replaces each `*` in `template` with the next capture (or nothing once they run out).
    public static func substitute(_ captures: [String], into template: String) -> String {
        var remaining = captures[...]
        var result = ""
        for character in template {
            if character == "*" {
                result += remaining.popFirst() ?? ""
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func normalized(_ pattern: String) -> String? {
        var pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !pattern.isEmpty else { return nil }
        if !pattern.contains("://") { pattern = "*://" + pattern }
        if pattern.hasSuffix("/") { pattern.removeLast() }
        return pattern
    }

    /// Iterative `*` matching with backtracking to the last star; linear in practice.
    private static func wildcard(_ p: [UInt8], _ t: [UInt8]) -> Bool {
        let star = UInt8(ascii: "*")
        var pi = 0, ti = 0
        var lastStar: Int?
        var resume = 0
        while ti < t.count {
            if pi < p.count, p[pi] == star {
                lastStar = pi
                resume = ti
                pi += 1
            } else if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if let star = lastStar {
                pi = star + 1
                resume += 1
                ti = resume
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == star { pi += 1 }
        return pi == p.count
    }
}
