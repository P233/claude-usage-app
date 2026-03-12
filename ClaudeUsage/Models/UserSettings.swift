import Foundation
import SwiftUI
import Combine
import AppKit

enum RefreshInterval: Int, CaseIterable, Sendable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var label: String {
        switch self {
        case .oneMinute: return "1 min"
        case .threeMinutes: return "3 min"
        case .fiveMinutes: return "5 min"
        case .tenMinutes: return "10 min"
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue)
    }
}

enum ResetSound: String, CaseIterable, Sendable {
    case none = "none"
    case glass = "Glass"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case tink = "Tink"

    var label: String {
        switch self {
        case .none: return "Off"
        case .glass: return "Glass"
        case .ping: return "Ping"
        case .pop: return "Pop"
        case .purr: return "Purr"
        case .sosumi: return "Sosumi"
        case .tink: return "Tink"
        }
    }

    func play() {
        guard self != .none else { return }
        NSSound(named: NSSound.Name(rawValue))?.play()
    }
}

/// User preferences for the app.
/// All mutations go through SwiftUI bindings on the main thread.
@MainActor
final class UserSettings: ObservableObject {
    static let shared = UserSettings()

    private let defaults = UserDefaults.standard
    private let refreshIntervalKey = "refreshInterval"
    private let resetSoundKey = "resetSound"

    @Published var refreshIntervalRaw: Int {
        didSet {
            defaults.set(refreshIntervalRaw, forKey: refreshIntervalKey)
        }
    }

    @Published var resetSoundRaw: String {
        didSet {
            defaults.set(resetSoundRaw, forKey: resetSoundKey)
        }
    }

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: refreshIntervalRaw) ?? .fiveMinutes }
        set { refreshIntervalRaw = newValue.rawValue }
    }

    var resetSound: ResetSound {
        get { ResetSound(rawValue: resetSoundRaw) ?? .none }
        set { resetSoundRaw = newValue.rawValue }
    }

    private init() {
        let storedInterval = defaults.integer(forKey: refreshIntervalKey)
        if storedInterval == 0 {
            self.refreshIntervalRaw = RefreshInterval.fiveMinutes.rawValue
        } else {
            self.refreshIntervalRaw = storedInterval
        }

        let storedSound = defaults.string(forKey: resetSoundKey)
        self.resetSoundRaw = storedSound ?? ResetSound.none.rawValue
    }
}
