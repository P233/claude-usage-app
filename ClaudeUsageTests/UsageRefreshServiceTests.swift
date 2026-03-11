import Foundation
import Combine
import AppKit

// MARK: - Simple Test Framework

/// Lightweight test result tracking - not isolated to MainActor for simplicity
final class TestRunner: @unchecked Sendable {
    static let shared = TestRunner()

    private var passCount = 0
    private var failCount = 0
    private var currentTest = ""
    private let lock = NSLock()

    func startTest(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        currentTest = name
        print("  ▶ \(name)")
    }

    func pass() {
        lock.lock()
        defer { lock.unlock() }
        passCount += 1
        print("    ✓ passed")
    }

    func fail(_ message: String, file: String = #file, line: Int = #line) {
        lock.lock()
        defer { lock.unlock() }
        failCount += 1
        let fileName = (file as NSString).lastPathComponent
        print("    ✗ FAILED: \(message) (\(fileName):\(line))")
    }

    func printSummary() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        print("")
        print("================================================================================")
        print("Results: \(passCount + failCount) tests, \(passCount) passed, \(failCount) failed")
        print("================================================================================")
        return failCount == 0
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected \(b), got \(a)", file: file, line: line)
    }
}

func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected true", file: file, line: line)
    }
}

func assertFalse(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if !condition {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected false", file: file, line: line)
    }
}

func assertNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    if value == nil {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected nil, got \(String(describing: value))", file: file, line: line)
    }
}

func assertNotNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    if value != nil {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected non-nil value", file: file, line: line)
    }
}

func assertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a > b {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected \(a) > \(b)", file: file, line: line)
    }
}

// MARK: - Test Suite

@MainActor
final class UsageRefreshServiceTests {

    var mockAPIClient: MockClaudeAPIClient!
    var mockAuthService: MockAuthenticationService!
    var settings: UserSettings!
    var sut: UsageRefreshService!

