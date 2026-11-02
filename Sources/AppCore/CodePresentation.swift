import Foundation
import ProxyCore

/// A run of characters in a code view, tagged with what it is so it can be colored.
public struct CodeToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case plain, key, string, number, literal }

    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Splits JSON text (usually already pretty-printed) into colorable tokens. It never fails: anything it
/// doesn't recognize comes back as plain text, so half-typed JSON in an editor still colors sensibly.
public enum JSONHighlighter {
    public static func tokens(_ source: String) -> [CodeToken] {
        let chars = Array(source.unicodeScalars)
        var tokens: [CodeToken] = []
        var plain = String.UnicodeScalarView()
        func flushPlain() {
            if !plain.isEmpty { tokens.append(CodeToken(.plain, String(plain))); plain = .init() }
        }
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\"" {
                flushPlain()
                var end = index + 1
                var escaped = false
                while end < chars.count {
                    let d = chars[end]
                    if escaped { escaped = false } else if d == "\\" { escaped = true } else if d == "\"" { break } else if d == "\n" { end -= 1; break }
                    end += 1
                }
                end = min(end, chars.count - 1)
                var text = String.UnicodeScalarView()
                text.append(contentsOf: chars[index...end])
                // A string followed by a colon is an object key.
                var look = end + 1
                while look < chars.count, chars[look] == " " || chars[look] == "\t" { look += 1 }
                let isKey = look < chars.count && chars[look] == ":"
                tokens.append(CodeToken(isKey ? .key : .string, String(text)))
                index = end + 1
            } else if c == "-" || ("0"..."9").contains(c) {
                flushPlain()
                var end = index + 1
                while end < chars.count, "0123456789.eE+-".unicodeScalars.contains(chars[end]) { end += 1 }
                var text = String.UnicodeScalarView()
                text.append(contentsOf: chars[index..<end])
                tokens.append(CodeToken(.number, String(text)))
                index = end
            } else if let word = ["true", "false", "null"].first(where: { matches($0, chars, at: index) }) {
                flushPlain()
                tokens.append(CodeToken(.literal, word))
                index += word.unicodeScalars.count
            } else {
                plain.append(c)
                index += 1
            }
        }
        flushPlain()
        return tokens
    }

    private static func matches(_ word: String, _ chars: [Unicode.Scalar], at index: Int) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard index + scalars.count <= chars.count else { return false }
        if index > 0, chars[index - 1].properties.isAlphabetic { return false }
        return Array(chars[index..<(index + scalars.count)]) == scalars
    }

    /// Tokens grouped per line, for a view with line numbers.
    public static func lines(_ source: String) -> [[CodeToken]] {
        var lines: [[CodeToken]] = [[]]
        for token in tokens(source) {
            let parts = token.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, part) in parts.enumerated() {
                if offset > 0 { lines.append([]) }
                if !part.isEmpty { lines[lines.count - 1].append(CodeToken(token.kind, String(part))) }
            }
        }
        return lines
    }
}

