import Foundation
import Security
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "OAuthTokenService")

// MARK: - Protocol

protocol OAuthTokenServiceProtocol {
    /// Attempt to load OAuth credentials from Claude Code CLI's Keychain entry.
    /// Returns nil if Claude Code is not installed or has no stored credentials.
    func loadClaudeCodeCredentials() -> ClaudeCodeCredentials?
}

// MARK: - Implementation

final class OAuthTokenService: OAuthTokenServiceProtocol {

    // MARK: - Keychain Reading

    func loadClaudeCodeCredentials() -> ClaudeCodeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.OAuth.claudeCodeKeychainService,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            logger.debug("No Claude Code credentials found in Keychain")
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            logger.error("Failed to read Claude Code Keychain entry: \(status)")
            return nil
        }

        do {
            let credentials = try JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
            logger.info("Successfully loaded Claude Code credentials")
            return credentials
        } catch {
            logger.error("Failed to decode Claude Code credentials: \(error.localizedDescription)")
            return nil
        }
    }
}