    func setUp() async {
        // Clear cached data to prevent cross-test state leaks
        UserDefaults.standard.removeObject(forKey: "cachedUsageSummary_v2")

        mockAPIClient = MockClaudeAPIClient()
        mockAuthService = MockAuthenticationService()
        settings = UserSettings.shared

        // Default: authenticated state
        mockAuthService.setAuthState(.authenticated(
            subscriptionType: SubscriptionType(rawValue: "claude_pro")
        ))

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 50))
    }

    func tearDown() {
        sut?.stopAutoRefresh()
        sut = nil
        mockAPIClient = nil
        mockAuthService = nil
    }

    // MARK: - Helpers

    private func createService() -> UsageRefreshService {
        UsageRefreshService(
            apiClient: mockAPIClient,
            authService: mockAuthService,
            settings: settings
        )
    }

    private func makeUsageResponse(fiveHourUtil: Int, resetsAt: Date? = nil) -> UsageResponse {
        makeUsageResponse(fiveHourUtil: fiveHourUtil, fiveHourResetsAt: resetsAt)
    }

    private func makeUsageResponse(
        fiveHourUtil: Int,
        fiveHourResetsAt: Date? = nil,
        sevenDayUtil: Int? = nil,
        sevenDayResetsAt: Date? = nil
    ) -> UsageResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var items: [String: UsagePeriodResponse] = [
            "five_hour": UsagePeriodResponse(
                utilization: fiveHourUtil,
                resetsAt: fiveHourResetsAt.map { formatter.string(from: $0) }
            )
        ]

        if let sevenDayUtil = sevenDayUtil {
            items["seven_day"] = UsagePeriodResponse(
                utilization: sevenDayUtil,
                resetsAt: sevenDayResetsAt.map { formatter.string(from: $0) }
            )
        }

        return UsageResponse(items: items)
    }

    private func waitForRefresh() async {
        try? await Task.sleep(nanoseconds: 150_000_000)  // 0.15 seconds
    }

    // MARK: - Tests

    func testSleepNotification_StopsAllTimers() async {
        TestRunner.shared.startTest("Sleep notification stops all timers")

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        let countdownBefore = sut.secondsUntilNextRefresh
        assertGreaterThan(countdownBefore, 0, "Auto-refresh should be active before sleep")

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        await waitForRefresh()

        assertEqual(sut.secondsUntilNextRefresh, 0, "Countdown should be 0 after sleep")
    }

    func testWakeNotification_RefreshesAndRestartsTimers() async {
        TestRunner.shared.startTest("Wake notification refreshes and restarts timers")

        sut = createService()
        await waitForRefresh()

        let initialCallCount = mockAPIClient.fetchUsageCallCount

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        await waitForRefresh()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await waitForRefresh()

        assertGreaterThan(mockAPIClient.fetchUsageCallCount, initialCallCount, "Should refresh on wake")
        assertGreaterThan(sut.secondsUntilNextRefresh, 0, "Auto-refresh should restart")
    }

    func testWakeNotification_DoesNotRefreshWhenNotAuthenticated() async {
        TestRunner.shared.startTest("Wake notification does not refresh when not authenticated")

        mockAuthService.setAuthState(.notAuthenticated)
        sut = createService()
        await waitForRefresh()

        mockAPIClient.reset()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await waitForRefresh()

        assertEqual(mockAPIClient.fetchUsageCallCount, 0, "Should not refresh when not authenticated")
    }

    func testStartAutoRefresh_SetsCountdown() async {
        TestRunner.shared.startTest("startAutoRefresh sets countdown")

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()

        let expected = Int(settings.refreshInterval.seconds)
        assertGreaterThan(sut.secondsUntilNextRefresh, 0, "Countdown should be > 0")
        assertTrue(sut.secondsUntilNextRefresh <= expected, "Countdown should be <= interval")
    }

    func testStopAutoRefresh_ClearsCountdown() async {
        TestRunner.shared.startTest("stopAutoRefresh clears countdown")

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        sut.stopAutoRefresh()

        assertEqual(sut.secondsUntilNextRefresh, 0, "Countdown should be 0 after stop")
    }

    func testAutoRefresh_PausesWhenPrimaryAtLimit() async {
        TestRunner.shared.startTest("Auto-refresh pauses when primary at limit")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: Date().addingTimeInterval(3600)
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        assertTrue(sut.secondsUntilNextRefresh > 0, "Countdown should show time until reset")
    }

    func testResetCountdown_ShowsCorrectSecondsUntilReset() async {
        TestRunner.shared.startTest("Reset countdown shows correct seconds until reset")

        let resetTime = Date().addingTimeInterval(7200)
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: resetTime
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        let countdown = sut.secondsUntilNextRefresh
        assertTrue(countdown > 7100 && countdown <= 7200,
                   "Countdown should be ~7200s until reset, got \(countdown)")
    }

    func testResetCountdown_ManualRefreshWhileAtLimit() async {
        TestRunner.shared.startTest("Manual refresh while at limit keeps reset countdown")

        let resetTime = Date().addingTimeInterval(3600)
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: resetTime
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        let countdownBefore = sut.secondsUntilNextRefresh
        assertTrue(countdownBefore > 0, "Should have reset countdown before manual refresh")

        await sut.refreshNow()
        await waitForRefresh()

        let countdownAfter = sut.secondsUntilNextRefresh
        assertTrue(countdownAfter > 3500,
                   "Should count to resetsAt (~1h), not refresh interval, got \(countdownAfter)")
    }

    func testResetCountdown_ClearedByStopAutoRefresh() async {
        TestRunner.shared.startTest("stopAutoRefresh clears reset countdown")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: Date().addingTimeInterval(3600)
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        assertTrue(sut.secondsUntilNextRefresh > 0, "Should have reset countdown")

        sut.stopAutoRefresh()

        assertEqual(sut.secondsUntilNextRefresh, 0, "Countdown should be 0 after stop")
    }

    func testResetCountdown_NonPrimaryExpiredTriggersRefresh() async {
        TestRunner.shared.startTest("Non-primary item expired triggers refresh while paused")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            fiveHourResetsAt: Date().addingTimeInterval(14400),
            sevenDayUtil: 80,
            sevenDayResetsAt: Date().addingTimeInterval(-10)
        ))

        sut = createService()
        await waitForRefresh()

        let callCountBefore = mockAPIClient.fetchUsageCallCount

        sut.startAutoRefresh()
        await waitForRefresh()

        assertGreaterThan(mockAPIClient.fetchUsageCallCount, callCountBefore,
                          "Should trigger refresh when non-primary item expires")
    }

    func testResetCountdown_SleepWakeWhileAtLimit() async {
        TestRunner.shared.startTest("Sleep/wake while at limit restores reset countdown")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: Date().addingTimeInterval(3600)
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        assertTrue(sut.secondsUntilNextRefresh > 0, "Should have reset countdown before sleep")

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        await waitForRefresh()

        assertEqual(sut.secondsUntilNextRefresh, 0, "Countdown should be 0 during sleep")

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await waitForRefresh()

        assertTrue(sut.secondsUntilNextRefresh > 3500,
                   "Should restore reset countdown (~1h), got \(sut.secondsUntilNextRefresh)")
    }

    func testResetCountdown_RecoveryFromLimitResumesAutoRefresh() async {
        TestRunner.shared.startTest("Recovery from 100% resumes normal auto-refresh")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: Date().addingTimeInterval(3600)
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        assertTrue(sut.secondsUntilNextRefresh > 3500,
                   "Should be counting to resetsAt, got \(sut.secondsUntilNextRefresh)")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 0))

        await sut.refreshNow()
        await waitForRefresh()

        assertEqual(sut.usageSummary?.primaryItem?.utilization, 0, "Utilization should be 0 after reset")

        sut.startAutoRefresh()
        await waitForRefresh()

        let countdown = sut.secondsUntilNextRefresh
        let maxExpected = Int(settings.refreshInterval.seconds)
        assertTrue(countdown > 0 && countdown <= maxExpected,
                   "Should be normal auto-refresh countdown (1-\(maxExpected)s), got \(countdown)")
    }

    func testScheduleResumeRefresh_PastResetTimeResumesAutoRefresh() async {
        TestRunner.shared.startTest("Past reset time triggers immediate refresh and resumes auto-refresh")

        // Simulate app launching with cached at-limit data whose reset time has already passed.
        // Before the fix: scheduleResumeRefresh(interval <= 0) called refreshNow() but not
        // startAutoRefresh(), leaving no auto-refresh timer after the immediate refresh completed.
        let nearFutureReset = Date().addingTimeInterval(0.2) // 200ms from now
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: nearFutureReset
        ))

        sut = createService()
        await waitForRefresh()  // Initial refresh: at-limit, resumeRefreshTimer set for ~5.2s

        // Wait for the reset time to pass
        try? await Task.sleep(nanoseconds: 400_000_000)  // 400ms

        // Now usageSummary.isPrimaryAtLimit == true but primaryResetsAt is in the past.
        // Return non-limit data on the next fetch.
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 30))

        // startAutoRefresh() sees at-limit with past resetsAt →
        // scheduleResumeRefresh(interval <= 0) → Task { refreshNow(); startAutoRefresh() }
        sut.startAutoRefresh()
        await waitForRefresh()
        await waitForRefresh()  // Extra buffer for the immediate refresh + startAutoRefresh to settle

        let countdown = sut.secondsUntilNextRefresh
        let maxExpected = Int(settings.refreshInterval.seconds)
        assertTrue(countdown > 0 && countdown <= maxExpected,
                   "Should resume normal auto-refresh countdown after past reset, got \(countdown)")
    }

    func testResetDetection_UtilizationUpdates() async {
        TestRunner.shared.startTest("Reset detection updates utilization")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 50))
        sut = createService()
        await waitForRefresh()

        assertEqual(sut.usageSummary?.primaryItem?.utilization, 50, "Initial utilization should be 50")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 0))
        await sut.refreshNow()
        await waitForRefresh()

        assertEqual(sut.usageSummary?.primaryItem?.utilization, 0, "Utilization should update to 0")
    }

    func testAuthStateChange_ClearsDataOnDisconnect() async {
        TestRunner.shared.startTest("Auth state change clears data on disconnect")

        sut = createService()
        await waitForRefresh()

        assertNotNil(sut.usageSummary, "Should have data when authenticated")

        mockAuthService.setAuthState(.notAuthenticated)
        await waitForRefresh()

        assertNil(sut.usageSummary, "Should clear data on disconnect")
    }

    func testRefresh_SetsErrorOnAPIFailure() async {
        TestRunner.shared.startTest("Refresh sets error on API failure")

        mockAPIClient.fetchUsageResult = .failure(NSError(domain: "test", code: -1))
        sut = createService()
        await waitForRefresh()

        assertNotNil(sut.lastError, "Should set error on failure")
    }

    func testRefresh_ClearsErrorOnSuccess() async {
        TestRunner.shared.startTest("Refresh clears error on success")

        sut = createService()
        await waitForRefresh()

        assertNil(sut.lastError, "Should have no error after successful refresh")
        assertNotNil(sut.usageSummary, "Should have usage data")
    }

    func testRefresh_SkipsWhenAlreadyRefreshing() async {
        TestRunner.shared.startTest("Refresh skips when already refreshing")

        sut = createService()
        await waitForRefresh()
        await waitForRefresh()

        mockAPIClient.fetchUsageDelay = 0.5
        mockAPIClient.reset()

        // Use separate Tasks to allow actual concurrent scheduling on @MainActor
        let t1 = Task { @MainActor in await sut.refreshNow() }
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms — enough for isRefreshing = true
        let t2 = Task { @MainActor in await sut.refreshNow() }
        let t3 = Task { @MainActor in await sut.refreshNow() }

        await t1.value
        await t2.value
        await t3.value

        assertEqual(mockAPIClient.fetchUsageCallCount, 1, "Should only make one API call")
    }

    // MARK: - Run All Tests

    func runAll() async {
        print("\n📋 Running UsageRefreshService Tests\n")

        await setUp()
        await testSleepNotification_StopsAllTimers()
        tearDown()

        await setUp()
        await testWakeNotification_RefreshesAndRestartsTimers()
        tearDown()

        await setUp()
        await testWakeNotification_DoesNotRefreshWhenNotAuthenticated()
        tearDown()

        await setUp()
        await testStartAutoRefresh_SetsCountdown()
        tearDown()

        await setUp()
        await testStopAutoRefresh_ClearsCountdown()
        tearDown()

        await setUp()
        await testAutoRefresh_PausesWhenPrimaryAtLimit()
        tearDown()

        await setUp()
        await testResetCountdown_ShowsCorrectSecondsUntilReset()
        tearDown()

        await setUp()
        await testResetCountdown_ManualRefreshWhileAtLimit()
        tearDown()

        await setUp()
        await testResetCountdown_ClearedByStopAutoRefresh()
        tearDown()

        await setUp()
        await testResetCountdown_NonPrimaryExpiredTriggersRefresh()
        tearDown()

        await setUp()
        await testResetCountdown_SleepWakeWhileAtLimit()
        tearDown()

        await setUp()
        await testResetCountdown_RecoveryFromLimitResumesAutoRefresh()
        tearDown()

        await setUp()
        await testScheduleResumeRefresh_PastResetTimeResumesAutoRefresh()
        tearDown()

        await setUp()
        await testResetDetection_UtilizationUpdates()
        tearDown()

        await setUp()
        await testAuthStateChange_ClearsDataOnDisconnect()
        tearDown()

        await setUp()
        await testRefresh_SetsErrorOnAPIFailure()
        tearDown()

        await setUp()
        await testRefresh_ClearsErrorOnSuccess()
        tearDown()

        await setUp()
        await testRefresh_SkipsWhenAlreadyRefreshing()
        tearDown()
    }
}

