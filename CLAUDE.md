# Claude Usage - Project Guidelines

## Project Overview

A macOS menubar application that displays Claude.ai usage statistics in real-time. Built with Swift 5.9 and SwiftUI, targeting macOS 13.0+.

**Tech Stack**: Swift async/await + Combine, SwiftUI + AppKit (NSStatusItem), OAuth + Keychain, URLSession, os.log. No external dependencies.

## Core Features

### 1. Authentication (OAuth via Claude Code CLI)

- Reads OAuth credentials from Claude Code's macOS Keychain (`"Claude Code-credentials"` service)
- **Read-only consumer**: never writes to Keychain, never refreshes tokens (avoids invalidating Claude Code's refresh token via server-side rotation)
- Token expired → re-read from Keychain on next refresh cycle (Claude Code handles refresh)
- Session expiry (401/403): Clear cached auth, show "No Credentials Found" UI with Retry button

### 2. Usage Data Fetching

- **API Endpoint**: `GET https://api.anthropic.com/api/oauth/usage` with Bearer token + `anthropic-beta` header
- **Polling**: Auto-refresh at configurable intervals (1, 3, 5, 10 minutes)
- **Dynamic Response Parsing**: API returns varying keys (`five_hour`, `seven_day`, `seven_day_opus`, etc.)
- **Priority Ordering**: `five_hour` → `seven_day` → `seven_day_*` variants → others (alphabetically)
- **Data Model**: Each item has `utilization` (0-100+) and `resetsAt` (ISO timestamp)

### 3. Menubar Display

- **Status Item**: Multi-line text showing primary usage percentage and reset time
- **Color Coding**: Green (< 80%), Orange (80-99%), Red (≥ 100%)
- **Active Task Badge**: Orange rounded badge showing running Claude Code task count (requires claude-code-switcher); `StatusBarContentView` uses `@ObservedObject` for reactive updates
- **Popover Menu**: Header with tier badge, usage cards (full-width primary, 2-column grid for others), refresh countdown/button

### 4. Reset Time Management

- **Display Formats**: Short `"14:30 · in 2h 30m"`, Long `"Jan 5 · in 3d 5h"`, At limit `"until 14:30"`, Null `"Ready"`
- **Auto-Refresh Pause**: When primary reaches 100%, pause API polling
- **Reset Detection**: When utilization drops to 0, play notification sound (if enabled)

### 5. Extra Usage

- Comes inline in the OAuth usage response (`extra_usage` field)
- Read-only display: enabled/disabled status, spending amount, progress bar
- "Manage in Browser" link to `claude.ai/settings/usage`

### 6. Settings

- Auto Refresh Interval, Reset Sound selector, Quit

## Architecture

**MVVM Pattern** with protocol-based services:

```
Views (SwiftUI) → ViewModel (AppViewModel) → Services → API
```

### Service Dependencies

```
UserSettings.shared (singleton)
       ↓
OAuthTokenService (reads Claude Code Keychain, read-only)
       ↓
AuthenticationService (owns OAuthTokenService)
       ↓
ClaudeAPIClient (depends on AuthenticationServiceProtocol for tokens)
       ↓
UsageRefreshService (depends on APIClient, AuthService, Settings)
       ↓
AppViewModel (coordinates all above, exposes @Published properties)
       ↑
ActiveTasksService (FSEvents on /tmp/cc-status/, reads ~/.claude/ide/*.lock, optional; checkAndActivate() on each refresh; limitation: standalone file sessions may not be counted when IDE locks exist)
```

### AuthState Machine

```
                    ┌─────────────┐
     App Launch ───▶│   unknown   │
                    └──────┬──────┘
                           │ checkStoredCredentials()
           ┌───────────────┴───────────────┐
           ▼                               ▼
    ┌─────────────┐                ┌────────────────┐
    │authenticated│                │notAuthenticated│
    │   (tier)    │                │  (Retry btn)   │
    └──────┬──────┘                └───────┬────────┘
           │  handleSessionExpired()       │ reconnect()
           └──────────▶ ◀─────────────────┘
```

### Edge Cases & Error Handling

- **Network Disconnected**: Skip API call, set `lastError`, retry on next timer tick
- **Token Expired**: Re-read Keychain; if still expired, retry with backoff (transient error, timers keep running)
- **Session Expired (401/403)**: Set `authState = .notAuthenticated`, show "No Credentials Found" with Retry
- **API Errors**: Max 3 retries with exponential backoff (30s, 60s, 120s); `retryCount` resets each scheduled cycle
- **Cache**: `cachedUsageSummary_v2` in UserDefaults, max age 1 hour, cleared on auth state change
- **System Sleep/Wake**: Stop all timers on sleep (prevents Power Nap API calls/sounds); refresh + restart on wake

**Primary Usage at Limit (100%)**:

- Pause auto-refresh, start 60s reset countdown timer (clock-aligned to minute boundaries)
- `secondsUntilNextRefresh` counts down to `resetsAt` (not next API call)
- All display locations (menubar, popover header, usage cards) use `primary.resetTimeRemaining` as unified source
- Schedule `resumeRefreshTimer` at `resetsAt + 5s` to resume polling
- Non-primary item reset during pause: `checkForExpiredResetTimes()` triggers refresh on each 60s tick; `processedResetTimes` prevents duplicate triggers

## Coding Conventions

- **Naming**: PascalCase types, camelCase functions/variables, constants in `Constants.swift` nested enums
- **Code Organization**: Use `// MARK: -` sections
- **Concurrency**: `@MainActor` for UI classes, async/await for all async work
- **Protocols**: Define protocols for services to enable testing (`ClaudeAPIClientProtocol`, `AuthenticationServiceProtocol`)
- **Error Handling**: Custom error enums with `LocalizedError`
- **Logging**: os.log with per-file `Logger` instances
- **Performance**: Cache DateFormatters, reuse NSHostingView for statusbar, `[weak self]` in closures

## File Structure

```
ClaudeUsage/
├── ClaudeUsageApp.swift      # @main entry point
├── AppDelegate.swift         # Menubar management
├── Models/
│   ├── AuthState.swift       # AuthState enum
│   ├── OAuthCredentials.swift # Claude Code Keychain JSON models
│   ├── SubscriptionType.swift # Subscription tier parsing
│   ├── UserSettings.swift    # User preferences
│   └── UsageData.swift       # Usage response & display models
├── Services/
│   ├── AuthenticationService.swift  # OAuth authentication
│   ├── ClaudeAPIClient.swift        # API client (OAuth)
│   ├── NetworkMonitor.swift         # Network connectivity
│   ├── OAuthTokenService.swift      # Claude Code Keychain reader (read-only)
│   ├── ActiveTasksService.swift     # Claude-code-switcher task count (optional)
│   └── UsageRefreshService.swift    # Polling, reset detection, countdown
├── ViewModels/
│   └── AppViewModel.swift    # UI state coordination
├── Views/
│   ├── MenuBarView.swift     # Main popover view
│   └── UsageCardView.swift   # Usage card components
└── Utilities/
    ├── ClaudeCodeVersion.swift # Dynamic CLI version detection for User-Agent
    └── Constants.swift       # App constants

ClaudeUsageTests/
├── UsageRefreshServiceTests.swift  # Unit tests
└── Mocks/                          # Mock services for testing
```

## API Endpoints

All calls go to `api.anthropic.com`:

- `GET /api/oauth/usage` — Usage statistics (Bearer token + `anthropic-beta` header)
- `GET /api/oauth/prepaid/credits` — Prepaid balance & auto-reload settings
- `GET /api/oauth/overage_spend_limit` — Billing limits & spending details
- `PUT /api/oauth/overage_spend_limit` — Toggle extra usage enabled/disabled

## Security Requirements

- Read-only access to Claude Code's Keychain (never write to it)
- Never log sensitive data (tokens, access tokens)
- Use HTTPS for all network requests

## Build & Test

```bash
./build.sh      # Creates build/ClaudeUsage.app (requires macOS 13.0+, Xcode CLI Tools)
./run-tests.sh  # Compiles and runs unit tests
```

- Lightweight custom test framework (no XCTest dependency)
- Protocol-based dependency injection with mock services

## Important Notes

1. **No External Dependencies**: Keep the project pure Swift/SwiftUI
2. **Menubar App**: Uses `LSUIElement` (no dock icon)
3. **OAuth Only**: Authentication via Claude Code CLI credentials (requires Claude Code installed)
4. **English UI**: User-facing strings are in English
5. **Dynamic API Response**: Usage API returns varying keys; handle with `orderedKeys`
