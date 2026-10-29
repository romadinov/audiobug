import Foundation

/// True for development-signed builds — your own installs (Xcode, scripts/install-iphone.sh). Improvement notes
/// and crash reports are collected only in those: they land in your own iCloud, which only your agents read.
/// (Apps can't see the App Store account's email, so the signature is the reliable signal; TestFlight and
/// App Store builds are distribution-signed.) Same scheme as Uberdoer and Scriptorium.
enum DeveloperBuild {
    static let isDeveloper: Bool = {
        #if DEBUG
        return true
        #else
        // A development provisioning profile is embedded and allows debugging (get-task-allow).
        guard let data = try? Data(contentsOf: Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "get-task-allow</key>") else { return false }
        return text[key.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<true/>")
        #endif
    }()
}
