import Foundation
import SwiftUI

enum Constants {
    enum App {
        static let bundleIdentifier = "com.claudeusage.app"
    }

    enum API {
        static let requestTimeout: TimeInterval = 30
    }

    enum Refresh {
        static let retryDelaySeconds: TimeInterval = 30
        /// Additional delay after reset time before refreshing (seconds)
        static let resumeDelaySeconds: TimeInterval = 5
    }

    enum UI {
        static let menuBarWidth: CGFloat = 300

        // Status bar dimensions
        static let statusBarMinWidth: CGFloat = 45
        static let statusBarHeight: CGFloat = 22
        static let statusBarPadding: CGFloat = 4

        // Card styling
        static let cardCornerRadius: CGFloat = 6
        static let cardHorizontalPadding: CGFloat = 12
        static let cardVerticalPadding: CGFloat = 10

        // Compact layout threshold
        static let compactLayoutThreshold = 4
    }

    enum Colors {
        /// Claude brand orange color (RGB: 217, 115, 64)
        static let claudeOrange = (red: 0.85, green: 0.45, blue: 0.25)

        /// Card background color - adapts to light/dark mode
        static let cardBackground = Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor.white.withAlphaComponent(0.05)
            } else {
                return NSColor.white.withAlphaComponent(0.75)
            }
        })
    }

    enum Time {
        static let secondsPerMinute = 60
        static let secondsPerHour = 3600
        static let secondsPerDay = 86400
    }

    enum OAuth {
        static let apiBaseURL = URL(string: "https://api.anthropic.com/api/oauth")!
        static let claudeCodeKeychainService = "Claude Code-credentials"
        static let betaHeader = "oauth-2025-04-20"
    }
}
