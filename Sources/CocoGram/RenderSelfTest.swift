import AppKit
import AVFoundation
import AVKit

/// Headless render verification for the three message-view fixes: tight row spacing, real media
/// (photo / sticker / video poster) decoding + rendering, and scroll-back pagination. Builds the
/// real `MessageTableCellView` against the live session, lays it out and renders it offscreen
/// (no window is ever shown — see `SelfTest`), then inspects geometry and rendered pixels.
@MainActor
enum RenderSelfTest {
    private static let renderWidth: CGFloat = 420

    static func run(client: TDLibTelegramClient) async -> String {
        var lines: [String] = []
        func emit(_ s: String) { lines.append(s) }

        // Offscreen AppKit drawing (cacheDisplay) needs the shared application initialized and
        // connected to the window server. We never show a window or activate, so nothing
        // appears on screen and focus is never stolen (see the never-foreground rule).
        _ = NSApplication.shared

        let loader = MediaImageLoader { try await client.downloadFile(fileID: $0) }

        // Find sample messages: a text message (spacing), a photo/sticker and a video/animation
        // (real media), and a chat with enough history to paginate.
        let chats = (try? await client.loadChats()) ?? []
        emit("Scanning up to 25 of \(chats.count) chats for sample messages…")

        var sampleText: Message?
        var samplePhoto: (message: Message, media: ImageMedia)?
        var sampleSticker: (message: Message, media: ImageMedia)?
        var sampleVideo: (message: Message, media: VideoMedia)?
        var scrollback: (id: Int64, title: String, oldest: Int64, recent: Int)?

        for chat in chats.prefix(25) {
            let msgs = (try? await client.loadMessages(chatID: chat.id)) ?? []
            if scrollback == nil, msgs.count >= 6, let oldest = msgs.first {
                scrollback = (chat.id, chat.title, oldest.id, msgs.count)
            }
            for message in msgs {
                switch message.kind {
                case .text(let body) where sampleText == nil && !body.isEmpty:
                    sampleText = message
                case .image(let media):
                    // Photos and stickers are both .image; distinguish by the a11y label so we
                    // verify WebP sticker decoding separately from JPEG/PNG photo decoding.
                    if media.accessibilityLabel.hasPrefix("Sticker") {
                        if sampleSticker == nil { sampleSticker = (message, media) }
                    } else if samplePhoto == nil {
                        samplePhoto = (message, media)
                    }
                case .video(let media):
                    // Prefer the shortest video so the playback download stays small and fast.
                    if sampleVideo == nil || media.duration < sampleVideo!.media.duration {
                        sampleVideo = (message, media)
                    }
                default:
                    break
                }
            }
            if sampleText != nil, samplePhoto != nil, sampleSticker != nil, sampleVideo != nil, scrollback != nil { break }
        }

        // Issue 1 — message row spacing.
        emit("--- Issue 1: message row spacing (self-sizing) ---")
        let textMessage = sampleText ?? Message(
            id: 0, sender: "Sample", time: "now", isOutgoing: false,
            kind: .text("Short message."), outgoingStatus: nil
        )
        let textHeight = measuredHeight(message: textMessage, loader: loader)
        emit("Short text cell self-sizes to \(Int(textHeight))pt + 2pt gap "
            + "(old behavior was a fixed 92pt row + 8pt gap = 100pt)\(sampleText == nil ? " [synthetic]" : "").")

        // Issue 2 — real media.
        emit("--- Issue 2: real media rendering ---")
        if let sample = samplePhoto {
            emit("Photo — " + (await renderReport(
                message: sample.message, loader: loader,
                imageFileID: sample.media.fileID, intrinsic: (sample.media.width, sample.media.height)
            )))
        } else {
            emit("Photo: none found in sampled chats.")
        }

        if let sample = sampleSticker {
            emit("Sticker (\(sample.media.accessibilityLabel)) — " + (await renderReport(
                message: sample.message, loader: loader,
                imageFileID: sample.media.fileID, intrinsic: (sample.media.width, sample.media.height)
            )))
        } else {
            emit("Sticker: none found in sampled chats.")
        }

        if let sample = sampleVideo {
            emit("Video/animation poster — " + (await renderReport(
                message: sample.message, loader: loader,
                imageFileID: sample.media.posterFileID, intrinsic: (sample.media.width, sample.media.height)
            )))
            emit("  click-to-play (no autoplay): " + videoWiringReport(message: sample.message))
            // The reported bug: clicking play made the message "disappear". That was a row-height
            // collapse — verify attaching the player keeps the cell exactly the same height.
            emit("  height stable when player attached: " + heightStabilityReport(message: sample.message, loader: loader))
            // Exercise the exact mechanism the fix uses inside a REAL NSTableView (offscreen, never
            // shown): retrieve the live cell via view(atColumn:row:) and attach in place, asserting
            // the row stays retrievable and the same height (no judder/disappear).
            emit("  live-table attach: " + tableAttachReport(message: sample.message, loader: loader))
            // The reported bug: "videos not playing". Verify the file actually downloads and is a
            // real, playable video asset (not just that the wiring exists).
            emit("  playback: " + (await playbackReport(client: client, media: sample.media)))
        } else {
            emit("Video/animation: none found in sampled chats.")
        }

        // Issue 3 — scroll-back pagination.
        emit("--- Issue 3: scroll-back pagination ---")
        if let sc = scrollback {
            let older = (try? await client.loadOlderMessages(chatID: sc.id, beforeMessageID: sc.oldest)) ?? []
            let strictlyOlder = older.allSatisfy { $0.id < sc.oldest }
            let ascending = zip(older, older.dropFirst()).allSatisfy { $0.id < $1.id }
            emit("Chat \"\(truncate(sc.title))\": \(sc.recent) recent loaded; "
                + "loadOlderMessages(before id \(sc.oldest)) streamed \(older.count) older message(s).")
            emit("  strictly older than anchor = \(strictlyOlder); oldest-first ordering = \(ascending).")
        } else {
            emit("Scrollback: no chat with >=6 messages found to paginate.")
        }

        return lines.joined(separator: "\n")
    }