/// One node of a JSON document for the inspector's tree view, in document order.
public struct JSONTreeNode: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case object, array, string, number, literal }

    public var id: String
    /// The key or array index, nil for the root.
    public var key: String?
    public var kind: Kind
    /// The value for leaves, a count such as "3 items" for containers.
    public var value: String
    public var children: [JSONTreeNode]?

    /// Parses `bytes` as JSON, keeping key order. Nil when it isn't valid JSON.
    public static func parse(_ bytes: [UInt8]) -> JSONTreeNode? {
        guard (try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])) != nil,
              let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        var parser = Parser(chars: Array(text.unicodeScalars))
        return parser.value(key: nil, path: "$")
    }

    private struct Parser {
        let chars: [Unicode.Scalar]
        var index = 0

        mutating func skipSpace() {
            while index < chars.count, chars[index].properties.isWhitespace { index += 1 }
        }

        mutating func value(key: String?, path: String) -> JSONTreeNode? {
            skipSpace()
            guard index < chars.count else { return nil }
            switch chars[index] {
            case "{":
                index += 1
                var children: [JSONTreeNode] = []
                while true {
                    skipSpace()
                    if index < chars.count, chars[index] == "}" { index += 1; break }
                    guard let name = string() else { return nil }
                    skipSpace()
                    guard index < chars.count, chars[index] == ":" else { return nil }
                    index += 1
                    guard let child = value(key: name, path: path + "." + name) else { return nil }
                    children.append(child)
                    skipSpace()
                    if index < chars.count, chars[index] == "," { index += 1 }
                }
                return JSONTreeNode(id: path, key: key, kind: .object, value: Self.count(children.count, "key"), children: children)
            case "[":
                index += 1
                var children: [JSONTreeNode] = []
                while true {
                    skipSpace()
                    if index < chars.count, chars[index] == "]" { index += 1; break }
                    let position = children.count
                    guard let child = value(key: String(position), path: path + "[\(position)]") else { return nil }
                    children.append(child)
                    skipSpace()
                    if index < chars.count, chars[index] == "," { index += 1 }
                }
                return JSONTreeNode(id: path, key: key, kind: .array, value: Self.count(children.count, "item"), children: children)
            case "\"":
                guard let text = string() else { return nil }
                return JSONTreeNode(id: path, key: key, kind: .string, value: "\"\(text)\"", children: nil)
            default:
                let start = index
                while index < chars.count, !",]} \n\r\t".unicodeScalars.contains(chars[index]) { index += 1 }
                var word = String.UnicodeScalarView()
                word.append(contentsOf: chars[start..<index])
                let text = String(word)
                let kind: Kind = ["true", "false", "null"].contains(text) ? .literal : .number
                return JSONTreeNode(id: path, key: key, kind: kind, value: text, children: nil)
            }
        }

        /// Reads a string literal and returns its contents with escapes left as written.
        mutating func string() -> String? {
            guard index < chars.count, chars[index] == "\"" else { return nil }
            index += 1
            var out = String.UnicodeScalarView()
            var escaped = false
            while index < chars.count {
                let c = chars[index]
                index += 1
                if escaped { escaped = false; out.append(c); continue }
                if c == "\\" { escaped = true; out.append(c); continue }
                if c == "\"" { return String(out) }
                out.append(c)
            }
            return nil
        }

        static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
    }
}

extension HTTPExchange {
    /// The request as it went over the wire (HTTP/1.1), body included when it is text.
    public var rawRequest: String {
        var lines = ["\(method) \(TrafficRow.pathAndQuery(of: url)) HTTP/1.1"]
        lines += requestHeaders.map { "\($0.name): \($0.value)" }
        return Self.raw(lines, body: requestBody)
    }

    /// The response as it came back, body included when it is text.
    public var rawResponse: String {
        guard let statusCode else { return error ?? "No response" }
        var lines = ["HTTP/1.1 \(statusCode) \(HTTPStatus.reason(for: statusCode))".trimmingCharacters(in: .whitespaces)]
        lines += responseHeaders.map { "\($0.name): \($0.value)" }
        return Self.raw(lines, body: responseBody)
    }

    private static func raw(_ lines: [String], body: [UInt8]) -> String {
        var text = lines.joined(separator: "\n") + "\n"
        if !body.isEmpty {
            text += "\n" + (String(bytes: body.prefix(200_000), encoding: .utf8) ?? "<\(Formatting.byteCount(body.count)) of binary data>")
        }
        return text
    }

    /// A curl command that repeats this request.
    public var curlCommand: String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl"]
        if method.uppercased() != "GET" { parts.append("-X \(method.uppercased())") }
        parts.append(quote(url))
        for header in requestHeaders where !["host", "content-length"].contains(header.name.lowercased()) {
            parts.append("-H \(quote("\(header.name): \(header.value)"))")
        }
        if !requestBody.isEmpty, let text = String(bytes: requestBody, encoding: .utf8) {
            parts.append("--data-binary \(quote(text))")
        }
        return parts.joined(separator: " \\\n  ")
    }

    /// The response's media type, such as "application/json".
    public var responseContentType: String? { contentType }

    /// The request's media type.
    public var requestContentType: String? {
        requestHeaders.first { $0.name.lowercased() == "content-type" }?.value
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}

/// Reason phrases for common status codes.
public enum HTTPStatus {
    public static func reason(for code: Int) -> String {
        switch code {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 410: "Gone"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }
}
