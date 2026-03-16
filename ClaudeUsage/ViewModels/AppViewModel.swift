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
    let accountManager = AccountManager()

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

        // Always read from Claude Code Keychain first to sync accounts
        await syncClaudeCodeAccount()

        // If the active account is the Claude Code account (or no accounts), use Keychain directly
        if let activeId = accountManager.activeAccountId,
           !accountManager.isClaudeCodeAccount(activeId) {
            // Active account is a stored (non-Claude-Code) account — load its tokens
            await loadStoredAccount(activeId)
        } else {
            // Active account is Claude Code's current account — use Keychain directly
            await authService.checkStoredCredentials()
        }
    }

    /// Read from Claude Code Keychain and save/update the account in AccountManager
    private func syncClaudeCodeAccount() async {
        let tokenService = OAuthTokenService()
        guard let credentials = await tokenService.loadClaudeCodeCredentials(),
              let tokens = credentials.claudeAiOauth else { return }

        let subType = SubscriptionType.from(oauthSubscriptionType: tokens.subscriptionType)
        let subscriptionType = subType.rawValue != nil
            ? subType
            : SubscriptionType.from(rateLimitTier: tokens.rateLimitTier)

        accountManager.syncFromClaudeCode(credentials: credentials, subscriptionType: subscriptionType)
    }

    /// Load a stored account's credentials and set override on AuthService
    private func loadStoredAccount(_ accountId: String) async {
        guard let account = accountManager.accounts.first(where: { $0.id == accountId }),
              let credentials = accountManager.loadCredentials(for: accountId),
              let tokens = credentials.claudeAiOauth else {
            // Stored credentials invalid, fall back to Claude Code
            logger.warning("Stored account credentials invalid, falling back to Claude Code")
            accountManager.activeAccountId = accountManager.accounts.first(where: {
                accountManager.isClaudeCodeAccount($0.id)
            })?.id ?? accountManager.accounts.first?.id
            await authService.checkStoredCredentials()
            return
        }

        authService.setOverrideTokens(tokens, subscriptionType: account.subscriptionType)
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
        // Re-sync from Claude Code and check credentials
        await syncClaudeCodeAccount()
        if let activeId = accountManager.activeAccountId,
           !accountManager.isClaudeCodeAccount(activeId) {
            await loadStoredAccount(activeId)
        } else {
            await authService.checkStoredCredentials()
        }
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

    // MARK: - Multi-Account

    func switchAccount(to accountId: String) async {
        guard accountId != accountManager.activeAccountId else { return }
        logger.info("Switching to account: \(accountId)")

        // Stop current refresh
        refreshService.stopAutoRefresh()

        // Clear current state
        usageSummary = nil
        extraUsage = nil
        lastError = nil

        // Set as active
        accountManager.activeAccountId = accountId

        if accountManager.isClaudeCodeAccount(accountId) {
            // This is Claude Code's current account — clear override, use Keychain directly
            await authService.clearOverride()
        } else {
            // Stored account — load override tokens
            await loadStoredAccount(accountId)
        }
    }

    func removeCurrentAccount() async {
        guard let activeId = accountManager.activeAccountId else { return }
        logger.info("Removing current account")

        refreshService.stopAutoRefresh()
        accountManager.removeAccount(activeId)

        // Switch to next available account
        if let nextId = accountManager.activeAccountId {
            await switchAccount(to: nextId)
        } else {
            await authService.clearOverride()
        }
    }
}
