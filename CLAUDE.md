# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⛔ CRITICAL INVARIANT — read before touching auth/storage/signing

**CocoGram must NEVER force a logged-in user to re-authenticate** (phone + OTP). Before
changing anything under `TDLibConfiguration`, the TDLib database/files paths, credential
resolution, auth-state handling, or `scripts/package.sh` signing, **read
[`SESSION_PERSISTENCE_INVARIANT.md`](SESSION_PERSISTENCE_INVARIANT.md) in full and run its
verification checklist.** The two non-negotiable rules: (A) the TDLib database directory is a
fixed constant — never keyed on `api_id`, cwd, env, or which binary runs; (B) the
`api_id`/`api_hash` are pinned into the database on first login and reused forever. Per-`api_id`
storage slots are **forbidden** — they caused this exact regression once already.

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

### Microphone permission (voice messages)

Recording requires macOS microphone access. Two pieces make the prompt appear:
- `NSMicrophoneUsageDescription` — declared in both `Sources/CocoGram/Info.plist` (embedded
  into the binary's `__TEXT,__info_plist` section by `Package.swift` linker flags, so the
  un-bundled `swift run` build can prompt) and the bundle `Info.plist` written by
  `scripts/package.sh`. Keep the string in sync across both.
- `com.apple.security.device.audio-input` — in `CocoGram.entitlements`, applied to the
  signed app by `package.sh`. **Required under the hardened runtime**: the notarized app is
  denied the mic without it even though the usage string is present.

Dev caveat: the `swift run` binary is ad-hoc signed, and its TCC identity (CDHash) changes
whenever the executable is relinked, so a granted permission may not persist across rebuilds.
The first run prompts; if a later build stops recording, reset with
`tccutil reset Microphone me.giannak.nick.cocogram`, or test mic flows against the signed
bundle (`scripts/package.sh` with `SKIP_NOTARIZE=1`), which has a stable identity.

**TDLib storage uses one fixed path + credential pinning** (see
[`SESSION_PERSISTENCE_INVARIANT.md`](SESSION_PERSISTENCE_INVARIANT.md)): the database and
files live at the constant `~/Library/Application Support/CocoGram/tdlib/database` (+
`/files`), never keyed on api_id/cwd/env/which-binary. On first login the api_id/api_hash
are pinned into `tdlib/database/session.pin` and reused forever; launch-time config
(`.cocogram.local`, `credentials.conf`, env) is consulted only to bootstrap that first
login. This is what guarantees a logged-in user is never forced to re-authenticate. A TDLib
log (warnings and errors) is written to `tdlib.log` next to the database directory.
**Per-api_id storage slots are forbidden** — they caused a re-auth regression once.

### Sound effects (`SoundEffects.swift`)

Short UI cues (recording Start/Pause/Stop, Send, Receive Same-Window/Push) live in
`Sources/CocoGram/Sounds/*.m4a`, declared as an SPM `.copy("Sounds")` resource so
`swift run` finds them via `Bundle.module`. `scripts/package.sh` copies them into the
bundle's `Resources/Sounds` **before** code signing (so they're sealed and survive
notarization), and the app loads them via `Bundle.main`. Cues are **additive** — they never
replace VoiceOver announcements; recording cues are sequenced around capture so they aren't
recorded into the message.

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
