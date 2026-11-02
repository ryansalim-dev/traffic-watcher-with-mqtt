import CZlib
import Foundation

/// Undoes `Content-Encoding: gzip` and `deflate` so captured bodies are readable, and rules, scripts
/// and breakpoints see the real content.
///
/// Apps send `Accept-Encoding: gzip, deflate, br` by default, so without this almost every real
/// response would be stored compressed. The proxy narrows `Accept-Encoding` to the codings it can
/// undo (`acceptEncoding`), then decodes the response and forwards it uncompressed with a fresh
/// Content-Length. A body that fails to decode, or uses a coding this doesn't know, is left as it came.
enum ContentDecoding {
    /// Codings `decode` can undo.
    static let supported: Set<String> = ["gzip", "x-gzip", "deflate", "identity"]

    /// The request's `Accept-Encoding` reduced to codings the proxy can decode, or nil to drop the
    /// header (nothing decodable was offered, so the server should answer uncompressed).
    static func acceptEncoding(_ value: String) -> String? {
        let kept = value.split(separator: ",").compactMap { part -> String? in
            let token = part.trimmingCharacters(in: .whitespaces)
            let name = token.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            return supported.contains(name) ? token : nil
        }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }

    /// Decodes a response body. Returns the new body and headers, or nil to keep the original
    /// (no Content-Encoding, an unknown coding, a corrupt stream, or a result over `limit` bytes).
    static func decode(body: [UInt8], headers: [CapturedHeader], limit: Int) -> (body: [UInt8], headers: [CapturedHeader])? {
        let codings = headers
            .filter { $0.name.lowercased() == "content-encoding" }
            .flatMap { $0.value.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        // An empty body (HEAD, 304) keeps its headers, which still describe the full representation.
        guard !body.isEmpty, !codings.isEmpty, codings.allSatisfy({ supported.contains($0) }) else { return nil }
        var decoded = body
        // Codings are listed in the order they were applied, so undo them last to first.
        for coding in codings.reversed() {
            guard let next = inflate(decoded, gzip: coding != "deflate", limit: limit) else { return nil }
            decoded = next
        }
        let remaining = headers.filter { $0.name.lowercased() != "content-encoding" }
        return (decoded, remaining)
    }

    /// Inflates a gzip stream, or a `deflate` body (zlib-wrapped, or raw as some servers send it).
    static func inflate(_ input: [UInt8], gzip: Bool, limit: Int) -> [UInt8]? {
        if gzip { return run(input, windowBits: 15 + 16, limit: limit) }
        return run(input, windowBits: 15, limit: limit) ?? run(input, windowBits: -15, limit: limit)
    }

    private static func run(_ input: [UInt8], windowBits: Int32, limit: Int) -> [UInt8]? {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        output.reserveCapacity(min(limit, max(input.count * 4, 4096)))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var input = input
        var finished = false
        input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { target -> Int32 in
                    stream.next_out = target.baseAddress
                    stream.avail_out = uInt(target.count)
                    return CZlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                output.append(contentsOf: chunk[..<produced])
                if output.count > limit { return }
                switch status {
                case Z_STREAM_END:
                    // gzip allows several members back to back; carry on with the next one.
                    if windowBits > 15, stream.avail_in > 0, inflateReset(&stream) == Z_OK { continue }
                    finished = true
                    return
                case Z_OK:
                    if stream.avail_in == 0 && produced == 0 { return } // truncated
                case Z_BUF_ERROR:
                    if stream.avail_in == 0 { return } // truncated
                default:
                    return // corrupt
                }
            }
        }
        return finished ? output : nil
    }
}