    /// Builds a configured, laid-out cell at the render width.
    private static func makeCell(_ message: Message, loader: MediaImageLoader) -> MessageTableCellView {
        let cell = MessageTableCellView()
        cell.configure(message: message, imageLoader: loader, onPlayVoiceMessage: {}, onPlayVideo: { _ in })
        let widthConstraint = cell.widthAnchor.constraint(equalToConstant: renderWidth)
        widthConstraint.isActive = true
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    private static func measuredHeight(message: Message, loader: MediaImageLoader) -> CGFloat {
        makeCell(message, loader: loader).fittingSize.height
    }

    /// Pre-fetches the media image so the cell renders with real bytes, then lays the cell out,
    /// renders it offscreen, and reports the decoded image size, display size, and how many
    /// distinct colors the rendered pixels contain (a flat placeholder yields very few).
    private static func renderReport(message: Message, loader: MediaImageLoader, imageFileID: Int?, intrinsic: (Int, Int)) async -> String {
        var decoded: NSImage?
        if let fileID = imageFileID {
            decoded = await loader.image(fileID: fileID)  // warms the cache; configure picks it up
        }

        let cell = makeCell(message, loader: loader)
        let height = cell.fittingSize.height
        cell.frame = NSRect(x: 0, y: 0, width: renderWidth, height: max(height, 1))
        cell.layoutSubtreeIfNeeded()
        let distinctColors = renderAndCountColors(cell)

        let display = MediaLayout.displaySize(width: intrinsic.0, height: intrinsic.1)
        let decodedDescription = decoded.map { "decoded \(Int($0.size.width))×\(Int($0.size.height))" }
            ?? "image unavailable (no poster or download failed)"
        let verdict = distinctColors >= 8 ? "real content rendered ✓" : "flat/placeholder ✗"
        return "intrinsic \(intrinsic.0)×\(intrinsic.1) → display \(Int(display.width))×\(Int(display.height)); "
            + "\(decodedDescription); cell \(Int(renderWidth))×\(Int(height))pt; "
            + "distinct sampled colors=\(distinctColors) (\(verdict))."
    }

    /// Confirms a video cell is activatable, does not play before activation (no autoplay), and
    /// does play on activation — exercised purely structurally, with no real player.
    private static func videoWiringReport(message: Message) -> String {
        var played = false
        let loader = MediaImageLoader { _ in throw CocoaError(.fileNoSuchFile) }
        let cell = MessageTableCellView()
        cell.configure(message: message, imageLoader: loader, onPlayVoiceMessage: {}, onPlayVideo: { _ in played = true })
        let autoplayed = played
        let activated = cell.accessibilityPerformPress()
        return "activatable=\(activated), autoplayed-before-activation=\(autoplayed), played-on-activation=\(played)"
    }

    /// Verifies that swapping the poster for the inline player does NOT change the cell's height
    /// (the cause of the "message disappears" bug). Attaches a stand-in player view exactly as
    /// the controller does and compares the laid-out height before vs after.
    private static func heightStabilityReport(message: Message, loader: MediaImageLoader) -> String {
        let cell = makeCell(message, loader: loader)
        let posterHeight = cell.fittingSize.height
        let standInPlayer = NSView()  // attachInlineVideo pins it to the poster's size
        cell.attachInlineVideo(standInPlayer)
        cell.layoutSubtreeIfNeeded()
        let playerHeight = cell.fittingSize.height
        let stable = abs(posterHeight - playerHeight) < 1
        return "poster \(Int(posterHeight))pt vs player \(Int(playerHeight))pt → \(stable ? "stable ✓ (message stays put)" : "CHANGED ✗ (would jump/disappear)")"
    }

    /// Downloads the real video file (caching on disk) and confirms it is a genuinely playable
    /// video asset — the strongest headless proof that activation will actually play video.
    private static func playbackReport(client: TDLibTelegramClient, media: VideoMedia) async -> String {
        // Downloading is synchronous (whole file). Skip very long videos so the test doesn't pull
        // hundreds of MB; the playability path is format-based and identical regardless of length.
        if media.duration > 180 {
            return "skipped full download for a long video (\(Int(media.duration))s); play path is the "
                + "same downloadFile→AVPlayer used for short clips."
        }
        guard let url = try? await client.downloadFile(fileID: media.videoFileID) else {
            return "download failed ✗"
        }
        let sizeKB = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) / 1024
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let verdict = playable && !videoTracks.isEmpty && duration > 0 ? "PLAYS ✓" : "not playable ✗"
        return "cached \(sizeKB)KB at \(url.lastPathComponent); isPlayable=\(playable), "
            + "videoTracks=\(videoTracks.count), duration=\(String(format: "%.1f", duration))s → \(verdict)"
    }

