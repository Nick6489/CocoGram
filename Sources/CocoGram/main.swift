import AppKit
@preconcurrency import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var telegramClient: TelegramClient!
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()
        NSApp.activate(ignoringOtherApps: true)

        // Choose the client only after we know whether credentials exist. With none, an
        // accessible first-run setup screen lets the user enter API credentials (or opt
        // into sample data) by ear — see AccountSetupController.
        if let configuration = TDLibConfiguration.resolve() {
            startSession(with: TDLibTelegramClient(configuration: configuration))
        } else {
            presentAccountSetup()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Builds the main window for the chosen client and starts the Telegram event loop.
    private func startSession(with client: TelegramClient) {
        telegramClient = client
        let controller = MainWindowController(telegramClient: client)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        windowController = controller

        Task {
            try? await client.start()
        }
        Task {
            await observeTelegramUpdates()
        }
    }

    /// Presents the first-run / revisit credential setup screen in its own window. The
    /// "use sample data" escape hatch is offered only on first run (before a session
    /// exists); revisiting from the menu just saves and asks the user to relaunch.
    @objc func showAccountSetup() {
        presentAccountSetup()
    }

    private func presentAccountSetup() {
        if let existing = setupWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let isRevisit = telegramClient != nil
        let controller = AccountSetupController(showsSampleDataOption: !isRevisit)
        controller.onComplete = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .credentials(let apiID, let apiHash, let useTestDataCenter):
                do {
                    try TDLibConfiguration.saveCredentials(
                        apiID: apiID,
                        apiHash: apiHash,
                        useTestDataCenter: useTestDataCenter
                    )
                } catch {
                    controller.showError("Couldn't save your credentials: \(error.localizedDescription)")
                    return
                }

                if isRevisit {
                    // A live session is already running against the old client; swapping it
                    // mid-flight is fragile, so confirm the save and ask for a relaunch.
                    self.dismissSetup()
                    self.announce("Credentials saved. Quit and reopen CocoGram to sign in with this account.")
                } else if let configuration = TDLibConfiguration.resolve() {
                    self.dismissSetup()
                    self.startSession(with: TDLibTelegramClient(configuration: configuration))
                } else {
                    controller.showError("Saved, but those credentials couldn't be read back. Check the values and try again.")
                }
            case .useSampleData:
                self.dismissSetup()
                self.startSession(with: DummyTelegramClient())
            }
        }

        let window = NSWindow(contentViewController: controller)
        window.title = "Set Up CocoGram"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 380))
        window.isReleasedWhenClosed = false
        window.center()
        setupWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func dismissSetup() {
        setupWindow?.close()
        setupWindow = nil
    }

    /// Posts a high-priority VoiceOver announcement (mirrors the app's existing pattern
    /// for surfacing important state changes to assistive technology).
    private func announce(_ message: String) {
        let element: Any = windowController?.window ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    /// Builds the application menu bar programmatically. SwiftPM executables have no
    /// MainMenu.xib, so without this there is no app menu and standard shortcuts
    /// (Cmd+Q, Cmd+W, Cmd+C/V/X) never fire — AppKit resolves key equivalents through
    /// NSApp.mainMenu before the responder chain. The first item is treated as the app menu.
    private func makeMainMenu() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        // Application menu (its title is replaced by the app name by AppKit).
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let setup = appMenu.addItem(withTitle: "Set Up Telegram Account…", action: #selector(showAccountSetup), keyEquivalent: "")
        setup.target = self
        setup.setAccessibilityHelp("Enter or change your Telegram API credentials.")
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "").target = NSApp
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        // Edit menu — provides the clipboard key equivalents (Cmd+X/C/V/A/Z) that
        // NSTextField/NSTextView rely on via the responder chain.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let playbackMenuItem = NSMenuItem()
        mainMenu.addItem(playbackMenuItem)
        let playbackMenu = NSMenu(title: "Playback")
        playbackMenuItem.submenu = playbackMenu
        let slower = playbackMenu.addItem(withTitle: "Slower", action: #selector(decreaseVoicePlaybackSpeed(_:)), keyEquivalent: "[")
        slower.target = self
        let faster = playbackMenu.addItem(withTitle: "Faster", action: #selector(increaseVoicePlaybackSpeed(_:)), keyEquivalent: "]")
        faster.target = self
        playbackMenu.addItem(.separator())
        let volumeDown = playbackMenu.addItem(withTitle: "Volume Down", action: #selector(decreaseVoicePlaybackVolume(_:)), keyEquivalent: "\u{F701}")
        volumeDown.keyEquivalentModifierMask = [.command]
        volumeDown.target = self
        let volumeUp = playbackMenu.addItem(withTitle: "Volume Up", action: #selector(increaseVoicePlaybackVolume(_:)), keyEquivalent: "\u{F700}")
        volumeUp.keyEquivalentModifierMask = [.command]
        volumeUp.target = self

        // Window menu — standard window management; NSApp.windowsMenu wires it up.
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    @objc private func decreaseVoicePlaybackSpeed(_ sender: Any?) {
        windowController?.decreaseVoicePlaybackSpeed()
    }

    @objc private func increaseVoicePlaybackSpeed(_ sender: Any?) {
        windowController?.increaseVoicePlaybackSpeed()
    }

    @objc private func decreaseVoicePlaybackVolume(_ sender: Any?) {
        windowController?.decreaseVoicePlaybackVolume()
    }

    @objc private func increaseVoicePlaybackVolume(_ sender: Any?) {
        windowController?.increaseVoicePlaybackVolume()
    }

    private func observeTelegramUpdates() async {
        for await update in telegramClient.updates {
            switch update {
            case .authorizationStateChanged(let state):
                handleAuthorizationState(state)
            case .chatsChanged:
                windowController?.showChats()
            case .messagesChanged:
                break
            }
        }
    }

    private func handleAuthorizationState(_ state: TelegramAuthorizationState) {
        switch state {
        case .waitingForPhoneNumber:
            presentAuthenticationPrompt(
                title: "Telegram Phone Number",
                message: "Enter your Telegram phone number in international format.",
                placeholder: "+15551234567",
                isSecure: false
            ) { [weak self] value in
                try await self?.telegramClient.submitPhoneNumber(value)
            }
        case .waitingForCode:
            presentAuthenticationPrompt(
                title: "Telegram Code",
                message: "Enter the login code Telegram sent you.",
                placeholder: "Login code",
                isSecure: false
            ) { [weak self] value in
                try await self?.telegramClient.submitAuthenticationCode(value)
            }
        case .waitingForPassword:
            presentAuthenticationPrompt(
                title: "Telegram Password",
                message: "Enter your two-step verification password.",
                placeholder: "Password",
                isSecure: true
            ) { [weak self] value in
                try await self?.telegramClient.submitPassword(value)
            }
        case .ready:
            windowController?.showChats()
        default:
            break
        }
    }

    private func presentAuthenticationPrompt(
        title: String,
        message: String,
        placeholder: String,
        isSecure: Bool,
        submit: @escaping (String) async throws -> Void
    ) {
        guard let parentWindow = windowController?.window else { return }
        if parentWindow.attachedSheet != nil { return }

        let controller = AuthenticationPromptController(
            title: title,
            message: message,
            placeholder: placeholder,
            isSecure: isSecure
        )
        controller.onSubmit = { value in
            Task { @MainActor in
                do {
                    try await submit(value)
                    parentWindow.endSheet(controller.view.window!)
                } catch {
                    controller.showError(error.localizedDescription)
                }
            }
        }

        let sheet = NSWindow(contentViewController: controller)
        sheet.title = title
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 430, height: 220))
        sheet.isReleasedWhenClosed = false
        parentWindow.beginSheet(sheet)
    }
}

final class MainWindowController: NSWindowController {
    init(telegramClient: TelegramClient) {
        let rootViewController = RootViewController(telegramClient: telegramClient)
        let window = NSWindow(contentViewController: rootViewController)
        window.title = "CocoGram"
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 920, height: 600)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showChats() {
        (contentViewController as? RootViewController)?.showChats()
    }

    func decreaseVoicePlaybackSpeed() {
        (contentViewController as? RootViewController)?.decreaseVoicePlaybackSpeed()
    }

    func increaseVoicePlaybackSpeed() {
        (contentViewController as? RootViewController)?.increaseVoicePlaybackSpeed()
    }

    func decreaseVoicePlaybackVolume() {
        (contentViewController as? RootViewController)?.decreaseVoicePlaybackVolume()
    }

    func increaseVoicePlaybackVolume() {
        (contentViewController as? RootViewController)?.increaseVoicePlaybackVolume()
    }
}

final class RootViewController: NSSplitViewController {
    private let sidebarController = SidebarViewController()
    private let listController: ItemListViewController
    private let detailController: DetailViewController

    init(telegramClient: TelegramClient) {
        listController = ItemListViewController(telegramClient: telegramClient)
        detailController = DetailViewController(telegramClient: telegramClient)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        addSplitViewItem(NSSplitViewItem(viewController: sidebarController))
        addSplitViewItem(NSSplitViewItem(viewController: listController))
        addSplitViewItem(NSSplitViewItem(viewController: detailController))

        splitViewItems[0].minimumThickness = 176
        splitViewItems[0].maximumThickness = 220
        splitViewItems[1].minimumThickness = 280
        splitViewItems[1].maximumThickness = 380
        splitViewItems[2].minimumThickness = 420

        sidebarController.onSelect = { [weak self] section in
            self?.listController.show(section: section)
        }
        listController.onSelect = { [weak self] item in
            self?.detailController.show(item: item)
        }

        sidebarController.select(section: .chats)
    }

    func showChats() {
        sidebarController.select(section: .chats)
    }

    func decreaseVoicePlaybackSpeed() {
        detailController.decreasePlaybackSpeed(nil)
    }

    func increaseVoicePlaybackSpeed() {
        detailController.increasePlaybackSpeed(nil)
    }

    func decreaseVoicePlaybackVolume() {
        detailController.decreasePlaybackVolume(nil)
    }

    func increaseVoicePlaybackVolume() {
        detailController.increasePlaybackVolume(nil)
    }
}

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((NavigationSection) -> Void)?

    private let tableView = NSTableView()
    private let sections = NavigationSection.allCases

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "CocoGram")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityLabel("CocoGram")

        tableView.headerView = nil
        tableView.rowHeight = 42
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .regular
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SectionColumn")))
        tableView.setAccessibilityLabel("Main sections")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        let stack = NSStackView(views: [title, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 18, bottom: 18, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func select(section: NavigationSection) {
        guard let index = sections.firstIndex(of: section) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        onSelect?(section)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = sections[row]
        let cell = IconTextCellView()
        cell.configure(iconName: section.icon, title: section.rawValue, subtitle: nil, badge: nil)
        cell.setAccessibilityRole(.button)
        cell.setAccessibilityLabel(section.rawValue)
        cell.onActivate = { [weak self] in
            self?.select(section: section)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        onSelect?(sections[row])
    }
}

final class ItemListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((DetailItem) -> Void)?

    private static let lastSelectedConversationIDKey = "lastSelectedConversationID"

    private let telegramClient: TelegramClient
    private let titleLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var section: NavigationSection = .chats
    private var items: [DetailItem] = []
    private var selectedItem: DetailItem?
    private var isSelectingProgrammatically = false

    init(telegramClient: TelegramClient) {
        self.telegramClient = telegramClient
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)

        searchField.placeholderString = "Search"
        searchField.setAccessibilityLabel("Search current section")

        tableView.headerView = nil
        tableView.rowHeight = 74
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .regular
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemColumn")))
        tableView.setAccessibilityLabel("Items")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let stack = NSStackView(views: [titleLabel, searchField, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 16, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func show(section: NavigationSection) {
        self.section = section
        titleLabel.stringValue = section.rawValue
        searchField.placeholderString = "Search \(section.rawValue.lowercased())"
        tableView.setAccessibilityLabel("\(section.rawValue) list")
        items = []
        selectedItem = nil
        tableView.reloadData()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loadedItems: [DetailItem]
                switch section {
                case .chats:
                    loadedItems = try await telegramClient.loadChats().map(DetailItem.conversation)
                case .contacts:
                    loadedItems = try await telegramClient.loadContacts().map(DetailItem.contact)
                case .channels:
                    loadedItems = try await telegramClient.loadChannels().map(DetailItem.channel)
                case .calls:
                    loadedItems = try await telegramClient.loadCalls().map(DetailItem.call)
                }

                guard self.section == section else { return }
                self.items = loadedItems
                self.tableView.reloadData()
                if !loadedItems.isEmpty {
                    self.selectItem(at: self.initialSelectionIndex(in: loadedItems, for: section))
                }
            } catch {
                self.items = []
                self.tableView.reloadData()
                self.titleLabel.stringValue = "\(section.rawValue) unavailable"
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = IconTextCellView()
        let badge: String?
        let iconName: String

        switch item {
        case .conversation(let conversation):
            iconName = conversation.isPinned ? "pin.fill" : "bubble.left.fill"
            badge = conversation.unreadCount > 0 ? "\(conversation.unreadCount)" : (conversation.isMuted ? "Muted" : nil)
        case .contact:
            iconName = "person.crop.circle.fill"
            badge = nil
        case .channel:
            iconName = "megaphone.fill"
            badge = nil
        case .call(let call):
            iconName = call.missed ? "phone.down.fill" : "phone.fill"
            badge = call.missed ? "Missed" : nil
        }

        cell.configure(iconName: iconName, title: item.title, subtitle: item.subtitle, badge: badge)
        cell.setAccessibilityRole(.button)
        cell.setAccessibilityLabel(item.accessibilitySummary)
        cell.onActivate = { [weak self] in
            self?.selectItem(at: row)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        selectItem(at: row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < items.count else { return false }
        if tableView.selectedRow == row {
            selectItem(at: row)
        }
        return true
    }

    private func selectItem(at row: Int) {
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        selectedItem = item
        if case .conversation(let conversation) = item {
            UserDefaults.standard.set(conversation.id, forKey: Self.lastSelectedConversationIDKey)
        }
        if tableView.selectedRow != row {
            isSelectingProgrammatically = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isSelectingProgrammatically = false
        }
        onSelect?(item)
    }

    private func initialSelectionIndex(in items: [DetailItem], for section: NavigationSection) -> Int {
        guard
            section == .chats,
            let conversationID = UserDefaults.standard.object(forKey: Self.lastSelectedConversationIDKey) as? NSNumber,
            let index = items.firstIndex(where: { item in
                guard case .conversation(let conversation) = item else { return false }
                return conversation.id == conversationID.int64Value
            })
        else {
            return 0
        }

        return index
    }
}

final class DetailViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let playbackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private let telegramClient: TelegramClient
    private let headerTitle = NSTextField(labelWithString: "Select a chat")
    private let headerSubtitle = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private let messageScrollView = NSScrollView()
    private let infoScrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let messageTableView = NSTableView()
    private let composerField = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let attachButton = NSButton(image: NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach file") ?? NSImage(), target: nil, action: nil)
    private let recordButton = NSButton(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Record message") ?? NSImage(), target: nil, action: nil)
    private let playbackStatusLabel = NSTextField(labelWithString: "Voice playback: idle")
    private let playbackSpeedPopUp = NSPopUpButton()
    private let playbackVolumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var recordingDialogController: RecordingDialogController?
    private var messages: [Message] = []
    private var currentConversationID: Int64?
    private var audioPlayer: AVAudioPlayer?
    private var playingVoiceFileID: Int?
    private var playbackTask: Task<Void, Never>?

    init(telegramClient: TelegramClient) {
        self.telegramClient = telegramClient
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        headerTitle.font = .systemFont(ofSize: 23, weight: .semibold)
        headerTitle.setAccessibilityRole(.staticText)
        headerSubtitle.font = .systemFont(ofSize: 13)
        headerSubtitle.textColor = .secondaryLabelColor

        // A long title/subtitle must never dictate the window's minimum width. These
        // single-line header labels truncate instead of expanding, and yield horizontally
        // (low compression resistance) so the window resizes freely down to its minSize.
        // VoiceOver still reads the full text via the accessibility labels set in show(item:).
        for label in [headerTitle, headerSubtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        actionStack.orientation = .horizontal
        actionStack.spacing = 8
        actionStack.alignment = .centerY

        let headerText = NSStackView(views: [headerTitle, headerSubtitle])
        headerText.orientation = .vertical
        headerText.spacing = 2

        let header = NSStackView(views: [headerText, NSView(), actionStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 14, right: 22)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)

        messageTableView.headerView = nil
        messageTableView.rowHeight = 104
        messageTableView.intercellSpacing = NSSize(width: 0, height: 8)
        messageTableView.dataSource = self
        messageTableView.delegate = self
        messageTableView.selectionHighlightStyle = .regular
        messageTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        messageTableView.setAccessibilityLabel("Messages")

        let messageColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MessageColumn"))
        messageColumn.resizingMask = .autoresizingMask
        messageTableView.addTableColumn(messageColumn)

        messageScrollView.documentView = messageTableView
        messageScrollView.hasVerticalScroller = true
        messageScrollView.drawsBackground = false
        messageScrollView.isHidden = true

        infoScrollView.documentView = contentStack
        infoScrollView.hasVerticalScroller = true
        infoScrollView.drawsBackground = false
        infoScrollView.setAccessibilityLabel("Conversation detail")
        infoScrollView.isHidden = true

        composerField.placeholderString = "Message"
        composerField.setAccessibilityLabel("Message text")

        attachButton.bezelStyle = .texturedRounded
        attachButton.setAccessibilityLabel("Attach file")
        attachButton.setAccessibilityHelp("Adds a file or media attachment to this message.")

        recordButton.bezelStyle = .texturedRounded
        recordButton.target = self
        recordButton.action = #selector(recordMessage)
        recordButton.setAccessibilityLabel("Record message")
        recordButton.setAccessibilityHelp("Opens a recording dialog and starts recording immediately.")

        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendTextMessage)
        sendButton.setAccessibilityLabel("Send message")

        playbackStatusLabel.font = .systemFont(ofSize: 12)
        playbackStatusLabel.textColor = .secondaryLabelColor
        playbackStatusLabel.setAccessibilityLabel("Voice playback idle")

        let speedLabel = NSTextField(labelWithString: "Speed")
        speedLabel.font = .systemFont(ofSize: 12)
        playbackSpeedPopUp.addItems(withTitles: Self.playbackRates.map { "\($0)x" })
        playbackSpeedPopUp.selectItem(at: 2)
        playbackSpeedPopUp.target = self
        playbackSpeedPopUp.action = #selector(playbackSpeedChanged)
        playbackSpeedPopUp.setAccessibilityLabel("Voice playback speed")

        let volumeLabel = NSTextField(labelWithString: "Volume")
        volumeLabel.font = .systemFont(ofSize: 12)
        playbackVolumeSlider.target = self
        playbackVolumeSlider.action = #selector(playbackVolumeChanged)
        playbackVolumeSlider.setAccessibilityLabel("Voice playback volume")
        playbackVolumeSlider.setAccessibilityHelp("Adjusts voice message playback volume. Command Up and Command Down also change volume.")

        let playbackControls = NSStackView(views: [playbackStatusLabel, NSView(), speedLabel, playbackSpeedPopUp, volumeLabel, playbackVolumeSlider])
        playbackControls.orientation = .horizontal
        playbackControls.alignment = .centerY
        playbackControls.spacing = 8
        playbackControls.edgeInsets = NSEdgeInsets(top: 8, left: 22, bottom: 8, right: 22)

        let composer = NSStackView(views: [attachButton, composerField, recordButton, sendButton])
        composer.orientation = .horizontal
        composer.alignment = .centerY
        composer.spacing = 8
        composer.edgeInsets = NSEdgeInsets(top: 12, left: 22, bottom: 16, right: 22)

        let root = NSStackView(views: [header, separator(), messageScrollView, infoScrollView, separator(), playbackControls, separator(), composer])
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            messageScrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            messageScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            infoScrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            playbackControls.widthAnchor.constraint(equalTo: root.widthAnchor),
            playbackVolumeSlider.widthAnchor.constraint(equalToConstant: 110),
            infoScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            composer.widthAnchor.constraint(equalTo: root.widthAnchor),
            composerField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    func show(item: DetailItem) {
        headerTitle.stringValue = item.title
        headerSubtitle.stringValue = item.subtitle
        headerTitle.setAccessibilityLabel(item.title)
        headerSubtitle.setAccessibilityLabel(item.subtitle)

        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        currentConversationID = nil
        messages = []
        messageTableView.reloadData()
        actionStack.arrangedSubviews.forEach { view in
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch item {
        case .conversation(let conversation):
            showConversation(conversation)
        case .contact(let contact):
            showContact(contact)
        case .channel(let channel):
            showChannel(channel)
        case .call(let call):
            showCall(call)
        }
    }

    private func showConversation(_ conversation: Conversation) {
        addHeaderButton(title: "Audio Call", symbol: "phone.fill", help: "Start an audio call with \(conversation.title).")
        addHeaderButton(title: "Video Call", symbol: "video.fill", help: "Start a video call with \(conversation.title).")
        addHeaderButton(title: "Info", symbol: "info.circle", help: "Show chat information.")

        messageScrollView.isHidden = false
        infoScrollView.isHidden = true
        view.layoutSubtreeIfNeeded()
        currentConversationID = conversation.id
        messageTableView.setAccessibilityLabel("Messages in \(conversation.title)")
        composerField.isEnabled = true
        sendButton.isEnabled = true
        attachButton.isEnabled = true
        recordButton.isEnabled = true

        loadMessages(for: conversation.id)
    }

    private func loadMessages(for conversationID: Int64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loadedMessages = try await telegramClient.loadMessages(chatID: conversationID)
                guard currentConversationID == conversationID else { return }
                replaceMessages(loadedMessages, selectLast: false)
            } catch {
                guard currentConversationID == conversationID else { return }
                print("Failed to load messages for chat \(conversationID): \(error.localizedDescription)")
                replaceMessages([], selectLast: false)
            }
        }
    }

    private func replaceMessages(_ newMessages: [Message], selectLast: Bool) {
        messages = newMessages
        messageTableView.reloadData()
        guard !messages.isEmpty else { return }

        let row = messages.count - 1
        messageTableView.scrollRowToVisible(row)

        if selectLast {
            messageTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            messageTableView.deselectAll(nil)
        }
    }

    private func reloadSelectedConversation() {
        guard let currentConversationID else { return }
        loadMessages(for: currentConversationID)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === messageTableView {
            playVoiceMessageIfPresent(at: messageTableView.selectedRow)
            return
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if view.hitTest(view.convert(event.locationInWindow, from: nil)) === messageTableView {
            reloadSelectedConversation()
        }
    }

    private func selectMessageRow(_ row: Int) {
        guard row >= 0, row < messages.count else { return }
        messageTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        messageTableView.scrollRowToVisible(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === messageTableView {
            if tableView.selectedRow == row {
                playVoiceMessageIfPresent(at: row)
            }
            return row >= 0 && row < messages.count
        }
        return true
    }

    private func playVoiceMessageIfPresent(at row: Int) {
        guard row >= 0, row < messages.count else { return }
        guard case .voice(_, _, let fileID) = messages[row].kind else { return }
        guard let fileID else {
            updatePlaybackStatus("Voice playback unavailable")
            return
        }

        if playingVoiceFileID == fileID, let audioPlayer {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                updatePlaybackStatus("Voice playback paused")
            } else {
                audioPlayer.play()
                updatePlaybackStatus("Playing voice message")
            }
            return
        }

        playbackTask?.cancel()
        audioPlayer?.stop()
        playingVoiceFileID = fileID
        updatePlaybackStatus("Downloading voice message")

        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await telegramClient.downloadVoiceMessage(fileID: fileID)
                guard !Task.isCancelled, playingVoiceFileID == fileID else { return }
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                player.enableRate = true
                player.rate = selectedPlaybackRate
                player.volume = Float(playbackVolumeSlider.doubleValue)
                player.prepareToPlay()
                audioPlayer = player
                player.play()
                updatePlaybackStatus("Playing voice message")
            } catch {
                guard !Task.isCancelled, playingVoiceFileID == fileID else { return }
                playingVoiceFileID = nil
                updatePlaybackStatus("Voice playback failed")
                announce("Couldn't play that voice message: \(error.localizedDescription)")
            }
        }
    }

    @objc func decreasePlaybackSpeed(_ sender: Any?) {
        adjustPlaybackSpeed(by: -1)
    }

    @objc func increasePlaybackSpeed(_ sender: Any?) {
        adjustPlaybackSpeed(by: 1)
    }

    @objc func decreasePlaybackVolume(_ sender: Any?) {
        adjustPlaybackVolume(by: -0.1)
    }

    @objc func increasePlaybackVolume(_ sender: Any?) {
        adjustPlaybackVolume(by: 0.1)
    }

    @objc private func playbackSpeedChanged() {
        audioPlayer?.rate = selectedPlaybackRate
        announce("Voice playback speed \(selectedPlaybackRate)x")
    }

    @objc private func playbackVolumeChanged() {
        audioPlayer?.volume = Float(playbackVolumeSlider.doubleValue)
        announce("Voice playback volume \(Int(playbackVolumeSlider.doubleValue * 100)) percent")
    }

    private func adjustPlaybackSpeed(by offset: Int) {
        let index = min(max(playbackSpeedPopUp.indexOfSelectedItem + offset, 0), Self.playbackRates.count - 1)
        playbackSpeedPopUp.selectItem(at: index)
        playbackSpeedChanged()
    }

    private func adjustPlaybackVolume(by offset: Double) {
        playbackVolumeSlider.doubleValue = min(max(playbackVolumeSlider.doubleValue + offset, 0), 1)
        playbackVolumeChanged()
    }

    private var selectedPlaybackRate: Float {
        Self.playbackRates[playbackSpeedPopUp.indexOfSelectedItem]
    }

    private func updatePlaybackStatus(_ status: String) {
        playbackStatusLabel.stringValue = status
        playbackStatusLabel.setAccessibilityLabel(status)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: view,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    fileprivate func playbackDidFinish(successfully: Bool) {
        playingVoiceFileID = nil
        audioPlayer = nil
        updatePlaybackStatus(successfully ? "Voice playback finished" : "Voice playback stopped")
    }

    private func showContact(_ contact: Contact) {
        addHeaderButton(title: "Message", symbol: "bubble.left.fill", help: "Open a chat with \(contact.name).")
        addHeaderButton(title: "Audio Call", symbol: "phone.fill", help: "Start an audio call with \(contact.name).")
        addHeaderButton(title: "Video Call", symbol: "video.fill", help: "Start a video call with \(contact.name).")

        messageScrollView.isHidden = true
        infoScrollView.isHidden = false
        contentStack.addArrangedSubview(InfoPanelView(rows: [
            ("Handle", contact.handle),
            ("Status", contact.status),
            ("Shared media", "18 photos, 3 voice messages")
        ]))
        composerField.isEnabled = false
        sendButton.isEnabled = false
        attachButton.isEnabled = false
        recordButton.isEnabled = false
    }

    private func showChannel(_ channel: Channel) {
        addHeaderButton(title: "Mute", symbol: "bell.slash.fill", help: "Mute notifications for \(channel.title).")
        addHeaderButton(title: "Info", symbol: "info.circle", help: "Show channel information.")

        messageScrollView.isHidden = true
        infoScrollView.isHidden = false
        contentStack.addArrangedSubview(InfoPanelView(rows: [
            ("Subscribers", channel.members),
            ("Latest post", channel.preview),
            ("Permissions", "Read-only channel preview")
        ]))
        composerField.isEnabled = false
        sendButton.isEnabled = false
        attachButton.isEnabled = false
        recordButton.isEnabled = false
    }

    private func showCall(_ call: CallRecord) {
        addHeaderButton(title: "Call Back", symbol: "phone.arrow.up.right.fill", help: "Call \(call.name) back.")
        addHeaderButton(title: "Message", symbol: "bubble.left.fill", help: "Open a chat with \(call.name).")

        messageScrollView.isHidden = true
        infoScrollView.isHidden = false
        contentStack.addArrangedSubview(InfoPanelView(rows: [
            ("Call type", call.status),
            ("Time", call.time),
            ("Result", call.missed ? "Missed" : "Completed")
        ]))
        composerField.isEnabled = false
        sendButton.isEnabled = false
        attachButton.isEnabled = false
        recordButton.isEnabled = false
    }

    @objc private func recordMessage() {
        let controller = RecordingDialogController()
        controller.onSend = { [weak self] duration in
            self?.appendRecordedVoiceMessage(duration: duration)
        }

        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Record Message"
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 420, height: 230))
        sheet.isReleasedWhenClosed = false
        recordingDialogController = controller

        view.window?.beginSheet(sheet) { [weak self] _ in
            self?.recordingDialogController = nil
        }
    }

    private func appendRecordedVoiceMessage(duration: TimeInterval) {
        guard let chatID = currentConversationID else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let message: Message
            do {
                message = try await telegramClient.sendVoiceMessage(duration: duration, chatID: chatID)
            } catch {
                return
            }

            guard currentConversationID == chatID else { return }
            appendMessageToTable(message)
        }
    }

    @objc private func sendTextMessage() {
        guard let chatID = currentConversationID else { return }
        let text = composerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerField.stringValue = ""

        Task { @MainActor [weak self] in
            guard let self else { return }
            let message: Message
            do {
                message = try await telegramClient.sendText(text, chatID: chatID)
            } catch {
                composerField.stringValue = text
                return
            }

            guard currentConversationID == chatID else { return }
            appendMessageToTable(message)
        }
    }

    private func appendMessageToTable(_ message: Message) {
        messages.append(message)
        messageTableView.reloadData()

        let row = messages.count - 1
        messageTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        messageTableView.scrollRowToVisible(row)
    }

    private func addHeaderButton(title: String, symbol: String, help: String) {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        actionStack.addArrangedSubview(button)
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        messages.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = MessageTableCellView()
        cell.configure(message: messages[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch messages[row].kind {
        case .text:
            return 92
        case .voice:
            return 124
        case .media:
            return 92
        }
    }
}

extension DetailViewController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.playbackDidFinish(successfully: flag)
        }
    }
}

final class IconTextCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = BadgeLabel()
    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(iconName: String, title: String, subtitle: String?, badge: String?) {
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: title)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil
        badgeLabel.stringValue = badge ?? ""
        badgeLabel.isHidden = badge == nil
    }

    private func setup() {
        iconView.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.spacing = 2

        let row = NSStackView(views: [iconView, textStack, badgeLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }
}

final class BadgeLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        backgroundColor = .controlAccentColor
        textColor = .alternateSelectedControlTextColor
        font = .systemFont(ofSize: 11, weight: .semibold)
        alignment = .center
        lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.cornerRadius = 9
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class AuthenticationPromptController: NSViewController {
    var onSubmit: ((String) -> Void)?

    private let promptTitle: String
    private let promptMessage: String
    private let placeholder: String
    private let isSecure: Bool
    private let inputField: NSTextField
    private let errorLabel = NSTextField(labelWithString: "")
    private let submitButton = NSButton(title: "Continue", target: nil, action: nil)

    init(title: String, message: String, placeholder: String, isSecure: Bool) {
        promptTitle = title
        promptMessage = message
        self.placeholder = placeholder
        self.isSecure = isSecure
        inputField = isSecure ? NSSecureTextField() : NSTextField()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: promptTitle)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setAccessibilityLabel(promptTitle)

        let messageLabel = NSTextField(wrappingLabelWithString: promptMessage)
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.setAccessibilityLabel(promptMessage)

        inputField.placeholderString = placeholder
        inputField.setAccessibilityLabel(promptTitle)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true
        errorLabel.setAccessibilityRole(.staticText)

        submitButton.bezelStyle = .rounded
        submitButton.target = self
        submitButton.action = #selector(submit)
        submitButton.keyEquivalent = "\r"
        submitButton.setAccessibilityLabel("Continue")

        let stack = NSStackView(views: [titleLabel, messageLabel, inputField, errorLabel, submitButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(inputField)
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.setAccessibilityLabel(message)
        errorLabel.isHidden = false
        NSAccessibility.post(
            element: errorLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    @objc private func submit() {
        let value = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            showError("This field is required.")
            return
        }
        errorLabel.isHidden = true
        onSubmit?(value)
    }
}

/// First-run / revisit screen for entering Telegram API credentials. Built entirely in
/// code with the same accessibility contract as the rest of the app: every control has an
/// explicit label/help, the field order reads top-to-bottom under VoiceOver, validation
/// errors are announced at high priority, and focus lands on the first field on appear.
final class AccountSetupController: NSViewController {
    enum Outcome {
        case credentials(apiID: Int, apiHash: String, useTestDataCenter: Bool)
        case useSampleData
    }

    var onComplete: ((Outcome) -> Void)?

    private let showsSampleDataOption: Bool
    private let apiIDField = NSTextField()
    private let apiHashField = NSTextField()
    private let testDCCheckbox = NSButton(checkboxWithTitle: "Use Telegram test servers", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let sampleDataButton = NSButton(title: "Use Sample Data Instead", target: nil, action: nil)

    init(showsSampleDataOption: Bool) {
        self.showsSampleDataOption = showsSampleDataOption
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "Set Up CocoGram")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setAccessibilityLabel("Set Up CocoGram")

        let messageLabel = NSTextField(wrappingLabelWithString: "Enter the API credentials from my.telegram.org to connect your Telegram account.")
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.setAccessibilityLabel("Enter the API credentials from my dot telegram dot org to connect your Telegram account.")

        let idCaption = NSTextField(labelWithString: "API ID")
        idCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        idCaption.textColor = .secondaryLabelColor
        idCaption.setAccessibilityElement(false)
        apiIDField.placeholderString = "API ID (numbers)"
        apiIDField.setAccessibilityLabel("API ID")
        apiIDField.setAccessibilityHelp("The numeric api_id from my.telegram.org.")

        let hashCaption = NSTextField(labelWithString: "API Hash")
        hashCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        hashCaption.textColor = .secondaryLabelColor
        hashCaption.setAccessibilityElement(false)
        apiHashField.placeholderString = "API Hash"
        apiHashField.setAccessibilityLabel("API Hash")
        apiHashField.setAccessibilityHelp("The api_hash string from my.telegram.org.")

        testDCCheckbox.setAccessibilityLabel("Use Telegram test servers")
        testDCCheckbox.setAccessibilityHelp("Connect to Telegram's isolated test data center instead of your real account. Leave off for normal use.")

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true
        errorLabel.setAccessibilityRole(.staticText)

        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(submit)
        continueButton.setAccessibilityLabel("Continue")
        continueButton.setAccessibilityHelp("Save these credentials and connect to Telegram.")

        let buttonRow = NSStackView(views: [continueButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        if showsSampleDataOption {
            sampleDataButton.bezelStyle = .rounded
            sampleDataButton.target = self
            sampleDataButton.action = #selector(useSampleData)
            sampleDataButton.setAccessibilityLabel("Use sample data instead")
            sampleDataButton.setAccessibilityHelp("Skip setup and explore CocoGram with built-in sample conversations. You can add your account later from the application menu.")
            buttonRow.insertArrangedSubview(sampleDataButton, at: 0)
        }

        let stack = NSStackView(views: [
            titleLabel, messageLabel,
            idCaption, apiIDField,
            hashCaption, apiHashField,
            testDCCheckbox, errorLabel, buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 22, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: messageLabel)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            apiIDField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            apiHashField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(apiIDField)
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.setAccessibilityLabel(message)
        errorLabel.isHidden = false
        NSAccessibility.post(
            element: errorLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    @objc private func submit() {
        let idText = apiIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = apiHashField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !idText.isEmpty, !hash.isEmpty else {
            showError("Both API ID and API Hash are required.")
            return
        }
        guard let apiID = Int(idText) else {
            showError("API ID must be a number, like 36271916.")
            return
        }

        errorLabel.isHidden = true
        onComplete?(.credentials(apiID: apiID, apiHash: hash, useTestDataCenter: testDCCheckbox.state == .on))
    }

    @objc private func useSampleData() {
        onComplete?(.useSampleData)
    }
}

final class RecordingDialogController: NSViewController {
    enum RecordingState {
        case recording
        case paused
        case stopped
        case playing
    }

    var onSend: ((TimeInterval) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let playPauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private var state: RecordingState = .recording
    private var elapsedSeconds: Int = 0
    private var timer: Timer?

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "Record Message")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setAccessibilityLabel("Record message")

        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.setAccessibilityRole(.staticText)

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        elapsedLabel.alignment = .center
        elapsedLabel.setAccessibilityRole(.staticText)

        playPauseButton.bezelStyle = .rounded
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayPause)

        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopRecording)

        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendRecording)
        sendButton.setAccessibilityHelp("Sends this recorded voice message.")

        let controls = NSStackView(views: [playPauseButton, stopButton, sendButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fillEqually
        controls.spacing = 10

        let stack = NSStackView(views: [titleLabel, statusLabel, elapsedLabel, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            elapsedLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        updateState(.recording)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startTimer()
        NSAccessibility.post(
            element: statusLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Recording started",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
    }

    @objc private func togglePlayPause() {
        switch state {
        case .recording:
            updateState(.paused)
            timer?.invalidate()
        case .paused:
            updateState(.recording)
            startTimer()
        case .stopped:
            updateState(.playing)
            startTimer()
        case .playing:
            updateState(.stopped)
            timer?.invalidate()
        }
    }

    @objc private func stopRecording() {
        timer?.invalidate()
        updateState(.stopped)
    }

    @objc private func sendRecording() {
        timer?.invalidate()
        onSend?(TimeInterval(elapsedSeconds))
        closeSheet()
    }

    private func updateState(_ newState: RecordingState) {
        state = newState

        switch state {
        case .recording:
            statusLabel.stringValue = "Recording"
            playPauseButton.title = "Pause"
            playPauseButton.setAccessibilityLabel("Pause recording")
            playPauseButton.setAccessibilityHelp("Pauses the current voice message recording.")
            stopButton.isEnabled = true
            sendButton.isEnabled = true
        case .paused:
            statusLabel.stringValue = "Recording paused"
            playPauseButton.title = "Record"
            playPauseButton.setAccessibilityLabel("Resume recording")
            playPauseButton.setAccessibilityHelp("Resumes recording this voice message.")
            stopButton.isEnabled = true
            sendButton.isEnabled = true
        case .stopped:
            statusLabel.stringValue = "Recording stopped"
            playPauseButton.title = "Play"
            playPauseButton.setAccessibilityLabel("Play recording")
            playPauseButton.setAccessibilityHelp("Plays the recorded voice message preview.")
            stopButton.isEnabled = false
            sendButton.isEnabled = true
        case .playing:
            statusLabel.stringValue = "Playing recording"
            playPauseButton.title = "Pause"
            playPauseButton.setAccessibilityLabel("Pause playback")
            playPauseButton.setAccessibilityHelp("Pauses playback of the recorded voice message preview.")
            stopButton.isEnabled = false
            sendButton.isEnabled = true
        }

        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
        updateElapsedLabel()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tickElapsed), userInfo: nil, repeats: true)
    }

    @objc private func tickElapsed() {
        elapsedSeconds += 1
        updateElapsedLabel()
    }

    private func updateElapsedLabel() {
        elapsedLabel.stringValue = String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
        elapsedLabel.setAccessibilityLabel("Elapsed time \(Message.format(TimeInterval(elapsedSeconds)))")
    }

    private func closeSheet() {
        guard let window = view.window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window.close()
    }
}

final class MessageTableCellView: NSTableCellView {
    private let senderLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let voiceContainer = NSStackView()
    private let voiceTranscriptLabel = NSTextField(wrappingLabelWithString: "")
    private let mediaContainer = NSStackView()
    private let mediaIcon = NSImageView()
    private let mediaLabel = NSTextField(labelWithString: "")
    private var accessibilitySummary = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(message: Message) {
        accessibilitySummary = message.accessibilitySummary
        setAccessibilityLabel(accessibilitySummary)

        senderLabel.stringValue = message.isOutgoing ? "You" : message.sender
        timeLabel.stringValue = message.time
        statusLabel.stringValue = message.outgoingStatus?.rawValue ?? ""
        statusLabel.isHidden = !message.isOutgoing || message.outgoingStatus == nil

        switch message.kind {
        case .text(let body):
            bodyLabel.stringValue = body
            bodyLabel.isHidden = false
            voiceContainer.isHidden = true
            mediaContainer.isHidden = true
        case .voice(let duration, let transcript, _):
            bodyLabel.isHidden = true
            voiceContainer.isHidden = false
            mediaContainer.isHidden = true
            voiceTranscriptLabel.stringValue = "Voice message, \(Message.format(duration)). \(transcript)"
        case .media(let icon, let label):
            bodyLabel.isHidden = true
            voiceContainer.isHidden = true
            mediaContainer.isHidden = false
            mediaIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            mediaLabel.stringValue = label
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityHelp("Message")

        senderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        senderLabel.textColor = .secondaryLabelColor
        senderLabel.setAccessibilityElement(false)

        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.setAccessibilityElement(false)
        // Wrap (don't expand) so a long message can never drive the cell/column/window
        // width. Low horizontal compression resistance lets the column shrink below the
        // text's natural single-line width; preferredMaxLayoutWidth gives wrapping a target.
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.preferredMaxLayoutWidth = 360
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bodyLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.setAccessibilityElement(false)

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.setAccessibilityElement(false)

        let metadataStack = NSStackView(views: [timeLabel, statusLabel])
        metadataStack.orientation = .horizontal
        metadataStack.alignment = .centerY
        metadataStack.spacing = 8
        metadataStack.setAccessibilityElement(false)

        let playIcon = NSImageView(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage())
        playIcon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        playIcon.contentTintColor = .controlAccentColor
        playIcon.setAccessibilityElement(false)

        voiceTranscriptLabel.font = .systemFont(ofSize: 13)
        voiceTranscriptLabel.textColor = .secondaryLabelColor
        voiceTranscriptLabel.maximumNumberOfLines = 2
        voiceTranscriptLabel.setAccessibilityElement(false)

        voiceContainer.orientation = .horizontal
        voiceContainer.alignment = .centerY
        voiceContainer.spacing = 8
        voiceContainer.addArrangedSubview(playIcon)
        voiceContainer.addArrangedSubview(voiceTranscriptLabel)
        voiceContainer.setAccessibilityElement(false)

        mediaIcon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        mediaIcon.contentTintColor = .controlAccentColor
        mediaIcon.setAccessibilityElement(false)

        mediaLabel.font = .systemFont(ofSize: 14)
        mediaLabel.lineBreakMode = .byTruncatingTail
        mediaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mediaLabel.setAccessibilityElement(false)

        mediaContainer.orientation = .horizontal
        mediaContainer.alignment = .centerY
        mediaContainer.spacing = 8
        mediaContainer.addArrangedSubview(mediaIcon)
        mediaContainer.addArrangedSubview(mediaLabel)
        mediaContainer.setAccessibilityElement(false)

        let stack = NSStackView(views: [senderLabel, bodyLabel, voiceContainer, mediaContainer, metadataStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func accessibilityLabel() -> String? {
        accessibilitySummary
    }
}

final class MessageBubbleView: NSView {
    private let message: Message

    init(message: Message) {
        self.message = message
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = (message.isOutgoing ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.controlBackgroundColor).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message.accessibilitySummary)
        setAccessibilityHelp("A chat message. Use VoiceOver left or right to move between messages.")

        let sender = NSTextField(labelWithString: message.isOutgoing ? "You" : message.sender)
        sender.font = .systemFont(ofSize: 12, weight: .semibold)
        sender.textColor = .secondaryLabelColor
        sender.setAccessibilityElement(false)

        let bodyView: NSView
        switch message.kind {
        case .text(let body):
            let text = NSTextField(wrappingLabelWithString: body)
            text.font = .systemFont(ofSize: 14)
            text.maximumNumberOfLines = 0
            text.setAccessibilityElement(false)
            bodyView = text
        case .voice(let duration, let transcript, _):
            bodyView = VoiceMessageView(duration: duration, transcript: transcript)
            bodyView.setAccessibilityElement(false)
        case .media(let icon, let label):
            let iconView = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil) ?? NSImage())
            iconView.contentTintColor = .controlAccentColor
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 14)
            text.lineBreakMode = .byTruncatingTail
            let row = NSStackView(views: [iconView, text])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.setAccessibilityElement(false)
            bodyView = row
        }

        let time = NSTextField(labelWithString: message.time)
        time.font = .systemFont(ofSize: 11)
        time.textColor = .tertiaryLabelColor
        time.setAccessibilityElement(false)

        let stack = NSStackView(views: [sender, bodyView, time])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

final class VoiceMessageView: NSView {
    init(duration: TimeInterval, transcript: String) {
        super.init(frame: .zero)
        setup(duration: duration, transcript: transcript)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setup(duration: TimeInterval, transcript: String) {
        let playButton = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play voice message") ?? NSImage(), target: nil, action: nil)
        playButton.bezelStyle = .texturedRounded
        playButton.setAccessibilityElement(false)

        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = duration
        progress.doubleValue = 0
        progress.controlSize = .small
        progress.setAccessibilityElement(false)

        let durationLabel = NSTextField(labelWithString: Message.format(duration))
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.setAccessibilityElement(false)

        let row = NSStackView(views: [playButton, progress, durationLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let transcriptLabel = NSTextField(wrappingLabelWithString: transcript)
        transcriptLabel.font = .systemFont(ofSize: 13)
        transcriptLabel.textColor = .secondaryLabelColor
        transcriptLabel.setAccessibilityElement(false)

        let stack = NSStackView(views: [row, transcriptLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.widthAnchor.constraint(equalToConstant: 180)
        ])
    }
}

final class InfoPanelView: NSView {
    init(rows: [(String, String)]) {
        super.init(frame: .zero)
        setup(rows: rows)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setup(rows: [(String, String)]) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        setAccessibilityRole(.group)
        setAccessibilityLabel(rows.map { "\($0.0), \($0.1)" }.joined(separator: ". "))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (label, value) in rows {
            let labelField = NSTextField(labelWithString: label)
            labelField.font = .systemFont(ofSize: 12, weight: .semibold)
            labelField.textColor = .secondaryLabelColor

            let valueField = NSTextField(wrappingLabelWithString: value)
            valueField.font = .systemFont(ofSize: 15)

            let row = NSStackView(views: [labelField, valueField])
            row.orientation = .vertical
            row.spacing = 3
            row.setAccessibilityRole(.group)
            row.setAccessibilityLabel("\(label), \(value)")
            stack.addArrangedSubview(row)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
