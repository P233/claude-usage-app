import Foundation
import Security
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "AccountManager")

// MARK: - Account Info

struct AccountInfo: Codable, Identifiable, Equatable {
    let id: String
    let organizationUuid: String
    let subscriptionType: SubscriptionType
    var label: String
    let addedAt: Date

    var displayName: String {
        if !label.isEmpty { return label }
        return subscriptionType.displayName ?? "Account"
    }
}

// MARK: - Account Manager

@MainActor
final class AccountManager: ObservableObject {

    @Published private(set) var accounts: [AccountInfo] = []
    @Published var activeAccountId: String? {
        didSet {
            UserDefaults.standard.set(activeAccountId, forKey: activeAccountIdKey)
        }
    }

    private let accountsKey = "storedAccounts_v1"
    private let activeAccountIdKey = "activeAccountId"
    private let keychainServiceName = "com.claudeusage.app.accounts"

    var activeAccount: AccountInfo? {
        accounts.first { $0.id == activeAccountId }
    }

    /// The organizationUuid of the account currently logged into Claude Code CLI
    private(set) var claudeCodeOrgUuid: String?

    init() {
        loadAccounts()
    }

    // MARK: - Sync from Claude Code

    /// Called when reading from Claude Code's Keychain.
    /// Saves/updates the account and returns the AccountInfo.
    @discardableResult
    func syncFromClaudeCode(
        credentials: ClaudeCodeCredentials,
        subscriptionType: SubscriptionType
    ) -> AccountInfo? {
        guard let orgUuid = credentials.organizationUuid else { return nil }
        claudeCodeOrgUuid = orgUuid

        // Check if account already exists
        if let existingIndex = accounts.firstIndex(where: { $0.organizationUuid == orgUuid }) {
            var account = accounts[existingIndex]

            // Update subscription type if changed
            if account.subscriptionType != subscriptionType {
                account = AccountInfo(
                    id: account.id,
                    organizationUuid: orgUuid,
                    subscriptionType: subscriptionType,
                    label: account.label,
                    addedAt: account.addedAt
                )
                accounts[existingIndex] = account
            }

            // Update stored credentials
            saveCredentialsToKeychain(credentials, accountId: account.id)

            // Set as active if no active account
            if activeAccountId == nil {
                activeAccountId = account.id
            }

            saveAccounts()
            return account
        }

        // Create new account
        let id = UUID().uuidString
        let tierName = subscriptionType.displayName ?? "Account"
        let accountNumber = accounts.count + 1
        let label = accounts.isEmpty ? tierName : "\(tierName) \(accountNumber)"

        let account = AccountInfo(
            id: id,
            organizationUuid: orgUuid,
            subscriptionType: subscriptionType,
            label: label,
            addedAt: Date()
        )

        accounts.append(account)
        saveCredentialsToKeychain(credentials, accountId: id)

        if activeAccountId == nil {
            activeAccountId = id
        }

        saveAccounts()
        logger.info("Added new account: \(label)")
        return account
    }

    func removeAccount(_ id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts[index]

        deleteCredentialsFromKeychain(accountId: account.id)
        accounts.remove(at: index)

        if activeAccountId == id {
            activeAccountId = accounts.first?.id
        }

        saveAccounts()
        logger.info("Removed account: \(account.displayName)")
    }

    func loadCredentials(for accountId: String) -> ClaudeCodeCredentials? {
        loadCredentialsFromKeychain(accountId: accountId)
    }

    /// Whether the given account is the one currently logged into Claude Code CLI
    func isClaudeCodeAccount(_ accountId: String) -> Bool {
        guard let account = accounts.first(where: { $0.id == accountId }),
              let ccOrgUuid = claudeCodeOrgUuid else { return false }
        return account.organizationUuid == ccOrgUuid
    }

    // MARK: - Persistence (Account List)

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else { return }
        do {
            accounts = try JSONDecoder().decode([AccountInfo].self, from: data)
            activeAccountId = UserDefaults.standard.string(forKey: activeAccountIdKey) ?? accounts.first?.id
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription)")
        }
    }

    private func saveAccounts() {
        do {
            let data = try JSONEncoder().encode(accounts)
            UserDefaults.standard.set(data, forKey: accountsKey)
        } catch {
            logger.error("Failed to save accounts: \(error.localizedDescription)")
        }
    }

    // MARK: - Keychain Storage (Per-Account Credentials)

    private func saveCredentialsToKeychain(_ credentials: ClaudeCodeCredentials, accountId: String) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadCredentialsFromKeychain(accountId: String) -> ClaudeCodeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
    }

    private func deleteCredentialsFromKeychain(accountId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(query as CFDictionary)
    }
}
