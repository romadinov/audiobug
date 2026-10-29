import Foundation

enum TimeFormat {
    /// "1:02:03" or "2:03".
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "–:––" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1h 23m" / "45m" / "30s" — for lists.
    static func compact(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    static func rate(_ rate: Float) -> String {
        let text = String(format: "%.2f", rate)
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed + "×"
    }
}
