import Foundation
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "UsageRefreshService")

@MainActor
protocol UsageRefreshServiceProtocol: AnyObject {
    var usageSummary: UsageSummary? { get }
    var usageSummaryPublisher: Published<UsageSummary?>.Publisher { get }
    var extraUsage: ExtraUsageSummary? { get }
    var extraUsagePublisher: Published<ExtraUsageSummary?>.Publisher { get }
    var isRefreshing: Bool { get }
    var isRefreshingPublisher: Published<Bool>.Publisher { get }
    var lastError: String? { get }
    var lastErrorPublisher: Published<String?>.Publisher { get }
    var secondsUntilNextRefresh: Int { get }
    var secondsUntilNextRefreshPublisher: Published<Int>.Publisher { get }

    func startAutoRefresh()
    func stopAutoRefresh()
    func refreshNow() async
}

@MainActor
final class UsageRefreshService: ObservableObject, UsageRefreshServiceProtocol {

    @Published private(set) var usageSummary: UsageSummary?
    var usageSummaryPublisher: Published<UsageSummary?>.Publisher { $usageSummary }

    @Published private(set) var extraUsage: ExtraUsageSummary?
    var extraUsagePublisher: Published<ExtraUsageSummary?>.Publisher { $extraUsage }

    @Published private(set) var isRefreshing = false
    var isRefreshingPublisher: Published<Bool>.Publisher { $isRefreshing }

    @Published private(set) var lastError: String?
    var lastErrorPublisher: Published<String?>.Publisher { $lastError }

    @Published private(set) var secondsUntilNextRefresh: Int = 0
    var secondsUntilNextRefreshPublisher: Published<Int>.Publisher { $secondsUntilNextRefresh }

    private let apiClient: ClaudeAPIClientProtocol
    private let authService: AuthenticationServiceProtocol
    private let settings: UserSettings
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Target date for `secondsUntilNextRefresh` countdown.
    /// During normal auto-refresh: next API call time.
    /// During reset countdown (100%): primary item's `resetsAt` time.
    private var nextRefreshDate: Date?
    private var retryCount = 0
    private let maxRetries = 3
    private var currentRefreshTask: Task<Void, Never>?

    private let cacheKey = "cachedUsageSummary_v2"

    /// Last known primary utilization percentage (0-100), used to detect reset.
    private var lastUtilization: Int?

    /// Timer to resume refresh when primary usage resets
    private var resumeRefreshTimer: Timer?

    /// Set of already-processed reset times to avoid triggering multiple refreshes
    private var processedResetTimes: Set<Date> = []

    /// Sleep/wake notification observers (must be removed on deinit)
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // Cached date formatters for performance
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterWithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(
        apiClient: ClaudeAPIClientProtocol,
        authService: AuthenticationServiceProtocol,
        settings: UserSettings? = nil
    ) {
        self.apiClient = apiClient
        self.authService = authService
        self.settings = settings ?? .shared

        loadCachedData()
        setupAuthStateObserver()
        setupSettingsObserver()
        setupWakeObserver()
    }

    deinit {
        currentRefreshTask?.cancel()
        countdownTask?.cancel()
        refreshTimer?.invalidate()
        countdownTimer?.invalidate()
        resumeRefreshTimer?.invalidate()
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func setupAuthStateObserver() {
        authService.authStatePublisher
            .sink { [weak self] (state: AuthState) in
                guard let self = self else { return }

                // Cancel and wait for previous task to complete
                self.currentRefreshTask?.cancel()
                self.currentRefreshTask = nil
                self.retryCount = 0  // Reset retry count on auth state change

                if state.isAuthenticated {
                    self.currentRefreshTask = Task { [weak self] in
                        await self?.refreshNow()
                    }
                    self.startAutoRefresh()
                } else {
                    self.stopAllTimers()
                    self.usageSummary = nil
                    self.extraUsage = nil
                    self.clearCache()
                    self.lastUtilization = nil
                    self.processedResetTimes.removeAll()
                }
            }
            .store(in: &cancellables)
    }

    private func setupSettingsObserver() {
        settings.$refreshIntervalRaw
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.authService.authState.isAuthenticated {
                    self.startAutoRefresh()
                }
            }
            .store(in: &cancellables)
    }

    private func setupWakeObserver() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                logger.info("System going to sleep, stopping all timers")
                self.stopAllTimers()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.authService.authState.isAuthenticated else { return }

