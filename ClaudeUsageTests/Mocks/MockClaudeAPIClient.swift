import Foundation

/// Mock API client for testing UsageRefreshService
@MainActor
final class MockClaudeAPIClient: ClaudeAPIClientProtocol {

    // MARK: - Configurable Behavior

    var fetchUsageResult: Result<UsageResponse, Error> = .success(UsageResponse(items: [:]))

    // MARK: - Call Tracking

    private(set) var fetchUsageCallCount = 0

    // MARK: - Artificial Delay

    var fetchUsageDelay: TimeInterval = 0

    // MARK: - ClaudeAPIClientProtocol

    func fetchUsage() async throws -> UsageResponse {
        fetchUsageCallCount += 1

        if fetchUsageDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(fetchUsageDelay * 1_000_000_000))
        }

        return try fetchUsageResult.get()
    }

    func fetchPrepaidCredits() async throws -> PrepaidCredits {
        throw MockError.notConfigured
    }

    func fetchOverageSpendLimit() async throws -> OverageSpendLimit {
        throw MockError.notConfigured
    }

    func updateExtraUsage(enabled: Bool) async throws {
        throw MockError.notConfigured
    }

    func fetchProfile() async throws -> ProfileResponse {
        throw MockError.notConfigured
    }

    // MARK: - Test Helpers

    func reset() {
        fetchUsageCallCount = 0
    }

    enum MockError: Error {
        case notConfigured
    }
}
