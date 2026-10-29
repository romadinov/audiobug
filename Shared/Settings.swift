import Foundation
import Observation

/// Listening preferences, kept in UserDefaults.
@MainActor @Observable
final class Settings {
    static let shared = Settings()
    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let skipChoices: [TimeInterval] = [10, 15, 30, 45, 60]

    /// Speed for books that haven't been played yet (each book remembers its own speed afterwards).
    var defaultRate: Float {
        didSet { UserDefaults.standard.set(defaultRate, forKey: "defaultRate") }
    }
    var skipForward: TimeInterval {
        didSet { UserDefaults.standard.set(skipForward, forKey: "skipForward") }
    }
    var skipBack: TimeInterval {
        didSet { UserDefaults.standard.set(skipBack, forKey: "skipBack") }
    }

    private init() {
        let d = UserDefaults.standard
        defaultRate = d.object(forKey: "defaultRate") as? Float ?? 1.0
        skipForward = d.object(forKey: "skipForward") as? TimeInterval ?? 30
        skipBack = d.object(forKey: "skipBack") as? TimeInterval ?? 15
    }
}
