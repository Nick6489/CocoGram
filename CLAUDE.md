# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

CocoGram is a native macOS Telegram client built with AppKit and Swift Package Manager, targeting macOS 15. It wraps Telegram's TDLib via the [TDLibKit](https://github.com/Swiftgram/TDLibKit) Swift package.

## Commands

```bash
# Build
swift build

# Run (debug)
swift run

# Build release
swift build -c release
```

There are no tests at this time.

## Configuration

To connect to real Telegram, create a `.cocogram.local` file in the project root (already gitignored). The app reads it as `KEY=VALUE` lines and merges them with environment variables (env vars take precedence):

```
COCOGRAM_API_ID=<your api_id from my.telegram.org>
COCOGRAM_API_HASH=<your api_hash>
COCOGRAM_TDLIB_TEST_DC=1        # optional: use Telegram's test servers
COCOGRAM_TDLIB_DATABASE=<path>  # optional: override TDLib database directory
COCOGRAM_TDLIB_FILES=<path>     # optional: override TDLib files directory
```

Without valid credentials the app starts in **dummy mode** (`DummyTelegramClient`), which shows hardcoded sample data and is the default development path.

## Architecture

### TelegramClient protocol (`TelegramClient.swift`)

The `TelegramClient` protocol is the boundary between the UI and Telegram. It exposes:
- An `AsyncStream<TelegramUpdate>` called `updates` for push events (auth state changes, chat/message updates)
- Async throwing methods for all user-initiated actions (`loadChats`, `sendText`, `sendVoiceMessage`, etc.)

All methods and the protocol itself are `@MainActor`-isolated.

Two implementations exist:
- **`TDLibTelegramClient`** — live implementation using TDLib. Selected by `AppDelegate` when `.cocogram.local` / env vars provide valid API credentials. Maintains in-memory `chatCache` and `userCache` to avoid redundant network requests.
- **`DummyTelegramClient`** — in-process stub with hardcoded conversations, messages, contacts, channels, and calls. Used when credentials are absent.

### UI layout (`main.swift`)

The app uses a programmatic three-column `NSSplitViewController` (`RootViewController`):

| Column | Controller | Width |
|---|---|---|
| Sidebar | `SidebarViewController` | 176–220 pt |
| Item list | `ItemListViewController` | 280–380 pt |
| Detail / conversation | `DetailViewController` | ≥420 pt |

`SidebarViewController` → `ItemListViewController` → `DetailViewController` communicate via callback closures (`onSelect`). Neither references the other directly.

`AppDelegate` owns both the `TelegramClient` instance and the `MainWindowController`. It observes `TelegramClient.updates` in an `async for` loop and routes auth-state changes to sheet-based prompts (`AuthenticationPromptController`) or tells the window controller to show chats.

### Models (`Models.swift`)

Plain Swift value types: `Conversation`, `Contact`, `Channel`, `CallRecord`, `Message` (with `MessageKind`: `.text` or `.voice`). The `DetailItem` enum wraps them all into a single type passed from the list to the detail view.

`NavigationSection` drives the sidebar and controls which `TelegramClient` method `ItemListViewController` calls.

### Accessibility

Every interactive element has explicit `setAccessibilityLabel` / `setAccessibilityRole` / `setAccessibilityHelp` calls. The `accessibilitySummary` computed properties on `Message` and `DetailItem` are the canonical strings surfaced to VoiceOver.

### TDLib concurrency notes

TDLib delivers raw update `Data` on an internal thread. `TDLibUpdateBridge` (a `nonisolated` helper) hops it to `@MainActor` via a `Task`. The `@retroactive @unchecked Sendable` conformances at the top of `TDLibTelegramClient.swift` are required because TDLibKit types cross the actor boundary before Swift 6 concurrency checking can verify them.
