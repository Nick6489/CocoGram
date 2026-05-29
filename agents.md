# agents.md

Notes for AI agents on non-obvious bugs and dead ends encountered in this codebase.

---

## VoiceOver traversal order in the three-column split view

### Symptom
After loading a conversation, VoiceOver traversed the three columns in the wrong order:
**messages → main sections → chats list** instead of **main sections → chats list → messages**.

### What does NOT cause it (dead ends)
- The `messageScrollView`'s frame being zero before layout. Forcing `view.layoutSubtreeIfNeeded()` before any accessibility notification had no effect.
- Swapping `scrollView.documentView` at runtime vs. using two permanent scroll views with `isHidden` toggling. Restructuring to always keep each scroll view in the layout hierarchy had no effect.
- The `reloadData()` call firing before layout was committed. Removing the redundant reload had no effect.

### Actual root cause
`NSSplitViewItem(sidebarWithViewController:)` and `NSSplitViewItem(contentListWithViewController:)` cause AppKit to classify those panes as *supplementary* content in the accessibility tree. AppKit then surfaces the "main" pane (the detail column) first in VoiceOver traversal, followed by the supplementary panes — regardless of their visual left-to-right order.

This is only observable once the detail column contains visible content. When the message scroll view is hidden (no conversation loaded), VoiceOver only sees the sidebar and list, which appear in the correct relative order. As soon as the message scroll view is shown, the supplementary-vs-main classification takes effect and the detail column jumps to the front.

### Fix
Use plain `NSSplitViewItem(viewController:)` for all three panes. The sidebar's source-list visual style is controlled by `NSTableView.style = .sourceList` on the sidebar's table view, not by the split view item type, so the appearance is unchanged. The trade-off is losing AppKit's automatic sidebar-collapse-on-resize behavior; the explicit `minimumThickness`/`maximumThickness` constraints on the split view items remain and are sufficient.

---

## Conversation list not showing last message previews

### Symptom
The chats list loaded correctly but all conversation subtitles showed "No messages yet" even for active chats.

### Cause (two separate issues)
1. **`TDLibChatOverlay` was a stub.** The `updateChatLastMessage` handler called `TDLibChatOverlay.chat(_:lastMessage:)` to update the cached `Chat` with the new last message, but that function simply returned the original chat unchanged. TDLib's live last-message updates were silently discarded.

2. **`getChats` was called before TDLib's local database was populated.** On first launch (or with a fresh database), calling TDLib's `getChats` immediately after `authorizationStateReady` can return chat IDs whose `lastMessage` field is nil because TDLib hasn't yet loaded the chat data from the server.

### Fix
- Added `chatLastMessageCache: [Int64: TDLibKit.Message?]` to track last-message overrides separately (since `TDLibKit.Chat` is a generated struct with all `let` fields — it can't be reconstructed just to update one field).
- `updateChatLastMessage` now writes into the cache and triggers a chat list refresh via the private `fetchChats()` method.
- `mapConversation` consults the cache before falling back to `chat.lastMessage`.
- `loadChats()` (the public protocol method) now calls TDLib's `loadChats` before `getChats`, ensuring the local database is populated before the ID list is read. The private `fetchChats()` skips this step and is used for live-update refreshes where the data is already present.
