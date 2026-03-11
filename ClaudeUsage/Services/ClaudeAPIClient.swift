import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "ClaudeAPIClient")

protocol ClaudeAPIClientProtocol {
    func fetchUsage() async throws -> UsageResponse
    func fetchPrepaidCredits() async throws -> PrepaidCredits
    func fetchOverageSpendLimit() async throws -> OverageSpendLimit
    func updateExtraUsage(enabled: Bool) async throws
}

final class ClaudeAPIClient: ClaudeAPIClientProtocol {

    enum APIError: Error, LocalizedError {
        case notAuthenticated
        case invalidURL
        case invalidResponse
        case httpError(statusCode: Int)
        case sessionExpired
        case tokenExpired
        case decodingError(Error)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not authenticated. Please log in."
            case .invalidURL:
                return "Invalid URL"
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let statusCode):
                return "HTTP error: \(statusCode)"
            case .sessionExpired:
                return "Session expired. Please log in again."
            case .tokenExpired:
                return "Token expired, waiting for refresh..."
            case .decodingError(let error):
                return "Failed to parse response: \(error.localizedDescription)"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }

        /// Errors that should NOT be retried with exponential backoff.
        /// - Auth errors: session permanently invalid, requires re-login
        /// - Token expired: transient, will resolve when Claude Code refreshes; auto-refresh timer handles it
        var shouldSkipRetry: Bool {
            switch self {
            case .notAuthenticated, .sessionExpired, .tokenExpired:
                return true
            default:
                return false
            }
        }
    }

    private let authService: AuthenticationServiceProtocol
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(authService: AuthenticationServiceProtocol) {
        self.authService = authService

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Constants.API.requestTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Request Building

    private func makeOAuthRequest(for endpoint: String, method: String = "GET") async throws -> URLRequest {
        let accessToken = try await authService.getAccessToken()

        let url = Constants.OAuth.apiBaseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ClaudeCodeVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Constants.OAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        return request
    }

    // MARK: - Response Handling

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let statusCode = httpResponse.statusCode

        if statusCode == 401 || statusCode == 403 {
            throw APIError.sessionExpired
        }

        guard (200...299).contains(statusCode) else {
            logger.error("HTTP error: \(statusCode)")
            throw APIError.httpError(statusCode: statusCode)
        }
    }

    /// Core request method: sends request, handles 401 retry with fresh token, maps errors.
    private func performDataRequest(_ request: URLRequest) async throws -> Data {
        logger.debug("Request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")

        do {
            let (data, response) = try await session.data(for: request)
            try validateResponse(response)
            return data

        } catch APIError.sessionExpired {
            return try await retryWithFreshToken(request)

        } catch let error as APIError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw APIError.networkError(error)
        }
    }

    // MARK: - 401 Retry

    /// Retries a request once with a fresh Keychain token. If still 401/403, marks session expired.
    private func retryWithFreshToken(_ original: URLRequest) async throws -> Data {
        logger.info("401 received, retrying with fresh Keychain token")

        do {
            let freshToken = try await authService.refreshAndGetAccessToken()
            var request = original
            request.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            try validateResponse(response)
            return data
        } catch APIError.sessionExpired {
            logger.warning("Retry still returned 401/403, session truly expired")
            await MainActor.run { authService.handleSessionExpired() }
            throw APIError.sessionExpired
        } catch APIError.tokenExpired, APIError.notAuthenticated {
            logger.warning("Cannot obtain fresh token for retry, marking session expired")
            await MainActor.run { authService.handleSessionExpired() }
            throw APIError.sessionExpired
        }
    }

    // MARK: - API Methods

    func fetchUsage() async throws -> UsageResponse {
        let request = try await makeOAuthRequest(for: "usage")
        let data = try await performDataRequest(request)
        do {
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func fetchPrepaidCredits() async throws -> PrepaidCredits {
        let request = try await makeOAuthRequest(for: "prepaid/credits")
        let data = try await performDataRequest(request)
        do {
            return try decoder.decode(PrepaidCredits.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func fetchOverageSpendLimit() async throws -> OverageSpendLimit {
        let request = try await makeOAuthRequest(for: "overage_spend_limit")
        let data = try await performDataRequest(request)
        do {
            return try decoder.decode(OverageSpendLimit.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func updateExtraUsage(enabled: Bool) async throws {
        var request = try await makeOAuthRequest(for: "overage_spend_limit", method: "PUT")
        request.httpBody = try JSONEncoder().encode(UpdateOverageSpendLimitRequest(isEnabled: enabled))
        _ = try await performDataRequest(request)
        logger.info("Extra usage updated: \(enabled)")
    }
}
