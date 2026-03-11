import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "UsageData")

// MARK: - Date Formatters (cached for performance)

private enum DateFormatters {
    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// Abbreviated duration formatter in English (e.g., "2h 30m", "3d 5h")
    static let remainingTime: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        formatter.calendar = {
            var calendar = Calendar.current
            calendar.locale = Locale(identifier: "en_US_POSIX")
            return calendar
        }()
        return formatter
    }()
}

// MARK: - Currency Formatter

/// Currency formatter — creates a fresh NumberFormatter per call for thread safety.
/// Only called from @MainActor views so performance impact is negligible.
private enum CurrencyFormatters {
    static func format(cents: Int, currency: String) -> String {
        let amount = Double(cents) / 100.0
        let key = currency.uppercased()

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = key

        switch key {
        case "USD": formatter.currencySymbol = "$"
        case "EUR": formatter.currencySymbol = "€"
        case "GBP": formatter.currencySymbol = "£"
        case "JPY":
            formatter.currencySymbol = "¥"
            formatter.maximumFractionDigits = 0
        case "CNY": formatter.currencySymbol = "¥"
        case "CAD": formatter.currencySymbol = "CA$"
        case "AUD": formatter.currencySymbol = "A$"
        default: formatter.currencySymbol = key
        }

        return formatter.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
    }
}

// MARK: - API Response Models

/// Raw usage period data from API
struct UsagePeriodResponse: Codable {
    let utilization: Int
    let resetsAt: String?

    /// Memberwise initializer (also used by tests)
    init(utilization: Int, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Extra usage data embedded in OAuth usage response
struct OAuthExtraUsage: Codable {
    let isEnabled: Bool
    let monthlyLimit: Int?
    let usedCredits: Int?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }

    /// Whether spending data is available (has limit values, regardless of enabled state)
    var hasSpendingData: Bool {
        guard let limit = monthlyLimit, limit > 0 else { return false }
        return true
    }

    var usedPercentage: Int {
        guard let used = usedCredits, let limit = monthlyLimit, limit > 0 else { return 0 }
        return Int(Double(used) / Double(limit) * 100)
    }

    var formattedUsedCredits: String {
        CurrencyFormatters.format(cents: usedCredits ?? 0, currency: "usd")
    }

    var formattedMonthlyLimit: String {
        CurrencyFormatters.format(cents: monthlyLimit ?? 0, currency: "usd")
    }
}

/// Dynamic usage response - parses any fields from the API
struct UsageResponse {
    let items: [String: UsagePeriodResponse]
    /// Extra usage data (present in OAuth responses)
    let extraUsage: OAuthExtraUsage?

    /// Memberwise initializer (also used by tests)
    init(items: [String: UsagePeriodResponse], extraUsage: OAuthExtraUsage? = nil) {
        self.items = items
        self.extraUsage = extraUsage
    }

    /// Ordered keys based on priority:
    /// 1. five_hour
    /// 2. seven_day
    /// 3. seven_day_* variants
    /// 4. others (alphabetically)
    var orderedKeys: [String] {
        var priorityKeys: [String] = []
        var sevenDayKeys: [String] = []
        var otherKeys: [String] = []

        for key in items.keys {
            if key == "five_hour" {
                priorityKeys.insert(key, at: 0)
            } else if key == "seven_day" {
                priorityKeys.append(key)
            } else if key.hasPrefix("seven_day_") {
                sevenDayKeys.append(key)
            } else {
                otherKeys.append(key)
            }
        }

        sevenDayKeys.sort()
        otherKeys.sort()

        return priorityKeys + sevenDayKeys + otherKeys
    }
}

extension UsageResponse: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var parsedItems: [String: UsagePeriodResponse] = [:]
        var parsedExtraUsage: OAuthExtraUsage?

        for key in container.allKeys {
            if key.stringValue == "extra_usage" {
                // Parse inline extra_usage from OAuth response
                do {
                    parsedExtraUsage = try container.decodeIfPresent(OAuthExtraUsage.self, forKey: key)
                } catch {
                    logger.error("Failed to decode extra_usage: \(error)")
                }
            } else if let period = try? container.decodeIfPresent(UsagePeriodResponse.self, forKey: key) {
                parsedItems[key.stringValue] = period
            }
        }

        self.items = parsedItems
        self.extraUsage = parsedExtraUsage
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

// MARK: - Processed Usage Models

/// A single usage item with display properties
struct UsageItem: Identifiable {
    let id: String
    let key: String
    let utilization: Int
    let resetsAt: Date?

