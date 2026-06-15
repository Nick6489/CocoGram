import AppKit
@preconcurrency import AVFoundation
import AVKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var telegramClient: TelegramClient!
    private var callController: CallController?
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    private var authSheet: NSWindow?
    private var authSheetState: TelegramAuthorizationState?
    private var lastAuthState: TelegramAuthorizationState?
    private var isTerminating = false
    private var sessionRestartTimestamps: [Date] = []

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

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        telegramClient?.stop()
        TDLibTelegramClient.shutdownAllClients()
    }

    /// Builds the main window for the chosen client and starts the Telegram event loop.
    /// Also used to restart with a fresh client after TDLib closes itself (server-side
    /// logout); the replacement window is shown before the old one closes so
    /// `applicationShouldTerminateAfterLastWindowClosed` never sees zero windows.
    private func startSession(with client: TelegramClient) {
        let previousWindowController = windowController
        let previousAuthSheet = authSheet
        authSheet = nil
        authSheetState = nil
        lastAuthState = nil

        telegramClient = client
        callController = CallController(telegramClient: client)
        let controller = MainWindowController(telegramClient: client)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        windowController = controller
        callController?.setParentWindow(controller.window)
        if let previousAuthSheet, let previousWindow = previousWindowController?.window {
            previousWindow.endSheet(previousAuthSheet)
        }
        previousWindowController?.close()

        Task {
            do {
                try await client.start()
            } catch {
                presentStartupFailure(error.localizedDescription)
            }
        }
        Task {
            await observeTelegramUpdates(from: client)
        }
    }

    /// Presents the first-run / revisit credential setup screen in its own window. The
    /// "use sample data" escape hatch is offered only on first run (before a session
    /// exists); revisiting from the menu just saves and asks the user to relaunch.
    @objc func showAccountSetup() {
        presentAccountSetup()
    }

    /// Opens (or re-focuses) the Settings window. Standard macOS Settings — currently the
    /// microphone-input picker for voice messages.
    @objc func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "CocoGram Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        // Track close so the next Cmd+, builds a fresh controller with a current device
        // list. The notification is delivered on the main queue, so it is safe to touch
        // main-actor state via assumeIsolated. The token lives in a property and is removed
        // on close so observers don't accumulate across repeated opens.
        if let existing = settingsCloseObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsWindow = nil
                if let observer = self.settingsCloseObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.settingsCloseObserver = nil
                }
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        // Standard macOS Settings item (Cmd+,). Hosts microphone-input selection.
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.setAccessibilityHelp("Choose which microphone records voice messages.")
        appMenu.addItem(.separator())
        let setup = appMenu.addItem(withTitle: "Set Up Telegram Account…", action: #selector(showAccountSetup), keyEquivalent: "")
        setup.target = self
        setup.setAccessibilityHelp("Enter or change your Telegram API credentials.")
        let signIn = appMenu.addItem(withTitle: "Sign In to Telegram…", action: #selector(showSignInPrompt), keyEquivalent: "")
        signIn.target = self
        signIn.setAccessibilityHelp("Reopen the prompt for the current Telegram sign-in step, such as the phone number or login code.")
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

    private func observeTelegramUpdates(from client: TelegramClient) async {
        for await update in client.updates {
            switch update {
            case .authorizationStateChanged(let state):
                handleAuthorizationState(state)
            case .chatsChanged(let conversations):
                windowController?.applyChats(conversations)
            case .messagesChanged(let chatID, let messages):
                windowController?.applyIncomingMessages(chatID: chatID, messages: messages)
            case .callChanged(let call):
                callController?.setParentWindow(windowController?.window)
                callController?.handle(call)
            case .callSignalingData(let callID, let data):
                callController?.handleSignalingData(data, callID: callID)
            case .startupStalled(let message):
                announce(message)
            case .startupFailed(let message):
                presentStartupFailure(message)
            }
        }
    }

    private func handleAuthorizationState(_ state: TelegramAuthorizationState) {
        lastAuthState = state
        switch state {
        case .waitingForParameters:
            break
        case .waitingForPhoneNumber:
            presentAuthenticationPrompt(
                for: state,
                title: "Telegram Phone Number",
                message: "Enter your Telegram phone number in international format.",
                placeholder: "+15551234567",
                isSecure: false
            ) { [weak self] value in
                try await self?.telegramClient.submitPhoneNumber(value)
            }
        case .waitingForCode:
            presentAuthenticationPrompt(
                for: state,
                title: "Telegram Code",
                message: "Enter the login code Telegram sent you.",
                placeholder: "Login code",
                isSecure: false
            ) { [weak self] value in
                try await self?.telegramClient.submitAuthenticationCode(value)
            }
        case .waitingForPassword:
            presentAuthenticationPrompt(
                for: state,
                title: "Telegram Password",
                message: "Enter your two-step verification password.",
                placeholder: "Password",
                isSecure: true
            ) { [weak self] value in
                try await self?.telegramClient.submitPassword(value)
            }
        case .ready:
            dismissAuthSheet()
            sessionRestartTimestamps = []
            windowController?.showChats()
        case .loggingOut:
            dismissAuthSheet()
            announce("Telegram is signing this device out. You will be asked to sign in again.")
        case .closed:
            dismissAuthSheet()
            restartSessionAfterRemoteLogout()
        case .unknown(let description):
            announce("Telegram asked for a sign-in step CocoGram doesn't support yet: \(description)")
        }
    }

    /// TDLib closes itself after a server-side logout (revoked session, terminated from
    /// another device), having destroyed its local database. A closed client can never
    /// recover, so unless the app is quitting, a fresh client is started — which lands in
    /// the normal sign-in flow instead of leaving a working-looking but dead window.
    private func restartSessionAfterRemoteLogout() {
        guard !isTerminating else { return }
        guard let configuration = TDLibConfiguration.resolve() else {
            presentStartupFailure("Your Telegram session ended, and CocoGram's API credentials could not be found to sign in again. Choose Set Up Telegram Account from the CocoGram menu.")
            return
        }

        let now = Date()
        sessionRestartTimestamps = sessionRestartTimestamps.filter { now.timeIntervalSince($0) < 60 }
        sessionRestartTimestamps.append(now)
        guard sessionRestartTimestamps.count <= 2 else {
            presentStartupFailure("Telegram keeps closing the session. Quit CocoGram and reopen it; if this continues, check ~/Library/Application Support/CocoGram/tdlib for details in tdlib.log.")
            return
        }

        telegramClient?.stop()
        startSession(with: TDLibTelegramClient(configuration: configuration))
        announce("Your Telegram session ended. Please sign in again.")
    }

    /// Surfaces a fatal client-startup problem (database locked by another running copy,
    /// unusable storage directory) that previously vanished into a silent, empty window.
    private func presentStartupFailure(_ message: String) {
        guard !isTerminating else { return }
        announce("CocoGram couldn't connect to Telegram. \(message)")

        let alert = NSAlert()
        alert.messageText = "CocoGram couldn't connect to Telegram"
        alert.informativeText = "\(message)\n\nIf another copy of CocoGram is running, quit it and reopen this one."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit CocoGram")
        alert.addButton(withTitle: "Continue Anyway")

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                NSApp.terminate(nil)
            }
        }
        if let window = windowController?.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// Re-presents the prompt for the current sign-in step. Reachable from the app menu
    /// so a dismissed sheet (close button or Cmd+W) is recoverable instead of leaving the
    /// session stuck halfway through authentication.
    @objc private func showSignInPrompt() {
        switch lastAuthState {
        case .waitingForPhoneNumber, .waitingForCode, .waitingForPassword:
            handleAuthorizationState(lastAuthState!)
        case .unknown(let description):
            announce("Telegram is asking for a sign-in step CocoGram doesn't support yet: \(description). Try signing in from another Telegram app first.")
        default:
            announce("Telegram is not asking for sign-in right now.")
        }
    }

    private func presentAuthenticationPrompt(
        for state: TelegramAuthorizationState,
        title: String,
        message: String,
        placeholder: String,
        isSecure: Bool,
        submit: @escaping (String) async throws -> Void
    ) {
        guard let parentWindow = windowController?.window else { return }
        // The newest authorization state always wins: TDLib can emit the next state
        // (e.g. waitCode) before the previous submission's response arrives, and a
        // dropped prompt would strand the login with no way to continue.
        if authSheet != nil, authSheetState == state { return }
        dismissAuthSheet()

        let controller = AuthenticationPromptController(
            title: title,
            message: message,
            placeholder: placeholder,
            isSecure: isSecure
        )
        let sheet = NSWindow(contentViewController: controller)
        controller.onSubmit = { [weak self, weak sheet] value in
            Task { @MainActor in
                do {
                    try await submit(value)
                    // Dismiss only if this sheet is still the active prompt — the next
                    // auth state may already have replaced it.
                    if let self, let sheet, self.authSheet === sheet {
                        self.dismissAuthSheet()
                    }
                } catch {
                    controller.showError(error.localizedDescription)
                }
            }
        }

        sheet.title = title
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(NSSize(width: 430, height: 220))
        sheet.isReleasedWhenClosed = false
        authSheet = sheet
        authSheetState = state
        parentWindow.beginSheet(sheet) { [weak self] _ in
            guard let self else { return }
            // Still tracked here means the user closed the sheet themselves (close
            // button or Cmd+W); programmatic dismissals clear the tracking first.
            if self.authSheet === sheet {
                self.authSheet = nil
                self.authSheetState = nil
                self.announce("Sign-in canceled. Choose Sign In to Telegram from the CocoGram menu to continue.")
            }
        }
    }

    private func dismissAuthSheet() {
        guard let sheet = authSheet else { return }
        authSheet = nil
        authSheetState = nil
        windowController?.window?.endSheet(sheet)
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

    func applyChats(_ conversations: [Conversation]) {
        (contentViewController as? RootViewController)?.applyChats(conversations)
    }

    func applyIncomingMessages(chatID: Int64, messages: [Message]) {
        (contentViewController as? RootViewController)?.applyIncomingMessages(chatID: chatID, messages: messages)
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

    func applyChats(_ conversations: [Conversation]) {
        listController.applyChats(conversations)
    }

    func applyIncomingMessages(chatID: Int64, messages: [Message]) {
        detailController.applyIncomingMessages(chatID: chatID, messages: messages)
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
    private var hasLoadedItemsOnce = false

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
                self.hasLoadedItemsOnce = true
                self.items = loadedItems
                self.tableView.reloadData()
                if !loadedItems.isEmpty {
                    self.selectItem(at: self.initialSelectionIndex(in: loadedItems, for: section))
                }
            } catch {
                guard self.section == section else { return }
                self.items = []
                self.tableView.reloadData()
                self.titleLabel.stringValue = "\(section.rawValue) unavailable"
                // Only a regression from a previously working list is worth announcing.
                // The first load on a live client predictably fails (it races client
                // startup, before sign-in), and barking a false alarm at every launch
                // would teach the user to ignore the announcement that matters.
                if self.hasLoadedItemsOnce {
                    NSAccessibility.post(
                        element: self.view,
                        notification: .announcementRequested,
                        userInfo: [
                            .announcement: "\(section.rawValue) could not be loaded. \(error.localizedDescription)",
                            .priority: NSAccessibilityPriorityLevel.high.rawValue
                        ]
                    )
                }
            }
        }
    }

    /// Refreshes the chat list in place from a pushed update, preserving the current
    /// selection. Unlike `show(section:)` this never clears the table first, so live
    /// updates don't blank the list (and yank VoiceOver focus) while a reload runs.
    func applyChats(_ conversations: [Conversation]) {
        guard section == .chats else { return }
        let newItems = conversations.map(DetailItem.conversation)
        // Reloading rebuilds every row's accessibility element, which shoves the
        // VoiceOver cursor off the list — never do it for a no-op refresh.
        guard newItems != items else { return }
        titleLabel.stringValue = section.rawValue
        hasLoadedItemsOnce = true

        let selectedConversationID: Int64?
        if case .conversation(let conversation)? = selectedItem {
            selectedConversationID = conversation.id
        } else {
            selectedConversationID = nil
        }

        let wasEmpty = items.isEmpty
        items = newItems
        tableView.reloadData()

        if let selectedConversationID,
           let row = items.firstIndex(where: { item in
               guard case .conversation(let conversation) = item else { return false }
               return conversation.id == selectedConversationID
           }) {
            selectedItem = items[row]
            isSelectingProgrammatically = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isSelectingProgrammatically = false
        } else if wasEmpty, !items.isEmpty {
            selectItem(at: initialSelectionIndex(in: items, for: .chats))
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
    private let playbackControls = NSStackView()
    private let playbackSeparator = NSBox()
    private var recordingDialogController: RecordingDialogController?
    /// Closures backing the header action buttons (call, info, …), indexed by button tag.
    private var headerButtonActions: [() -> Void] = []
    /// Debounces the call button so rapid clicks can't fire duplicate createCall requests.
    private var isStartingCall = false
    private var messages: [Message] = []
    private var currentConversationID: Int64?
    /// The in-flight history load. A cold chat's load polls TDLib for up to a few seconds
    /// (see `loadRecentHistory`), so switching chats rapidly must cancel the prior load —
    /// otherwise overlapping poll loops pile up on the main actor doing discarded work.
    private var messageLoadTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var playingVoiceFileID: Int?
    private var playbackTask: Task<Void, Never>?
    private var decodedVoiceMessageURL: URL?

    /// Downloads + caches inline media images (photos, stickers, video posters) by file id.
    private lazy var imageLoader = MediaImageLoader { [weak self] fileID in
        guard let self else { throw CocoaError(.fileNoSuchFile) }
        return try await self.telegramClient.downloadFile(fileID: fileID)
    }
    /// Inline video playback. The player and its view live on the controller (not in a cell)
    /// so playback survives table reloads and cell recycling; the view is re-attached to
    /// whichever cell currently shows the playing message. Nothing ever autoplays.
    private var videoPlayer: AVPlayer?
    private var videoPlayerView: AVPlayerView?
    private var playingVideoMessageID: Int64?
    private var videoDownloadTask: Task<Void, Never>?
    /// Scroll-back pagination state for the open conversation.
    private var isLoadingOlder = false
    private var reachedStartOfHistory = false

    init(telegramClient: TelegramClient) {
        self.telegramClient = telegramClient
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        // The scroll observer is registered against this controller; drop it so a replaced
        // controller (e.g. after a session restart) leaves nothing dangling in NotificationCenter.
        NotificationCenter.default.removeObserver(self)
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
        // Rows size themselves to their content (see MessageTableCellView's top-to-bottom
        // constraint chain). The old fixed 104pt row + 8pt gap padded every short message with
        // dead space; self-sizing + a hairline gap keeps messages tight, like the official app.
        messageTableView.usesAutomaticRowHeights = true
        messageTableView.intercellSpacing = NSSize(width: 0, height: 2)
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
        // Stream older history in as the user scrolls back toward the top.
        messageScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(messageScrollDidChange),
            name: NSView.boundsDidChangeNotification,
            object: messageScrollView.contentView
        )

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

        playbackControls.setViews([playbackStatusLabel, NSView(), speedLabel, playbackSpeedPopUp, volumeLabel, playbackVolumeSlider], in: .leading)
        playbackControls.orientation = .horizontal
        playbackControls.alignment = .centerY
        playbackControls.spacing = 8
        playbackControls.edgeInsets = NSEdgeInsets(top: 8, left: 22, bottom: 8, right: 22)
        playbackControls.isHidden = true
        playbackSeparator.boxType = .separator
        playbackSeparator.isHidden = true

        let composer = NSStackView(views: [attachButton, composerField, recordButton, sendButton])
        composer.orientation = .horizontal
        composer.alignment = .centerY
        composer.spacing = 8
        composer.edgeInsets = NSEdgeInsets(top: 12, left: 22, bottom: 16, right: 22)

        let root = NSStackView(views: [header, separator(), messageScrollView, infoScrollView, separator(), playbackControls, playbackSeparator, composer])
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
        if case .conversation(let conversation) = item {
            if currentConversationID != conversation.id {
                stopVoicePlayback()
                stopVideoPlayback()
            }
        } else {
            stopVoicePlayback()
            stopVideoPlayback()
        }
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
        headerButtonActions = []

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
        addHeaderButton(title: "Audio Call", symbol: "phone.fill", help: "Start an audio call with \(conversation.title).") { [weak self] in
            self?.startCall(isVideo: false)
        }
        addHeaderButton(title: "Video Call", symbol: "video.fill", help: "Start a video call with \(conversation.title).") { [weak self] in
            self?.startCall(isVideo: true)
        }
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
        // Cancel any prior in-flight load: a cold chat polls TDLib for a few seconds, and a
        // fast chat switch would otherwise leave the previous poll loop running for nothing.
        messageLoadTask?.cancel()
        messageLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loadedMessages = try await telegramClient.loadMessages(chatID: conversationID)
                guard !Task.isCancelled, currentConversationID == conversationID else { return }
                replaceMessages(loadedMessages, selectLast: false)
            } catch {
                guard !Task.isCancelled, currentConversationID == conversationID else { return }
                print("Failed to load messages for chat \(conversationID): \(error.localizedDescription)")
                replaceMessages([], selectLast: false)
            }
        }
    }

    private func replaceMessages(_ newMessages: [Message], selectLast: Bool) {
        // Fresh history for this chat: pagination starts over.
        reachedStartOfHistory = false
        isLoadingOlder = false
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

    @objc private func messageScrollDidChange() {
        loadOlderMessagesIfNeeded()
    }

    /// When the viewport nears the top of the loaded history, stream in the next older page.
    /// `force` bypasses the scroll-position check (used by the headless render test).
    func loadOlderMessagesIfNeeded(force: Bool = false) {
        guard !isLoadingOlder, !reachedStartOfHistory else { return }
        guard let chatID = currentConversationID, let oldest = messages.first else { return }

        if !force {
            // "Near the top" — within roughly one screenful of the start, to prefetch the next
            // older page before the user reaches the very top.
            let offsetY = messageScrollView.contentView.bounds.origin.y
            guard offsetY < messageScrollView.contentView.bounds.height else { return }
        }

        isLoadingOlder = true
        let beforeID = oldest.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingOlder = false }
            let older = (try? await telegramClient.loadOlderMessages(chatID: chatID, beforeMessageID: beforeID)) ?? []
            // Bail if the chat changed or this page is stale.
            guard currentConversationID == chatID, messages.first?.id == beforeID else { return }
            if older.isEmpty {
                reachedStartOfHistory = true
                return
            }
            prependOlderMessages(older)
        }
    }

    /// Inserts an older page above the current history while keeping the viewport visually
    /// anchored on the message the user was looking at (so it doesn't jump to the top).
    private func prependOlderMessages(_ older: [Message]) {
        let clipView = messageScrollView.contentView
        messageTableView.layoutSubtreeIfNeeded()
        let heightBefore = messageTableView.bounds.height
        let offsetBefore = clipView.bounds.origin

        messages = older + messages
        messageTableView.reloadData()
        messageTableView.layoutSubtreeIfNeeded()

        // Rows were added above; shift the scroll origin down by the inserted height so the
        // previously-visible messages stay put (the document is flipped, top-anchored).
        let heightAfter = messageTableView.bounds.height
        let delta = heightAfter - heightBefore
        clipView.setBoundsOrigin(NSPoint(x: offsetBefore.x, y: offsetBefore.y + delta))
        messageScrollView.reflectScrolledClipView(clipView)
    }

    /// Begins inline playback of a video/animation. Downloads (and caches) the file first;
    /// nothing autoplays — playback only starts here, in response to an explicit activation.
    private func playVideo(_ media: VideoMedia, messageID: Int64) {
        // Re-activating the message that is already playing/loading: toggle once the player
        // exists, otherwise ignore (a download is in flight — don't restart it).
        if playingVideoMessageID == messageID {
            if let videoPlayer {
                if videoPlayer.rate == 0 {
                    videoPlayer.play()
                    announce("Playing video")
                } else {
                    videoPlayer.pause()
                    announce("Video paused")
                }
            }
            return
        }

        stopVideoPlayback()
        playingVideoMessageID = messageID
        announce("Downloading video")
        setVideoDownloadingIndicator(true, messageID: messageID)
        videoDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await telegramClient.downloadFile(fileID: media.videoFileID)
                guard !Task.isCancelled, playingVideoMessageID == messageID else { return }
                let player = AVPlayer(url: url)
                let playerView = AVPlayerView()
                playerView.player = player
                playerView.controlsStyle = .inline
                playerView.videoGravity = .resizeAspect
                playerView.setAccessibilityLabel("Video player")
                videoPlayer = player
                videoPlayerView = playerView
                // Swap the poster for the player IN PLACE on the live cell — no reloadData, which
                // would recompute every row height and yank scroll/VoiceOver focus to another
                // message (and could displace this one). The player matches the poster's size, so
                // the row height is unchanged. Recycled-away rows re-attach via viewFor.
                attachPlayerToPlayingRow()
                player.play()  // explicit, user-initiated — never an autoplay
                announce("Playing video")
            } catch {
                guard !Task.isCancelled, playingVideoMessageID == messageID else { return }
                setVideoDownloadingIndicator(false, messageID: messageID)
                playingVideoMessageID = nil
                announce("Couldn't play that video: \(error.localizedDescription)")
            }
        }
    }

    private func setVideoDownloadingIndicator(_ downloading: Bool, messageID: Int64) {
        guard let row = messages.firstIndex(where: { $0.id == messageID }),
              let cell = messageTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCellView
        else { return }
        cell.setVideoDownloading(downloading)
    }

    /// Attaches the controller-owned player to the visible cell for the playing message, in
    /// place, without reloading the table.
    private func attachPlayerToPlayingRow() {
        guard let playerView = videoPlayerView,
              let messageID = playingVideoMessageID,
              let row = messages.firstIndex(where: { $0.id == messageID }),
              let cell = messageTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCellView
        else { return }
        cell.attachInlineVideo(playerView)
        cell.layoutSubtreeIfNeeded()  // give the player its frame now so it renders immediately
    }

    private func stopVideoPlayback() {
        videoDownloadTask?.cancel()
        videoPlayer?.pause()
        videoPlayer = nil
        // Restore the poster in whatever visible cell currently hosts the player, so stopping or
        // switching videos never leaves a blank box where the message was.
        if let messageID = playingVideoMessageID,
           let row = messages.firstIndex(where: { $0.id == messageID }),
           let cell = messageTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCellView {
            cell.detachInlineVideoAndRestorePoster()
        }
        videoPlayerView?.player = nil
        videoPlayerView?.removeFromSuperview()
        videoPlayerView = nil
        playingVideoMessageID = nil
    }

    private func reloadSelectedConversation() {
        guard let currentConversationID else { return }
        loadMessages(for: currentConversationID)
    }

    /// Appends messages pushed by a live update so the open conversation stays current, and
    /// plays the receive cue (same-window vs push depending on whether the message is for the
    /// open chat). Outgoing messages are skipped: the send path already appends them locally
    /// and plays the send cue, and a pushed copy can't be deduplicated (no message id).
    func applyIncomingMessages(chatID: Int64, messages newMessages: [Message]) {
        let incoming = newMessages.filter { !$0.isOutgoing }
        guard !incoming.isEmpty else { return }

        if currentConversationID == chatID {
            SoundEffects.shared.play(.receiveMessageSameWindow)
            for message in incoming {
                appendMessageToTable(message)
            }
        } else {
            SoundEffects.shared.play(.receiveMessagePush)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === messageTableView {
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
        audioPlayer = nil
        removeDecodedVoiceMessage()
        playingVoiceFileID = fileID
        updatePlaybackStatus("Downloading voice message")

        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await telegramClient.downloadVoiceMessage(fileID: fileID)
                guard !Task.isCancelled, playingVoiceFileID == fileID else { return }
                let decodedURL = try await Task.detached {
                    try OggOpusDecoder.decodeToTemporaryPCMFile(url)
                }.value
                guard !Task.isCancelled, playingVoiceFileID == fileID else {
                    try? FileManager.default.removeItem(at: decodedURL)
                    return
                }
                removeDecodedVoiceMessage()
                decodedVoiceMessageURL = decodedURL
                let player = try AVAudioPlayer(contentsOf: decodedURL)
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
                removeDecodedVoiceMessage()
                playingVoiceFileID = nil
                updatePlaybackStatus("Voice playback failed")
                // Never surface the raw error (it can be a cryptic CoreAudio OSStatus, e.g. if the
                // output device was unplugged mid-playback) — give a clean, actionable message.
                announce("This voice message couldn’t be played. Check your audio output device, then try again.")
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
        playbackControls.isHidden = playingVoiceFileID == nil
        playbackSeparator.isHidden = playingVoiceFileID == nil
    }

    private func stopVoicePlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingVoiceFileID = nil
        removeDecodedVoiceMessage()
        updatePlaybackStatus("Voice playback: idle")
    }

    private func removeDecodedVoiceMessage() {
        guard let decodedVoiceMessageURL else { return }
        try? FileManager.default.removeItem(at: decodedVoiceMessageURL)
        self.decodedVoiceMessageURL = nil
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
        removeDecodedVoiceMessage()
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
        controller.onSend = { [weak self] fileURL, duration in
            self?.appendRecordedVoiceMessage(fileURL: fileURL, duration: duration)
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

    private func appendRecordedVoiceMessage(fileURL: URL, duration: TimeInterval) {
        guard let chatID = currentConversationID else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        Task { @MainActor [weak self] in
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard let self else { return }
            let message: Message
            do {
                let encodedURL = try await Task.detached {
                    try OggOpusEncoder.encode(fileURL)
                }.value
                message = try await telegramClient.sendVoiceMessage(fileURL: encodedURL, duration: duration, chatID: chatID)
            } catch {
                // Don't leak the raw encoder/TDLib error (it can be a cryptic OSStatus or network
                // code) — give a clean, actionable message.
                announce("Couldn’t send that voice message. Check your connection and try again.")
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
        SoundEffects.shared.play(.sendMessage)

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

    private func addHeaderButton(title: String, symbol: String, help: String, action: (() -> Void)? = nil) {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        if let action {
            button.tag = headerButtonActions.count
            headerButtonActions.append(action)
            button.target = self
            button.action = #selector(headerButtonTapped(_:))
        }
        actionStack.addArrangedSubview(button)
    }

    @objc private func headerButtonTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < headerButtonActions.count else { return }
        headerButtonActions[sender.tag]()
    }

    /// Initiates a 1:1 call to the open conversation's user. Errors (e.g. group chats, which
    /// don't support 1:1 calls) are announced. The resulting call UI is driven by AppDelegate's
    /// call controller via the update stream.
    private func startCall(isVideo: Bool) {
        guard let chatID = currentConversationID, !isStartingCall else { return }
        isStartingCall = true  // debounce: a second click can't fire a duplicate createCall
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStartingCall = false }
            do {
                try await telegramClient.startCall(chatID: chatID, isVideo: isVideo)
            } catch {
                announce("Couldn't start the call: \(error.localizedDescription)")
            }
        }
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
        let message = messages[row]
        let identifier = NSUserInterfaceItemIdentifier("MessageCell")
        // Recycle cells: with self-sizing rows viewFor is called often (measure + display), so a
        // fresh allocation each time is wasteful. configure() fully resets every region, and the
        // async image set is guarded by file id, so a recycled cell never shows stale content.
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? MessageTableCellView) ?? MessageTableCellView()
        cell.identifier = identifier
        cell.configure(
            message: message,
            imageLoader: imageLoader,
            onPlayVoiceMessage: { [weak self] in self?.playVoiceMessageIfPresent(at: row) },
            onPlayVideo: { [weak self] media in self?.playVideo(media, messageID: message.id) }
        )
        // If this row is the one currently playing video, hand it the controller-owned player.
        if message.id == playingVideoMessageID, let videoPlayerView {
            cell.attachInlineVideo(videoPlayerView)
        }
        return cell
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

/// Settings window. Currently hosts microphone-input selection for voice messages, built
/// in code with the same accessibility contract as the rest of the app: the popup is
/// labeled, the field order reads top-to-bottom under VoiceOver, and the chosen device is
/// announced at high priority.
final class SettingsViewController: NSViewController {
    private let microphonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sfxOutputPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let callOutputPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var devices: [AudioInputDevice] = []
    private var outputDevices: [AudioOutputDevice] = []

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "Settings")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setAccessibilityLabel("Settings")

        func sectionHeader(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.setAccessibilityRole(.staticText)
            return label
        }
        func helpText(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityLabel(text)
            return label
        }
        func captionLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityElement(false)
            return label
        }
        func configure(_ popup: NSPopUpButton, accessibility: String, help: String, action: Selector) {
            popup.target = self
            popup.action = action
            popup.setAccessibilityLabel(accessibility)
            popup.setAccessibilityHelp(help)
        }

        let micSection = sectionHeader("Microphone")
        let micHelp = helpText("Choose which microphone records voice messages and is used for calls. This applies only to CocoGram — it doesn’t change your Mac’s sound input.")
        let micCaption = captionLabel("Input device")
        configure(microphonePopup, accessibility: "Microphone input device",
                  help: "Choose which microphone records voice messages and is used for calls.",
                  action: #selector(microphoneChanged))

        let sfxSection = sectionHeader("Sound Effects")
        let sfxHelp = helpText("Choose where CocoGram plays its interface sound effects.")
        let sfxCaption = captionLabel("Output device")
        configure(sfxOutputPopup, accessibility: "Sound effects output device",
                  help: "Choose where CocoGram plays sound effects.",
                  action: #selector(sfxOutputChanged))

        let callSection = sectionHeader("Calls")
        let callHelp = helpText("Choose where you hear calls. Pairing a separate microphone and speaker lets AirPods stay in high-quality audio instead of dropping to phone-call quality during a call.")
        let callCaption = captionLabel("Output device")
        configure(callOutputPopup, accessibility: "Call output device",
                  help: "Choose where you hear calls.",
                  action: #selector(callOutputChanged))

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityRole(.staticText)

        let stack = NSStackView(views: [
            titleLabel,
            micSection, micHelp, micCaption, microphonePopup,
            sfxSection, sfxHelp, sfxCaption, sfxOutputPopup,
            callSection, callHelp, callCaption, callOutputPopup,
            statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 24, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: titleLabel)
        stack.setCustomSpacing(18, after: microphonePopup)
        stack.setCustomSpacing(18, after: sfxOutputPopup)
        stack.setCustomSpacing(16, after: callOutputPopup)
        view.addSubview(stack)

        let fullWidth: [NSView] = [titleLabel, micHelp, sfxHelp, callHelp, statusLabel,
                                   microphonePopup, sfxOutputPopup, callOutputPopup]
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        constraints += fullWidth.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
        NSLayoutConstraint.activate(constraints)

        view.setFrameSize(NSSize(width: 460, height: 580))
        reloadDevices()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(microphonePopup)
    }

    private func reloadDevices() {
        devices = VoiceMessageRecorder.availableInputDevices()
        outputDevices = CoreAudioDevices.availableOutputDevices()

        // Build menu items by hand (not addItem(withTitle:), which silently drops items
        // whose title duplicates an existing one — common with two similar interfaces).
        // Item 0 is "System Default"; items 1… map to the device list.
        populateInputPopup()
        populateOutputPopup(sfxOutputPopup, selectedUID: AudioOutputPreference.uid(for: .soundEffects))
        populateOutputPopup(callOutputPopup, selectedUID: AudioOutputPreference.uid(for: .calls))
        updateStatus()
    }

    private func populateInputPopup() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "System Default", action: nil, keyEquivalent: ""))
        for device in devices {
            menu.addItem(NSMenuItem(title: device.name, action: nil, keyEquivalent: ""))
        }
        microphonePopup.menu = menu
        // Reflect the user's saved choice (a per-app preference; the system input is never
        // changed). Falls back to System Default if the saved device isn't connected.
        if let uid = AudioInputPreference.preferredUID, let index = devices.firstIndex(where: { $0.uid == uid }) {
            microphonePopup.selectItem(at: index + 1)
        } else {
            microphonePopup.selectItem(at: 0)
        }
    }

    private func populateOutputPopup(_ popup: NSPopUpButton, selectedUID: String?) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "System Default", action: nil, keyEquivalent: ""))
        for device in outputDevices {
            menu.addItem(NSMenuItem(title: device.name, action: nil, keyEquivalent: ""))
        }
        popup.menu = menu
        if let selectedUID, let index = outputDevices.firstIndex(where: { $0.uid == selectedUID }) {
            popup.selectItem(at: index + 1)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func microphoneChanged() {
        let index = microphonePopup.indexOfSelectedItem
        // Item 0 = System Default (clear the preference); items 1… select a specific device
        // by stable UID. This only records the preference — it never opens the device and
        // never changes the macOS system input, so unselected devices are left untouched.
        if index <= 0 {
            AudioInputPreference.preferredUID = nil
        } else if index - 1 < devices.count {
            AudioInputPreference.preferredUID = devices[index - 1].uid
        }
        updateStatus(announce: true)
    }

    @objc private func sfxOutputChanged() {
        AudioOutputPreference.setUID(selectedOutputUID(sfxOutputPopup), for: .soundEffects)
        updateStatus(announce: true)
    }

    @objc private func callOutputChanged() {
        AudioOutputPreference.setUID(selectedOutputUID(callOutputPopup), for: .calls)
        updateStatus(announce: true)
    }

    /// nil for "System Default" (item 0), else the chosen output device's stable UID. Recording
    /// a preference only — never opens the device or changes the macOS system output.
    private func selectedOutputUID(_ popup: NSPopUpButton) -> String? {
        let index = popup.indexOfSelectedItem
        guard index > 0, index - 1 < outputDevices.count else { return nil }
        return outputDevices[index - 1].uid
    }

    private func updateStatus(announce: Bool = false) {
        let input = microphonePopup.titleOfSelectedItem ?? "System Default"
        let sfx = sfxOutputPopup.titleOfSelectedItem ?? "System Default"
        let call = callOutputPopup.titleOfSelectedItem ?? "System Default"
        let message = "Microphone: \(input). Sound effects play on: \(sfx). Calls play on: \(call)."
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel(message)
        if announce {
            NSAccessibility.post(
                element: statusLabel,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }
}

final class RecordingDialogController: NSViewController, AVAudioPlayerDelegate {
    enum RecordingState {
        case preparing
        case recording
        case recordingPaused
        case previewReady
        case previewPlaying
        case previewPaused
    }

    var onSend: ((URL, TimeInterval) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let playPauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var state: RecordingState = .preparing
    private var timer: Timer?
    private var recorder: VoiceMessageRecorder?
    private var previewPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var recordedDuration: TimeInterval = 0
    private var captureFailure: Error?
    private var didTransferRecording = false
    private var isClosing = false

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

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelRecording)
        cancelButton.setAccessibilityLabel("Cancel recording")
        cancelButton.setAccessibilityHelp("Discards this recorded voice message.")

        let controls = NSStackView(views: [playPauseButton, stopButton, sendButton, cancelButton])
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

        updateState(.preparing)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { @MainActor [weak self] in
            await self?.startRecordingWithPermission()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isClosing = true
        timer?.invalidate()
        finishRecording()
        previewPlayer?.stop()
        if !didTransferRecording, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
    }

    @objc private func togglePlayPause() {
        switch state {
        case .preparing:
            return
        case .recording:
            // Pause capture first, then play the cue so it isn't recorded.
            recorder?.pause()
            updateState(.recordingPaused)
            timer?.invalidate()
            SoundEffects.shared.play(.pauseRecording)
        case .recordingPaused:
            // Play the resume (Start) cue first, then resume capture in its completion so
            // the cue isn't recorded.
            SoundEffects.shared.play(.startRecording) { [weak self] in
                guard let self, !self.isClosing, self.state == .recordingPaused else { return }
                // The recorder can be gone if a capture failure was detected (and finishRecording
                // niled it) while paused. `recorder?.resume()` would then silently no-op via
                // optional chaining and we'd falsely show "Recording" with no recorder — so confirm
                // it's still alive and surface a failure otherwise.
                guard let recorder = self.recorder else {
                    self.presentRecordingFailure(VoiceMessageRecorder.RecorderError.configurationFailed("Recording stopped unexpectedly. Please try again."))
                    return
                }
                do {
                    try recorder.resume()
                    self.updateState(.recording)
                    self.startTimer()
                } catch {
                    self.presentRecordingFailure(error)
                }
            }
        case .previewReady:
            playPreview(restarting: true)
        case .previewPlaying:
            previewPlayer?.pause()
            updateState(.previewPaused)
            timer?.invalidate()
        case .previewPaused:
            playPreview(restarting: false)
        }
    }

    @objc private func stopRecording() {
        timer?.invalidate()
        finishRecording()
        // A write/device failure caught at Stop must be announced here — .previewReady is
        // silent and would enable Send on a corrupt take with no signal to VoiceOver.
        if let captureFailure {
            presentRecordingFailure(captureFailure)
            return
        }
        // Capture has stopped, so the Stop cue won't be recorded.
        SoundEffects.shared.play(.stopRecording)
        updateState(.previewReady)
    }

    @objc private func sendRecording() {
        timer?.invalidate()
        finishRecording()
        previewPlayer?.stop()
        if let captureFailure {
            presentRecordingFailure(captureFailure)
            return
        }
        guard let recordingURL, recordedDuration > 0 else {
            announce("Nothing has been recorded yet. Press Record to start.")
            return
        }
        didTransferRecording = true
        SoundEffects.shared.play(.sendMessage)
        onSend?(recordingURL, recordedDuration)
        closeSheet()
    }

    @objc private func cancelRecording() {
        closeSheet()
    }

    private func updateState(_ newState: RecordingState) {
        state = newState

        switch state {
        case .preparing:
            statusLabel.stringValue = "Preparing microphone"
            playPauseButton.setAccessibilityLabel("Pause recording")
            playPauseButton.isEnabled = false
            stopButton.isEnabled = false
            sendButton.isEnabled = false
        case .recording:
            statusLabel.stringValue = "Recording"
            playPauseButton.title = "Pause"
            playPauseButton.setAccessibilityLabel("Pause recording")
            playPauseButton.setAccessibilityHelp("Pauses the current voice message recording.")
            playPauseButton.isEnabled = true
            stopButton.isEnabled = true
            sendButton.isEnabled = true
        case .recordingPaused:
            statusLabel.stringValue = "Recording paused"
            playPauseButton.title = "Record"
            playPauseButton.setAccessibilityLabel("Resume recording")
            playPauseButton.setAccessibilityHelp("Resumes recording this voice message.")
            playPauseButton.isEnabled = true
            stopButton.isEnabled = true
            sendButton.isEnabled = true
        case .previewReady:
            statusLabel.stringValue = "Recording stopped"
            playPauseButton.title = "Play"
            playPauseButton.setAccessibilityLabel("Play recording")
            playPauseButton.setAccessibilityHelp("Plays the recorded voice message preview.")
            playPauseButton.isEnabled = true
            stopButton.isEnabled = false
            sendButton.isEnabled = true
        case .previewPlaying:
            statusLabel.stringValue = "Playing recording"
            playPauseButton.title = "Pause"
            playPauseButton.setAccessibilityLabel("Pause playback")
            playPauseButton.setAccessibilityHelp("Pauses playback of the recorded voice message preview.")
            playPauseButton.isEnabled = true
            stopButton.isEnabled = false
            sendButton.isEnabled = true
        case .previewPaused:
            statusLabel.stringValue = "Playback paused"
            playPauseButton.title = "Play"
            playPauseButton.setAccessibilityLabel("Resume playback")
            playPauseButton.setAccessibilityHelp("Resumes playback of the recorded voice message preview.")
            playPauseButton.isEnabled = true
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

    private func finishRecording() {
        if let recorder {
            recorder.stop()
            // Read after stop() so frames from the final in-flight tap buffers count.
            recordedDuration = max(recordedDuration, recorder.currentTime)
            if let error = recorder.captureError {
                captureFailure = error
            }
        }
        recorder = nil
    }

    @objc private func tickElapsed() {
        // Surface a mid-recording capture failure (device change, disk/write error) within
        // a second instead of waiting for Send. The recorder's tap can't speak to the user
        // itself, so the timer is the polling point.
        if state == .recording, let error = recorder?.captureError {
            timer?.invalidate()
            finishRecording()
            presentRecordingFailure(error)
            return
        }
        updateElapsedLabel()
    }

    private func updateElapsedLabel() {
        let elapsed: TimeInterval
        switch state {
        case .preparing:
            elapsed = 0
        case .recording, .recordingPaused:
            elapsed = recorder?.currentTime ?? recordedDuration
        case .previewReady:
            elapsed = recordedDuration
        case .previewPlaying, .previewPaused:
            elapsed = previewPlayer?.currentTime ?? 0
        }
        let elapsedSeconds = Int(elapsed)
        elapsedLabel.stringValue = String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
        elapsedLabel.setAccessibilityLabel("Elapsed time \(Message.format(TimeInterval(elapsedSeconds)))")
    }

    private func startRecordingWithPermission() async {
        let permissionGranted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionGranted = true
        case .notDetermined:
            permissionGranted = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            permissionGranted = false
        @unknown default:
            permissionGranted = false
        }

        guard !isClosing else { return }
        guard permissionGranted else {
            // Denied/restricted (or the user dismissed the prompt): the only fix is the Privacy
            // pane, so guide there directly rather than failing silently.
            showMicrophoneSettingsError("CocoGram needs microphone access to record voice messages. "
                + "Open System Settings ▸ Privacy & Security ▸ Microphone and turn on CocoGram. "
                + "If it’s already on, switch it off and back on, then try again.")
            return
        }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("CocoGram-\(UUID().uuidString).caf")
            // Records from the current system input device (chosen in Settings ▸ Microphone)
            // at its native rate/channels; the send path resamples to 48 kHz once, in
            // OggOpusEncoder, and only when the native rate isn't already 48 kHz.
            let recorder = try VoiceMessageRecorder(url: url)
            recordingURL = url
            self.recorder = recorder

            // Play the Start cue first, then begin capture in its completion so the cue itself
            // isn't recorded into the message. start() now confirms the mic actually opened, so a
            // blocked microphone is reported here as an actionable error — never a raw OSStatus.
            SoundEffects.shared.play(.startRecording) { [weak self] in
                guard let self, !self.isClosing, self.recorder === recorder else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isClosing, self.recorder === recorder else { return }
                    // start() now waits (briefly) for the first real audio buffer to confirm the mic
                    // is genuinely live, so show an explicit "opening" status instead of a silent
                    // gap. On success updateState(.recording) overwrites it immediately; on failure
                    // presentRecordingFailure shows the actionable recovery. Either way we leave
                    // .preparing — the dead "Preparing microphone" + dimmed Stop can't persist.
                    self.statusLabel.stringValue = "Opening microphone…"
                    self.statusLabel.setAccessibilityLabel("Opening microphone")
                    do {
                        try await recorder.start()
                        self.updateState(.recording)
                        self.startTimer()
                        self.announce("Recording started")
                    } catch {
                        self.presentRecordingFailure(error)
                    }
                }
            }
        } catch {
            presentRecordingFailure(error)
        }
    }

    /// Single funnel for any recording failure: shows an actionable message (and, for a mic-access
    /// block, the Microphone Settings recovery) and NEVER leaks a raw OSStatus to the user.
    private func presentRecordingFailure(_ error: Error) {
        recorder?.stop()
        recorder = nil
        if VoiceMessageRecorder.isMicrophoneAccessFailure(error) {
            showMicrophoneSettingsError(VoiceMessageRecorder.RecorderError.microphoneAccessBlocked.errorDescription ?? "The microphone is unavailable.")
        } else if let recorderError = error as? VoiceMessageRecorder.RecorderError {
            showRecordingError(recorderError.errorDescription ?? "Recording failed. Please try again.")
        } else {
            // Unknown/unexpected error — give a clean message, not the underlying code.
            showRecordingError("Recording failed. Please try again.")
        }
    }

    /// Shows a microphone-access failure with a one-tap path to the Privacy ▸ Microphone settings.
    private func showMicrophoneSettingsError(_ message: String) {
        timer?.invalidate()
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel(message)
        playPauseButton.isEnabled = false
        stopButton.isEnabled = false
        sendButton.isEnabled = false
        announce(message)
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Microphone Unavailable"
        alert.informativeText = message
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func playPreview(restarting: Bool) {
        guard let recordingURL else { return }
        do {
            let player = try previewPlayer ?? AVAudioPlayer(contentsOf: recordingURL)
            player.delegate = self
            if restarting {
                player.currentTime = 0
            }
            guard player.prepareToPlay(), player.play() else {
                throw CocoaError(.fileReadUnknown)
            }
            previewPlayer = player
            updateState(.previewPlaying)
            startTimer()
        } catch {
            // A preview-playback failure is an OUTPUT-device problem (e.g. headphones unplugged),
            // not a mic block — so don't route to the Microphone recovery and never leak the raw
            // OSStatus. The recording is intact and can still be sent.
            showRecordingError("Couldn’t play the preview — check your audio output device. You can still send this recording.")
        }
    }

    private func showRecordingError(_ message: String) {
        timer?.invalidate()
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel(message)
        playPauseButton.isEnabled = false
        stopButton.isEnabled = false
        sendButton.isEnabled = false
        announce(message)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: statusLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard previewPlayer === player else { return }
            timer?.invalidate()
            previewPlayer?.currentTime = 0
            updateState(.previewReady)
        }
    }

    private func closeSheet() {
        guard let window = view.window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window.close()
    }
}

/// Sizing for inline media: scale the intrinsic pixel dimensions down to fit a sensible box
/// (never upscaling), so a cell reserves the right height before the bytes arrive.
enum MediaLayout {
    static let maxWidth: CGFloat = 300
    static let maxHeight: CGFloat = 300

    static func displaySize(width: Int, height: Int) -> NSSize {
        let w = CGFloat(max(width, 1))
        let h = CGFloat(max(height, 1))
        let scale = min(maxWidth / w, maxHeight / h, 1.0)
        return NSSize(width: max((w * scale).rounded(), 80), height: max((h * scale).rounded(), 60))
    }
}

/// Loads and caches media images by TDLib file id. Downloads go through TDLib (which caches
/// the bytes on disk); decoded `NSImage`s are held in memory so scrolling never re-downloads
/// or re-decodes. In-flight loads are coalesced so duplicate cells share one download.
@MainActor
final class MediaImageLoader {
    private let download: @MainActor (Int) async throws -> URL
    private let cache = NSCache<NSNumber, NSImage>()
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]

    init(download: @escaping @MainActor (Int) async throws -> URL) {
        self.download = download
    }

    func cachedImage(fileID: Int) -> NSImage? {
        cache.object(forKey: NSNumber(value: fileID))
    }

    func image(fileID: Int) async -> NSImage? {
        let key = NSNumber(value: fileID)
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[fileID] { return await existing.value }

        let task = Task { @MainActor [download] () -> NSImage? in
            guard let url = try? await download(fileID) else { return nil }
            return NSImage(contentsOf: url)
        }
        inFlight[fileID] = task
        let image = await task.value
        inFlight[fileID] = nil
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

final class MessageTableCellView: NSTableCellView {
    private let senderLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let voiceContainer = NSStackView()
    private let voicePlayButton = NSButton()
    private let voiceTranscriptLabel = NSTextField(wrappingLabelWithString: "")
    private let mediaContainer = NSStackView()
    private let mediaIcon = NSImageView()
    private let mediaLabel = NSTextField(labelWithString: "")
    // Inline image / video poster.
    private let imageContainer = NSView()
    private let mediaImageView = NSImageView()
    private let videoPlayOverlay = NSButton()
    private let mediaLoadingSpinner = NSProgressIndicator()
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?

    private var accessibilitySummary = ""
    private var isVoiceMessage = false
    /// File id whose image this cell currently wants, so a late async load for a superseded
    /// configuration is ignored.
    private var pendingImageFileID: Int?
    private var videoToPlay: VideoMedia?
    private var onPlayVideo: ((VideoMedia) -> Void)?
    private var onPlayVoiceMessage: (() -> Void)?
    private weak var imageLoader: MediaImageLoader?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        message: Message,
        imageLoader: MediaImageLoader,
        onPlayVoiceMessage: @escaping () -> Void,
        onPlayVideo: @escaping (VideoMedia) -> Void
    ) {
        accessibilitySummary = message.accessibilitySummary
        setAccessibilityLabel(accessibilitySummary)
        self.imageLoader = imageLoader
        self.onPlayVoiceMessage = onPlayVoiceMessage
        self.onPlayVideo = onPlayVideo
        self.videoToPlay = nil

        senderLabel.stringValue = message.isOutgoing ? "You" : message.sender
        timeLabel.stringValue = message.time
        statusLabel.stringValue = message.outgoingStatus?.rawValue ?? ""
        statusLabel.isHidden = !message.isOutgoing || message.outgoingStatus == nil

        // Reset all optional regions; each case re-enables only what it needs.
        bodyLabel.isHidden = true
        voiceContainer.isHidden = true
        mediaContainer.isHidden = true
        imageContainer.isHidden = true
        videoPlayOverlay.isHidden = true
        captionLabel.isHidden = true
        captionLabel.stringValue = ""   // clear so a recycled cell never keeps a prior caption
        isVoiceMessage = false
        pendingImageFileID = nil
        setImageLoading(false)
        detachInlineVideo()

        switch message.kind {
        case .text(let body):
            setAccessibilityHelp("Message")
            bodyLabel.stringValue = body
            bodyLabel.isHidden = false
        case .voice(let duration, let transcript, _):
            isVoiceMessage = true
            setAccessibilityHelp("Voice message. Press VoiceOver Space to play, pause, or resume.")
            voiceContainer.isHidden = false
            voiceTranscriptLabel.stringValue = "Voice message, \(Message.format(duration)). \(transcript)"
        case .image(let image):
            setAccessibilityHelp("Image")
            showImage(fileID: image.fileID, width: image.width, height: image.height, caption: image.caption)
        case .video(let video):
            setAccessibilityHelp("Video. Activate to play it inline.")
            videoToPlay = video
            showImage(fileID: video.posterFileID, width: video.width, height: video.height, caption: video.caption)
            videoPlayOverlay.isHidden = false
        case .media(let icon, let label):
            setAccessibilityHelp("Message")
            mediaContainer.isHidden = false
            mediaIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            mediaLabel.stringValue = label
        }
    }

    /// Sizes and reveals the image region, then loads the bytes asynchronously. `fileID` is
    /// optional so a video with no poster still lays out at the right size.
    private func showImage(fileID: Int?, width: Int, height: Int, caption: String) {
        imageContainer.isHidden = false
        let size = MediaLayout.displaySize(width: width, height: height)
        imageWidthConstraint?.constant = size.width
        imageHeightConstraint?.constant = size.height
        mediaImageView.image = nil

        if !caption.isEmpty {
            captionLabel.isHidden = false
            captionLabel.stringValue = caption
        }

        guard let fileID else { return }
        if let cached = imageLoader?.cachedImage(fileID: fileID) {
            setLoadedImage(cached)
            return
        }
        // Show a spinner over a neutral fill while the bytes download, so a loading cell is
        // never mistaken for a fully-rendered (very light or very dark) image.
        setImageLoading(true)
        pendingImageFileID = fileID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await self.imageLoader?.image(fileID: fileID)
            guard self.pendingImageFileID == fileID else { return }  // superseded by a later configure
            if let image {
                self.setLoadedImage(image)
            } else {
                self.setImageLoading(false)  // download failed; drop the spinner
            }
        }
    }

    /// Toggles the loading state: a spinner over a neutral placeholder fill while bytes load.
    private func setImageLoading(_ loading: Bool) {
        mediaImageView.layer?.backgroundColor = (loading ? NSColor.quaternaryLabelColor : NSColor.clear).cgColor
        mediaLoadingSpinner.isHidden = !loading
        if loading {
            mediaLoadingSpinner.startAnimation(nil)
        } else {
            mediaLoadingSpinner.stopAnimation(nil)
        }
    }

    /// Installs a decoded image and clears the placeholder — a transparent sticker then renders
    /// over the cell background rather than a grey box, and a finished load reads as finished.
    private func setLoadedImage(_ image: NSImage) {
        mediaImageView.image = image
        setImageLoading(false)
    }

    /// Embeds the conversation's shared inline video player over the poster (the player is owned
    /// by the view controller and moved between cells as rows recycle).
    func attachInlineVideo(_ playerView: NSView) {
        playerView.translatesAutoresizingMaskIntoConstraints = false
        if playerView.superview !== imageContainer {
            playerView.removeFromSuperview()
            imageContainer.addSubview(playerView)
            NSLayoutConstraint.activate([
                playerView.leadingAnchor.constraint(equalTo: mediaImageView.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: mediaImageView.trailingAnchor),
                playerView.topAnchor.constraint(equalTo: mediaImageView.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: mediaImageView.bottomAnchor)
            ])
        }
        mediaImageView.isHidden = true
        videoPlayOverlay.isHidden = true
        setVideoDownloading(false)
    }

    private func detachInlineVideo() {
        for subview in imageContainer.subviews where subview is AVPlayerView {
            subview.removeFromSuperview()
        }
        mediaImageView.isHidden = false
    }

    /// Removes the inline player and brings the poster (and, for a video, the play overlay) back,
    /// so a stopped/switched video never leaves an empty cell.
    func detachInlineVideoAndRestorePoster() {
        detachInlineVideo()
        setVideoDownloading(false)
        videoPlayOverlay.isHidden = (videoToPlay == nil)
    }

    /// Shows a spinner over the (already-loaded) poster while the full video downloads, so a slow
    /// download reads as "loading", not "broken". The play overlay is hidden while downloading.
    func setVideoDownloading(_ downloading: Bool) {
        mediaLoadingSpinner.isHidden = !downloading
        if downloading {
            mediaLoadingSpinner.startAnimation(nil)
            videoPlayOverlay.isHidden = true
        } else {
            mediaLoadingSpinner.stopAnimation(nil)
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

        voicePlayButton.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play voice message")
        voicePlayButton.bezelStyle = .texturedRounded
        voicePlayButton.target = self
        voicePlayButton.action = #selector(playVoiceMessage)
        voicePlayButton.setAccessibilityLabel("Play voice message")
        voicePlayButton.setAccessibilityHelp("Downloads and plays this voice message. Activate again to pause or resume playback.")

        voiceTranscriptLabel.font = .systemFont(ofSize: 13)
        voiceTranscriptLabel.textColor = .secondaryLabelColor
        voiceTranscriptLabel.maximumNumberOfLines = 2
        voiceTranscriptLabel.setAccessibilityElement(false)

        voiceContainer.orientation = .horizontal
        voiceContainer.alignment = .centerY
        voiceContainer.spacing = 8
        voiceContainer.addArrangedSubview(voicePlayButton)
        voiceContainer.addArrangedSubview(voiceTranscriptLabel)
        voiceContainer.setAccessibilityElement(false)

        // Inline image / video poster, with a play overlay centered on top for video. The
        // background is clear by default (set to a neutral fill only while loading) so a loaded
        // image — including a transparent sticker — renders cleanly without a grey box behind it.
        mediaImageView.imageScaling = .scaleProportionallyUpOrDown
        mediaImageView.wantsLayer = true
        mediaImageView.layer?.cornerRadius = 10
        mediaImageView.layer?.masksToBounds = true
        mediaImageView.layer?.backgroundColor = NSColor.clear.cgColor
        mediaImageView.translatesAutoresizingMaskIntoConstraints = false
        mediaImageView.setAccessibilityElement(false)

        mediaLoadingSpinner.style = .spinning
        mediaLoadingSpinner.controlSize = .small
        mediaLoadingSpinner.isDisplayedWhenStopped = false
        mediaLoadingSpinner.isHidden = true
        mediaLoadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        mediaLoadingSpinner.setAccessibilityElement(false)

        videoPlayOverlay.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play video")
        videoPlayOverlay.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        videoPlayOverlay.isBordered = false
        videoPlayOverlay.bezelStyle = .regularSquare
        videoPlayOverlay.contentTintColor = .white
        videoPlayOverlay.target = self
        videoPlayOverlay.action = #selector(playVideo)
        videoPlayOverlay.translatesAutoresizingMaskIntoConstraints = false
        videoPlayOverlay.setAccessibilityElement(false)

        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.addSubview(mediaImageView)
        imageContainer.addSubview(mediaLoadingSpinner)
        imageContainer.addSubview(videoPlayOverlay)
        imageContainer.setAccessibilityElement(false)

        let imageWidth = mediaImageView.widthAnchor.constraint(equalToConstant: 200)
        let imageHeight = mediaImageView.heightAnchor.constraint(equalToConstant: 200)
        imageWidthConstraint = imageWidth
        imageHeightConstraint = imageHeight
        NSLayoutConstraint.activate([
            mediaImageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            mediaImageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            mediaImageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            mediaImageView.trailingAnchor.constraint(lessThanOrEqualTo: imageContainer.trailingAnchor),
            imageWidth,
            imageHeight,
            mediaLoadingSpinner.centerXAnchor.constraint(equalTo: mediaImageView.centerXAnchor),
            mediaLoadingSpinner.centerYAnchor.constraint(equalTo: mediaImageView.centerYAnchor),
            videoPlayOverlay.centerXAnchor.constraint(equalTo: mediaImageView.centerXAnchor),
            videoPlayOverlay.centerYAnchor.constraint(equalTo: mediaImageView.centerYAnchor)
        ])

        captionLabel.font = .systemFont(ofSize: 13)
        captionLabel.maximumNumberOfLines = 0
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.preferredMaxLayoutWidth = 300
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        captionLabel.setAccessibilityElement(false)

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

        let stack = NSStackView(views: [senderLabel, bodyLabel, voiceContainer, imageContainer, captionLabel, mediaContainer, metadataStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14)
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

    override func accessibilityPerformPress() -> Bool {
        if isVoiceMessage {
            onPlayVoiceMessage?()
            return true
        }
        if let videoToPlay {
            onPlayVideo?(videoToPlay)
            return true
        }
        return false
    }

    @objc private func playVoiceMessage() {
        onPlayVoiceMessage?()
    }

    @objc private func playVideo() {
        guard let videoToPlay else { return }
        onPlayVideo?(videoToPlay)
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

// Headless device-enumeration diagnostics (no GUI, no app.run(), opens no audio device).
SelfTest.runIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