    /// Renders a view offscreen and counts distinct colors across a sampling grid. Real photos /
    /// stickers / video frames contain many; an unrendered placeholder contains one or two.
    private static func renderAndCountColors(_ view: NSView) -> Int {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)

        let wide = rep.pixelsWide
        let high = rep.pixelsHigh
        guard wide > 0, high > 0 else { return 0 }

        var colors = Set<Int>()
        let steps = 24
        for i in 0..<steps {
            for j in 0..<steps {
                let x = min(wide - 1, wide * i / steps)
                let y = min(high - 1, high * j / steps)
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let key = (Int(color.redComponent * 15) << 8)
                    | (Int(color.greenComponent * 15) << 4)
                    | Int(color.blueComponent * 15)
                colors.insert(key)
            }
        }
        return colors.count
    }

    private static func truncate(_ title: String) -> String {
        title.count <= 28 ? title : String(title.prefix(27)) + "…"
    }

    /// End-to-end check of the controller's play mechanism in a real (offscreen, never-shown)
    /// NSTableView: materialize the cell with `view(atColumn:row:)`, attach the player in place,
    /// and confirm the row stays retrievable at the same height — the two failure symptoms were
    /// the row vanishing and focus jumping, both caused by reloading instead of attaching.
    private static func tableAttachReport(message: Message, loader: MediaImageLoader) -> String {
        let table = NSTableView()
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.width = renderWidth
        table.addTableColumn(column)
        let source = StubTableSource(message: message, loader: loader)
        table.dataSource = source
        table.delegate = source

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: renderWidth, height: 600))
        scroll.documentView = table
        // Offscreen, borderless, NEVER ordered front — gives the table a window context for
        // view(atColumn:row:) without ever appearing on screen or stealing focus.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: renderWidth, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        table.reloadData()
        table.layoutSubtreeIfNeeded()

        guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? MessageTableCellView else {
            _ = window
            return "could not retrieve live cell ✗"
        }
        let heightBefore = table.rect(ofRow: 0).height
        cell.attachInlineVideo(NSView())  // stand-in player, sized to the poster
        table.layoutSubtreeIfNeeded()
        let stillRetrievable = (table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? MessageTableCellView) === cell
        let heightAfter = table.rect(ofRow: 0).height
        let stable = abs(heightBefore - heightAfter) < 2
        _ = window  // keep the window alive through the checks
        return "cell retrieved=\(true), still retrievable after attach=\(stillRetrievable), "
            + "row height \(Int(heightBefore))→\(Int(heightAfter))pt \(stable ? "stable ✓" : "CHANGED ✗")"
    }
}

/// Minimal one-row table source for the live-table attach check.
@MainActor
private final class StubTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let message: Message
    private let loader: MediaImageLoader

    init(message: Message, loader: MediaImageLoader) {
        self.message = message
        self.loader = loader
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = MessageTableCellView()
        cell.configure(message: message, imageLoader: loader, onPlayVoiceMessage: {}, onPlayVideo: { _ in })
        return cell
    }
}