                logger.info("System woke from sleep, refreshing usage")
                Task.detached(priority: .utility) { ClaudeCodeVersion.refresh() }
                self.resumeRefreshTimer?.invalidate()
                self.resumeRefreshTimer = nil
                await self.refreshNow()
                self.startAutoRefresh()
            }
        }
    }

    /// Checks if primary usage has reset and plays notification sound.
    private func checkForResetAndPlaySound(utilization: Int?) {
        defer { lastUtilization = utilization }

        guard let current = utilization, let last = lastUtilization else { return }

        if last > 0 && current == 0 {
            logger.info("Primary usage reset detected (\(last)% → 0%), playing sound")
            settings.resetSound.play()
        }
    }

    /// Schedules a timer to resume refresh when primary usage resets.
    private func scheduleResumeRefresh(resetsAt: Date?) {
        resumeRefreshTimer?.invalidate()
        resumeRefreshTimer = nil

        guard let resetsAt = resetsAt else { return }

        let interval = resetsAt.timeIntervalSince(Date())
        guard interval > 0 else {
            logger.info("Reset time has passed, refreshing now")
            Task { @MainActor [weak self] in
                await self?.refreshNow()
                self?.startAutoRefresh()
            }
            return
        }

        let delayedInterval = interval + Constants.Refresh.resumeDelaySeconds

        logger.info("Primary usage expired, scheduling resume refresh in \(Int(delayedInterval))s")
        resumeRefreshTimer = Timer.scheduledTimer(withTimeInterval: delayedInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                logger.info("Resume timer fired, refreshing and restarting auto-refresh")
                await self.refreshNow()
                self.startAutoRefresh()
            }
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()

        if let summary = usageSummary, summary.isPrimaryAtLimit {
            logger.info("Primary usage at limit, not starting auto-refresh")
            scheduleResumeRefresh(resetsAt: summary.primaryResetsAt)
            startResetCountdown(resetsAt: summary.primaryResetsAt)
            return
        }

        let interval = settings.refreshInterval.seconds
        nextRefreshDate = Date().addingTimeInterval(interval)
        updateCountdown()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshNow()
            }
        }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCountdown()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownTask?.cancel()
        countdownTask = nil
        nextRefreshDate = nil
        secondsUntilNextRefresh = 0
    }

    private func stopAllTimers() {
        stopAutoRefresh()
        resumeRefreshTimer?.invalidate()
        resumeRefreshTimer = nil
    }

    /// Starts a 60-second countdown timer targeting the reset time, aligned to system clock
    /// minute boundaries.
    private func startResetCountdown(resetsAt: Date?) {
        guard let resetsAt = resetsAt else { return }

        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownTask?.cancel()

        nextRefreshDate = resetsAt
        updateCountdown()

        // Align first tick to next minute boundary, then switch to 60s repeating timer
        let secondsIntoMinute = Calendar.current.component(.second, from: Date())
        let delayToNextMinute = secondsIntoMinute == 0 ? 0.0 : TimeInterval(60 - secondsIntoMinute)

        countdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayToNextMinute * 1_000_000_000))
            guard !Task.isCancelled, let self = self, self.nextRefreshDate != nil else { return }
            self.updateCountdown()

            self.countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.nextRefreshDate != nil else { return }
                    self.updateCountdown()
                }
            }
        }
    }

    private func updateCountdown() {
        guard let nextRefresh = nextRefreshDate else {
            secondsUntilNextRefresh = 0
            return
        }
        let remaining = Int(nextRefresh.timeIntervalSince(Date()))
        secondsUntilNextRefresh = max(0, remaining)

        checkForExpiredResetTimes()
    }

    /// Checks if any usage item's reset time has expired and triggers a refresh.
    private func checkForExpiredResetTimes() {
        guard !isRefreshing else { return }
        guard let items = usageSummary?.items else { return }

        let now = Date()
        for item in items {
            guard let resetsAt = item.resetsAt else { continue }

            if resetsAt <= now && !processedResetTimes.contains(resetsAt) {
                processedResetTimes.insert(resetsAt)
                logger.info("Usage item '\(item.key)' reset time expired, forcing refresh")
                Task { @MainActor [weak self] in
                    await self?.refreshNow()
                }
                return
            }
        }
    }

    func refreshNow() async {
        guard !isRefreshing else {
            logger.debug("Refresh already in progress, skipping")
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        retryCount = 0

        let hasActiveTimer = refreshTimer != nil
        let refreshInterval = settings.refreshInterval.seconds

        await performRefresh()

        if hasActiveTimer && refreshTimer != nil {
            nextRefreshDate = Date().addingTimeInterval(refreshInterval)
        }
    }

    private func performRefresh() async {
        guard authService.authState.isAuthenticated else {
            lastError = "Not authenticated"
            return
        }

        if !NetworkMonitor.shared.isConnected {
            lastError = "No network connection"
            logger.warning("Refresh skipped: no network connection")
            return
        }

        lastError = nil

        do {
            let usageResponse = try await apiClient.fetchUsage()

            let summary = processUsageResponse(usageResponse)

            checkForResetAndPlaySound(utilization: summary.primaryItem?.utilization)

            let previousResetsAt = self.usageSummary?.primaryResetsAt
            self.usageSummary = summary
            self.retryCount = 0
            // Only clear dedup set when reset times actually change
            if summary.primaryResetsAt != previousResetsAt {
                self.processedResetTimes.removeAll()
            }
            saveCache(summary)

            if summary.isPrimaryAtLimit {
                logger.info("Primary usage at limit, pausing auto-refresh")
                stopAutoRefresh()
                scheduleResumeRefresh(resetsAt: summary.primaryResetsAt)
                startResetCountdown(resetsAt: summary.primaryResetsAt)
            }

            // Fetch detailed extra usage data from separate endpoints,
            // falling back to inline data from usage response
            await fetchExtraUsageData(inlineExtraUsage: usageResponse.extraUsage)

            let primaryUtil = summary.primaryItem?.utilization ?? 0
            logger.info("Usage updated: \(summary.items.count) items, primary=\(primaryUtil)%")
        } catch let error as ClaudeAPIClient.APIError {
            lastError = error.localizedDescription
            logger.error("API Error: \(error.localizedDescription)")

            if error.isAuthError {
                retryCount = 0
            } else {
                await handleRetry()
            }
        } catch {
            lastError = error.localizedDescription
            logger.error("Error: \(error.localizedDescription)")
            await handleRetry()
        }
    }

    private func handleRetry() async {
        guard retryCount < maxRetries else {
            logger.warning("Max retries reached, waiting for next scheduled refresh")
            return
        }

        retryCount += 1
        let delay = Constants.Refresh.retryDelaySeconds * pow(2.0, Double(retryCount - 1))
        logger.info("Retrying in \(Int(delay))s (attempt \(self.retryCount)/\(self.maxRetries))")

        guard !Task.isCancelled else {
            logger.debug("Task cancelled, aborting retry")
            return
        }

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        guard !Task.isCancelled else {
            logger.debug("Task cancelled after sleep, aborting retry")
            return
        }

        await performRefresh()
    }

    // MARK: - Cache

    private func saveCache(_ summary: UsageSummary) {
        let cached = CachedUsageSummary(
            items: summary.items.map { CachedUsageItem(key: $0.key, utilization: $0.utilization, resetsAt: $0.resetsAt) },
            lastUpdated: summary.lastUpdated
        )

        do {
            let data = try JSONEncoder().encode(cached)
            UserDefaults.standard.set(data, forKey: cacheKey)
            logger.debug("Cache saved successfully")
        } catch {
            logger.warning("Failed to save cache: \(error.localizedDescription)")
        }
    }

    private static let cacheMaxAge: TimeInterval = 3600

    private func loadCachedData() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else {
            logger.debug("No cached data found")
            return
        }

        do {
            let cached = try JSONDecoder().decode(CachedUsageSummary.self, from: data)

            let age = Date().timeIntervalSince(cached.lastUpdated)
            if age > Self.cacheMaxAge {
                logger.info("Cache expired (age: \(Int(age))s), will refresh on login")
                clearCache()
                return
            }

            let items = cached.items.map { UsageItem(key: $0.key, utilization: $0.utilization, resetsAt: $0.resetsAt) }
            self.usageSummary = UsageSummary(items: items, lastUpdated: cached.lastUpdated)
            logger.info("Loaded cached data (age: \(Int(age))s)")
        } catch {
            logger.warning("Failed to load cache: \(error.localizedDescription)")
        }
    }

    private func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        logger.debug("Cache cleared")
    }

    // MARK: - Extra Usage

    private func fetchExtraUsageData(inlineExtraUsage: OAuthExtraUsage?) async {
        // Try detailed endpoints first
        do {
            async let creditsTask = apiClient.fetchPrepaidCredits()
            async let spendLimitTask = apiClient.fetchOverageSpendLimit()

            let (credits, spendLimit) = try await (creditsTask, spendLimitTask)
            self.extraUsage = ExtraUsageSummary(credits: credits, spendLimit: spendLimit)
            return
        } catch {
            logger.debug("Detailed extra usage fetch failed: \(error.localizedDescription)")
        }

        // Fall back to inline extra_usage from OAuth usage response
        guard let inline = inlineExtraUsage else { return }
        let fallbackSpendLimit = OverageSpendLimit(
            organizationUuid: "",
            isEnabled: inline.isEnabled,
            monthlyCreditLimit: inline.monthlyLimit ?? 0,
            currency: "usd",
            usedCredits: inline.usedCredits ?? 0,
            outOfCredits: inline.utilization.map { $0 >= 100 } ?? false,
            createdAt: "",
            updatedAt: ""
        )
        self.extraUsage = ExtraUsageSummary(credits: nil, spendLimit: fallbackSpendLimit)
    }

    // MARK: - Data Processing

    private func processUsageResponse(_ response: UsageResponse) -> UsageSummary {
        var items: [UsageItem] = []

        for key in response.orderedKeys {
            guard let period = response.items[key] else { continue }

            let resetsAt = parseDate(period.resetsAt)
            let item = UsageItem(key: key, utilization: period.utilization, resetsAt: resetsAt)
            items.append(item)
        }

        return UsageSummary(items: items, lastUpdated: Date())
    }

    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }

        if let date = Self.isoFormatterWithFractional.date(from: dateString) {
            return date
        }

        if let date = Self.isoFormatterWithoutFractional.date(from: dateString) {
            return date
        }

        logger.warning("Failed to parse date: \(dateString)")
        return nil
    }
}

// MARK: - Cache Model

private struct CachedUsageSummary: Codable {
    let items: [CachedUsageItem]
    let lastUpdated: Date
}

private struct CachedUsageItem: Codable {
    let key: String
    let utilization: Int
    let resetsAt: Date?
}
