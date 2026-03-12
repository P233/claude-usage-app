import Foundation

/// Represents the user's Claude subscription type.
/// Stores the raw capability name and provides formatted display.
struct SubscriptionType: Equatable, Codable {
    let rawValue: String?

    /// Display name for UI
    /// - "claude_pro" → "Pro"
    /// - "claude_max" → "Max"
    /// - Non "claude_" prefix → shows original value
    var displayName: String? {
        guard let raw = rawValue else { return nil }

        if raw.lowercased().hasPrefix("claude_") {
            let suffix = String(raw.dropFirst(7))
            return suffix.isEmpty ? raw : suffix.capitalized
        }

        return raw
    }

    /// Infer subscription type from capabilities array
    /// Returns the first claude_* capability found, or first capability if none
    static func from(capabilities: [String]?) -> SubscriptionType {
        guard let capabilities = capabilities, !capabilities.isEmpty else {
            return SubscriptionType(rawValue: nil)
        }

        // Prefer claude_* capability
        if let claudeCapability = capabilities.first(where: { $0.lowercased().hasPrefix("claude_") }) {
            return SubscriptionType(rawValue: claudeCapability.lowercased())
        }

        return SubscriptionType(rawValue: capabilities.first)
    }

    /// Create from Claude Code's OAuth subscriptionType format (e.g., "max" → "claude_max")
    static func from(oauthSubscriptionType: String?) -> SubscriptionType {
        guard let subType = oauthSubscriptionType else {
            return SubscriptionType(rawValue: nil)
        }
        let normalized = subType.lowercased().hasPrefix("claude_") ? subType : "claude_\(subType)"
        return SubscriptionType(rawValue: normalized.lowercased())
    }

    /// Legacy migration: infer from old rateLimitTier format
    /// e.g., "default_claude_max_5x" → extract "claude_max_5x"
    static func from(rateLimitTier: String?) -> SubscriptionType {
        guard let tier = rateLimitTier else {
            return SubscriptionType(rawValue: nil)
        }
        let lowered = tier.lowercased()
        if let range = lowered.range(of: "claude_") {
            return SubscriptionType(rawValue: String(lowered[range.lowerBound...]))
        }
        return SubscriptionType(rawValue: "claude_\(lowered)")
    }
}
