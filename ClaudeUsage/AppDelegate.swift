import SwiftUI
import AppKit
import Combine

/// Custom AppDelegate to manage NSStatusItem for multi-line menubar display
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// Reusable hosting view for status bar content (prevents memory leaks)
    private var statusBarHostingView: NSHostingView<StatusBarContentView>?

    /// Shared view model accessible throughout the app
    let viewModel = AppViewModel()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy for menubar-only app
        NSApplication.shared.setActivationPolicy(.accessory)

        // Eagerly detect Claude Code version off the cooperative thread pool
        // (Process.waitUntilExit() is blocking and must not run on async threads)
        Task.detached(priority: .utility) { _ = ClaudeCodeVersion.userAgent }

        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        observeViewModelChanges()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.action = #selector(togglePopover)
        button.target = self

        updateStatusBarContent()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: Constants.UI.menuBarWidth, height: 500)
        popover?.behavior = .transient
        popover?.animates = true
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.popover?.performClose(nil)
            }
        }
    }

    private func observeViewModelChanges() {
        Publishers.CombineLatest3(
            viewModel.$usageSummary,
            viewModel.$authState,
            viewModel.$isRefreshing
        )
        .sink { [weak self] _ in
            self?.updateStatusBarContent()
        }
        .store(in: &cancellables)

        viewModel.$secondsUntilNextRefresh
            .removeDuplicates()
            .throttle(for: .seconds(30), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.updateStatusBarContent()
            }
            .store(in: &cancellables)
    }

    // MARK: - Status Bar Content

    private func updateStatusBarContent() {
        guard let button = statusItem?.button else { return }

        if statusBarHostingView == nil {
            let hostingView = NSHostingView(rootView: StatusBarContentView(viewModel: viewModel))
            statusBarHostingView = hostingView
            button.addSubview(hostingView)
        }

        guard let hostingView = statusBarHostingView else { return }

        hostingView.invalidateIntrinsicContentSize()
        let fittingSize = hostingView.fittingSize
        let width = max(Constants.UI.statusBarMinWidth, fittingSize.width + Constants.UI.statusBarPadding)
        let height = Constants.UI.statusBarHeight

        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        button.frame = NSRect(x: 0, y: 0, width: width, height: height)
        statusItem?.length = width
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        } else {
            let contentView = MenuBarView().environmentObject(viewModel)
            popover?.contentViewController = NSHostingController(rootView: contentView)
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

// MARK: - Status Bar Content View

/// SwiftUI view for the menubar status item (supports two lines)
struct StatusBarContentView: View {
    @ObservedObject var viewModel: AppViewModel

    /// Default remaining time when resetting (5-hour cycle)
    private static let defaultRemaining = "5h"

    private static let claudeOrange = Color(
        red: Constants.Colors.claudeOrange.red,
        green: Constants.Colors.claudeOrange.green,
        blue: Constants.Colors.claudeOrange.blue
    )

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "brain")
                .font(.system(size: 13))

            if viewModel.authState.isAuthenticated {
                if let primary = viewModel.usageSummary?.primaryItem {
                    VStack(alignment: .leading, spacing: -3) {
                        HStack(alignment: .center, spacing: 3) {
                            Text("\(primary.utilization)%")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .fixedSize()

                            Circle()
                                .fill(viewModel.statusColor)
                                .frame(width: 6, height: 6)
                        }

                        Text(primary.resetTimeRemaining ?? Self.defaultRemaining)
                            .font(.system(size: 8, weight: .regular, design: .rounded))
                            .opacity(0.8)
                            .fixedSize()
                    }
                } else if viewModel.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                }
            }

            if let count = viewModel.activeTaskCount {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(height: 18)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Self.claudeOrange)
                    )
                    .opacity(count > 0 ? 1.0 : 0.5)
                    .fixedSize()
            }
        }
        .frame(height: 22)
    }
}
