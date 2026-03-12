import Foundation
import Combine
import SwiftUI
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "AppViewModel")

@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var authState: AuthState = .unknown
    @Published var usageSummary: UsageSummary?
    @Published var extraUsage: ExtraUsageSummary?
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var secondsUntilNextRefresh: Int = 0
    @Published var activeTaskCount: Int?

    // MARK: - Services

    let authService: AuthenticationServiceProtocol
    let apiClient: ClaudeAPIClientProtocol
    let refreshService: UsageRefreshServiceProtocol
    var settings: UserSettings
    let activeTasksService = ActiveTasksService()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    var menuBarTitle: String {
        guard let usage = usageSummary?.primaryItem else {
            return "–"
        }
        return "\(usage.utilization)%"
    }

    var statusColor: Color {
        guard let usage = usageSummary?.primaryItem else {
            return .secondary
        }
        return usage.statusLevel.color
    }

    var isExtraUsageEnabled: Bool {
        extraUsage?.spendLimit?.isEnabled ?? false
    }

    /// Whether the primary usage is at limit (paused auto-refresh)
    var isPrimaryAtLimit: Bool {
        usageSummary?.isPrimaryAtLimit ?? false
    }

    // MARK: - Initialization

    convenience init() {
        let settings = UserSettings.shared
        let authService = AuthenticationService()
        let apiClient = ClaudeAPIClient(authService: authService)
        let refreshService = UsageRefreshService(
            apiClient: apiClient,
            authService: authService,
            settings: settings
        )

        self.init(
            authService: authService,
            apiClient: apiClient,
            refreshService: refreshService,
            settings: settings
        )
    }

    init(
        authService: AuthenticationServiceProtocol,
        apiClient: ClaudeAPIClientProtocol,
        refreshService: UsageRefreshServiceProtocol,
        settings: UserSettings
    ) {
        self.authService = authService
        self.apiClient = apiClient
        self.refreshService = refreshService
        self.settings = settings

        setupBindings()
        logger.debug("AppViewModel initialized")

        Task { [weak self] in
            await self?.checkCredentialsOnLaunch()
        }
    }

    private func checkCredentialsOnLaunch() async {
        logger.debug("App launched, checking stored credentials")
        await authService.checkStoredCredentials()
    }

    private func setupBindings() {
        authService.authStatePublisher.assign(to: &$authState)
        refreshService.usageSummaryPublisher.assign(to: &$usageSummary)
        refreshService.extraUsagePublisher.assign(to: &$extraUsage)
        refreshService.isRefreshingPublisher.assign(to: &$isRefreshing)
        refreshService.lastErrorPublisher.assign(to: &$lastError)
        refreshService.secondsUntilNextRefreshPublisher.assign(to: &$secondsUntilNextRefresh)

        activeTasksService.$activeTaskCount.assign(to: &$activeTaskCount)
        activeTasksService.start()
    }

    // MARK: - Actions

    func reconnect() async {
        logger.info("Retrying credential check")
        await authService.checkStoredCredentials()
    }

    func refreshUsage() async {
        await refreshService.refreshNow()
        activeTasksService.checkAndActivate()
    }

    func toggleExtraUsage(enabled: Bool) async throws {
        logger.info("Toggling extra usage to: \(enabled)")
        try await apiClient.updateExtraUsage(enabled: enabled)
        await refreshService.refreshNow()
    }

    func quit() {
        logger.info("App quitting")
        NSApplication.shared.terminate(nil)
    }
}