    init(key: String, utilization: Int, resetsAt: Date?) {
        self.id = key
        self.key = key
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// Display title for the usage item
    var displayTitle: String {
        switch key {
        case "five_hour":
            return "5-Hour Usage"
        case "seven_day":
            return "7-Day Usage"
        default:
            if key.hasPrefix("seven_day_") {
                let suffix = String(key.dropFirst(10))
                let formatted = suffix.split(separator: "_")
                    .map { $0.capitalized }
                    .joined(separator: " ")
                return "7-Day \(formatted)"
            }
            return key.split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    var percentage: Double {
        Double(utilization) / 100.0
    }

    var displayText: String {
        "\(utilization)%"
    }

    var isNearLimit: Bool {
        utilization >= 80
    }

    var isAtLimit: Bool {
        utilization >= 100
    }

    /// Usage status level for color coding
    var statusLevel: UsageStatusLevel {
        if isAtLimit { return .critical }
        if isNearLimit { return .warning }
        return .normal
    }

    /// Short title for compact display
    var compactTitle: String {
        switch key {
        case "five_hour":
            return "5-Hour"
        case "seven_day":
            return "7-Day"
        default:
            if key.hasPrefix("seven_day_") {
                let suffix = String(key.dropFirst(10))
                return suffix.capitalized
            }
            return displayTitle
        }
    }

    /// Whether to use long reset display (for non-5-hour items)
    var useLongResetDisplay: Bool {
        key != "five_hour"
    }

    // MARK: - Reset Time Display Properties

    private var resetTimeResult: ResetTimeFormatter.Result {
        ResetTimeFormatter.parse(resetsAt)
    }

    var resetTimeDisplay: String? {
        switch resetTimeResult {
        case .none: return nil
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return ResetTimeFormatter.shortDisplay(for: tc)
        }
    }

    var resetTimeShort: String? {
        switch resetTimeResult {
        case .none: return nil
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return ResetTimeFormatter.timeOnly(for: tc)
        }
    }

    var resetTimeRemaining: String? {
        switch resetTimeResult {
        case .none: return ResetTimeFormatter.readyText
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return ResetTimeFormatter.compactRemaining(for: tc)
        }
    }

    var resetTimeTarget: String? {
        switch resetTimeResult {
        case .none: return nil
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return "until \(ResetTimeFormatter.formatResetTime(tc.date))"
        }
    }

    var resetTimeDisplayLong: String? {
        switch resetTimeResult {
        case .none: return nil
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return ResetTimeFormatter.longDisplay(for: tc)
        }
    }
}

// MARK: - Reset Time Formatting

private enum ResetTimeFormatter {
    static let updatingText = "Updating..."
    static let readyText = "Ready"

    struct TimeComponents {
        let date: Date
        let days: Int
        let hours: Int
        let minutes: Int

        var totalSeconds: Int {
            days * Constants.Time.secondsPerDay
                + hours * Constants.Time.secondsPerHour
                + minutes * Constants.Time.secondsPerMinute
        }

        var remainingFormatted: String? {
            let interval = TimeInterval(max(60, totalSeconds))
            return DateFormatters.remainingTime.string(from: interval)
        }

        var remainingWithPrefix: String {
            if let formatted = remainingFormatted {
                return "in \(formatted)"
            }
            return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
        }
    }

    enum Result {
        case none
        case expired
        case valid(TimeComponents)
    }

    static func parse(_ resetsAt: Date?) -> Result {
        guard let resetsAt = resetsAt else { return .none }
        let interval = resetsAt.timeIntervalSince(Date())
        guard interval > 0 else { return .expired }

        let totalSeconds = Int(interval)
        return .valid(TimeComponents(
            date: resetsAt,
            days: totalSeconds / Constants.Time.secondsPerDay,
            hours: (totalSeconds % Constants.Time.secondsPerDay) / Constants.Time.secondsPerHour,
            minutes: (totalSeconds % Constants.Time.secondsPerHour) / Constants.Time.secondsPerMinute
        ))
    }

    static func roundToNearestMinute(_ date: Date) -> Date {
        let seconds = Calendar.current.component(.second, from: date)
        let adjustment = seconds >= 30 ? (60 - seconds) : -seconds
        return date.addingTimeInterval(TimeInterval(adjustment))
    }

    static func formatResetTime(_ date: Date) -> String {
        let rounded = roundToNearestMinute(date)
        let calendar = Calendar.current
        if calendar.isDateInToday(rounded) {
            return DateFormatters.timeOnly.string(from: rounded)
        } else if calendar.isDateInTomorrow(rounded) {
            return "Tmr \(DateFormatters.timeOnly.string(from: rounded))"
        } else {
            return DateFormatters.dateTime.string(from: rounded)
        }
    }

    static func shortDisplay(for tc: TimeComponents) -> String {
        let timeStr = formatResetTime(tc.date)
        return "\(timeStr) · \(tc.remainingWithPrefix)"
    }

    static func longDisplay(for tc: TimeComponents) -> String {
        let rounded = roundToNearestMinute(tc.date)
        guard let remaining = tc.remainingFormatted else {
            return Calendar.current.isDateInToday(rounded)
                ? DateFormatters.timeOnly.string(from: rounded)
                : DateFormatters.monthDay.string(from: rounded)
        }

        if Calendar.current.isDateInToday(rounded) {
            let timeStr = DateFormatters.timeOnly.string(from: rounded)
            return "\(timeStr) · in \(remaining)"
        } else {
            let dateStr = DateFormatters.monthDay.string(from: rounded)
            return "\(dateStr) · in \(remaining)"
        }
    }

    static func compactRemaining(for tc: TimeComponents) -> String? {
        tc.remainingFormatted
    }

    static func timeOnly(for tc: TimeComponents) -> String {
        DateFormatters.timeOnly.string(from: roundToNearestMinute(tc.date))
    }
}

/// Usage status levels for UI color coding
enum UsageStatusLevel {
    case normal    // < 80%
    case warning   // 80-99%
    case critical  // >= 100%

    static func from(percentage: Int) -> UsageStatusLevel {
        if percentage >= 100 { return .critical }
        if percentage >= 80 { return .warning }
        return .normal
    }
}

/// Processed usage summary with ordered items
struct UsageSummary {
    let items: [UsageItem]
    let lastUpdated: Date

    var primaryItem: UsageItem? {
        items.first { $0.key == "five_hour" } ?? items.first
    }

    var isPrimaryAtLimit: Bool {
        primaryItem?.isAtLimit ?? false
    }

    var primaryResetsAt: Date? {
        primaryItem?.resetsAt
    }
}

// MARK: - Extra Usage Models

struct PrepaidCredits: Codable {
    let amount: Int
    let currency: String
    let autoReloadSettings: AutoReloadSettings?

    enum CodingKeys: String, CodingKey {
        case amount, currency
        case autoReloadSettings = "auto_reload_settings"
    }
}

struct AutoReloadSettings: Codable {
    let enabled: Bool?
}

struct OverageSpendLimit: Codable {
    let isEnabled: Bool
    let monthlyCreditLimit: Int
    let currency: String
    let usedCredits: Int

    // Present in detailed API response, absent in inline fallback
    let organizationUuid: String?
    let outOfCredits: Bool?
    let createdAt: String?
    let updatedAt: String?

    init(
        isEnabled: Bool,
        monthlyCreditLimit: Int,
        currency: String,
        usedCredits: Int,
        organizationUuid: String? = nil,
        outOfCredits: Bool? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyCreditLimit = monthlyCreditLimit
        self.currency = currency
        self.usedCredits = usedCredits
        self.organizationUuid = organizationUuid
        self.outOfCredits = outOfCredits
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyCreditLimit = "monthly_credit_limit"
        case currency
        case usedCredits = "used_credits"
        case organizationUuid = "organization_uuid"
        case outOfCredits = "out_of_credits"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var usedPercentage: Int {
        guard monthlyCreditLimit > 0 else { return 0 }
        return Int(Double(usedCredits) / Double(monthlyCreditLimit) * 100)
    }

    var formattedUsedCredits: String {
        CurrencyFormatters.format(cents: usedCredits, currency: currency)
    }

    var formattedMonthlyLimit: String {
        CurrencyFormatters.format(cents: monthlyCreditLimit, currency: currency)
    }

    var resetDateDisplay: String {
        let calendar = Calendar.current
        let now = Date()
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: now),
              let firstOfNextMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth)) else {
            return ""
        }
        return "Resets \(DateFormatters.monthDay.string(from: firstOfNextMonth))"
    }
}

struct ExtraUsageSummary {
    let credits: PrepaidCredits?
    let spendLimit: OverageSpendLimit?

    /// Whether detailed API data is available (vs inline fallback)
    var hasDetailedData: Bool { credits != nil }

    var formattedBalance: String? {
        guard let credits = credits else { return nil }
        return CurrencyFormatters.format(cents: credits.amount, currency: credits.currency)
    }

    var isAutoReloadOn: Bool {
        credits?.autoReloadSettings?.enabled ?? false
    }
}

// MARK: - Billing Request/Response Models

struct UpdateOverageSpendLimitRequest: Codable {
    let isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
    }
}