// MARK: - UsageResponse Decoding Tests

final class UsageResponseDecodingTests {

    func testDecodes_SinglePeriod() {
        TestRunner.shared.startTest("Decodes single usage period")

        let json = """
        {"five_hour": {"utilization": 42, "resets_at": "2025-06-01T12:00:00Z"}}
        """.data(using: .utf8)!

        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: json) else {
            TestRunner.shared.fail("Failed to decode")
            return
        }

        assertEqual(response.items.count, 1, "Should have 1 item")
        assertEqual(response.items["five_hour"]?.utilization, 42, "Utilization should be 42")
        assertEqual(response.items["five_hour"]?.resetsAt, "2025-06-01T12:00:00Z", "Should preserve resetsAt")
        assertNil(response.extraUsage, "Should have no extra usage")
    }

    func testDecodes_MultiplePeriods() {
        TestRunner.shared.startTest("Decodes multiple usage periods")

        let json = """
        {
            "five_hour": {"utilization": 80, "resets_at": null},
            "seven_day": {"utilization": 30, "resets_at": "2025-06-07T00:00:00Z"},
            "seven_day_opus": {"utilization": 10, "resets_at": "2025-06-07T00:00:00Z"}
        }
        """.data(using: .utf8)!

        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: json) else {
            TestRunner.shared.fail("Failed to decode")
            return
        }

        assertEqual(response.items.count, 3, "Should have 3 items")
        assertNil(response.items["five_hour"]?.resetsAt, "five_hour resetsAt should be nil")
    }

    func testOrderedKeys_Priority() {
        TestRunner.shared.startTest("orderedKeys follows priority: five_hour → seven_day → variants → others")

        let json = """
        {
            "seven_day_opus": {"utilization": 10, "resets_at": null},
            "custom_period": {"utilization": 5, "resets_at": null},
            "five_hour": {"utilization": 80, "resets_at": null},
            "seven_day": {"utilization": 30, "resets_at": null}
        }
        """.data(using: .utf8)!

        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: json) else {
            TestRunner.shared.fail("Failed to decode")
            return
        }

        let keys = response.orderedKeys
        assertEqual(keys[0], "five_hour", "First key should be five_hour")
        assertEqual(keys[1], "seven_day", "Second key should be seven_day")
        assertEqual(keys[2], "seven_day_opus", "Third key should be seven_day_opus")
        assertEqual(keys[3], "custom_period", "Fourth key should be custom_period")
    }

    func testDecodes_WithExtraUsage() {
        TestRunner.shared.startTest("Decodes extra_usage inline data")

        let json = """
        {
            "five_hour": {"utilization": 50, "resets_at": null},
            "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1200, "utilization": 24.0}
        }
        """.data(using: .utf8)!

        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: json) else {
            TestRunner.shared.fail("Failed to decode")
            return
        }

        assertEqual(response.items.count, 1, "extra_usage should not appear in items")
        assertNotNil(response.extraUsage, "Should have extra usage")
        assertTrue(response.extraUsage?.isEnabled == true, "Extra usage should be enabled")
        assertEqual(response.extraUsage?.monthlyLimit, 5000, "Monthly limit should be 5000")
        assertEqual(response.extraUsage?.usedCredits, 1200, "Used credits should be 1200")
    }

    func testDecodes_IgnoresUnknownFields() {
        TestRunner.shared.startTest("Ignores fields that don't match UsagePeriodResponse")

        let json = """
        {
            "five_hour": {"utilization": 50, "resets_at": null},
            "unknown_field": "some string value"
        }
        """.data(using: .utf8)!

        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: json) else {
            TestRunner.shared.fail("Failed to decode")
            return
        }

        assertEqual(response.items.count, 1, "Should only have 1 valid item")
        assertNotNil(response.items["five_hour"], "five_hour should be present")
    }

    func runAll() {
        print("\n📋 Running UsageResponse Decoding Tests\n")

        testDecodes_SinglePeriod()
        testDecodes_MultiplePeriods()
        testOrderedKeys_Priority()
        testDecodes_WithExtraUsage()
        testDecodes_IgnoresUnknownFields()
    }
}

// MARK: - Test Entry Point

@main
struct TestMain {
    static var testsComplete = false
    static var testSuccess = false

    static func main() {
        Task { @MainActor in
            // Run decoding tests first (no async needed)
            UsageResponseDecodingTests().runAll()

            // Run service tests
            let tests = UsageRefreshServiceTests()
            await tests.runAll()

            testSuccess = TestRunner.shared.printSummary()
            testsComplete = true
        }

        while !testsComplete {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        exit(testSuccess ? 0 : 1)
    }
}
