import Foundation

/// The request line and headers of an HTTP/1.1 request, as received by the app's tiny servers.
public struct HTTPRequestHead: Equatable {
    public let method: String
    /// Percent-decoded path without the query string, e.g. "/upload/Emma.m4b".
    public let path: String
    /// Decoded query parameters ("+" counts as a space).
    public let query: [String: String]
    /// Header values keyed by lower-cased name.
    public let headers: [String: String]

    public var contentLength: Int64? { headers["content-length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }
    public var expectsContinue: Bool { headers["expect"]?.lowercased().contains("100-continue") ?? false }

    /// Parses everything up to (not including) the blank line that ends the head.
    public init?(_ text: String) {
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)[...]
        guard let requestLine = lines.popFirst() else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let pathPart = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = Self.percentDecode(String(pathPart[0]))
        query = pathPart.count > 1 ? Self.parseQuery(String(pathPart[1])) : [:]
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
    }

    public static func parseQuery(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecode(String(kv[0]).replacingOccurrences(of: "+", with: " "))
            let value = kv.count > 1 ? percentDecode(String(kv[1]).replacingOccurrences(of: "+", with: " ")) : ""
            result[key] = value
        }
        return result
    }

    public static func percentDecode(_ string: String) -> String {
        string.removingPercentEncoding ?? string
    }

    /// A file name safe to create inside a folder: no directories, no hidden files, no control characters.
    public static func safeFileName(_ name: String) -> String? {
        let last = (name as NSString).lastPathComponent
        var cleaned = last.components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// A relative folder path safe to create inside the library ("" = root): no "..", no hidden components.
    public static func safeFolder(_ folder: String) -> String? {
        let components = folder.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
        var kept: [String] = []
        for component in components where !component.isEmpty {
            guard component != "..", !component.hasPrefix("."), component.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            kept.append(component)
        }
        return kept.joined(separator: "/")
    }
}
