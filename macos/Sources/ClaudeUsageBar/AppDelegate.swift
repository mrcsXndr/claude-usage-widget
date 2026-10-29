import AppKit
import Combine
import SwiftUI
import UsageCore

/// Owns the menu bar item, the dropdown and the timers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    // Created in applicationDidFinishLaunching, on the main actor.
    private var store: UsageStore!
    private var loginItem: LoginItem!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var tickTimer: Timer?
    /// When the popover last closed: the mouse-down on the icon closes a transient popover
    /// before our mouse-up action runs, which would otherwise reopen it.
    private var lastPopoverClose = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore()
        loginItem = LoginItem()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Claude usage")
        }

        let actions = PopoverActions(
            refresh: { [weak self] in self?.store.refresh(manual: true) },
            scan: { [weak self] in self?.store.scan() },
            openConfig: { [weak self] in self?.openConfig() },
            openLog: { [weak self] in self?.openLog() },
            quit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: PopoverView(store: store, loginItem: loginItem, actions: actions))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true

        // Redraw the rings whenever the data or config changes (after the change lands).
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &cancellables)

        // A light/dark switch changes the menu bar; redraw so text colours follow.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(appearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        // Catch up after sleep (give the network a few seconds to come back).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        // Check once a minute whether a refresh is due; this also keeps tooltips' countdowns fresh.
        // Selector-based so the callback stays on the main thread (a closure here trips Swift's concurrency checks).
        tickTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(tick),
                                         userInfo: nil, repeats: true)
        tickTimer?.tolerance = 10

        redraw()
        loginItem.enableOnFirstRun()
        store.start()
    }

    // MARK: Drawing

    private func redraw() {
        guard let button = statusItem?.button else { return }
        let shown = store.menuBarAccounts
        let groups = RingRenderer.groups(accounts: shown, usage: store.usage)
        button.image = RingRenderer.image(for: groups, showPercent: store.config.showPercentInside)
        updateTooltip()
    }

    private func updateTooltip() {
        statusItem?.button?.toolTip = RingRenderer.tooltip(accounts: store.menuBarAccounts, usage: store.usage)
    }

    @objc private func tick() {
        store.refreshIfDue()
        updateTooltip()
    }

    @objc private func appearanceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.redraw() }
    }

    @objc private func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.store.refreshIfDue() }
    }

    // MARK: Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        if Date().timeIntervalSince(lastPopoverClose) < 0.3 { return }
        store.notice = nil
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let refresh = NSMenuItem(title: "Refresh now", action: #selector(menuRefresh), keyEquivalent: "")
        refresh.isEnabled = store.canRefreshManually() && !store.refreshing
        menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: "Scan for accounts", action: #selector(menuScan), keyEquivalent: ""))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at login", action: #selector(menuToggleLogin), keyEquivalent: "")
        login.state = loginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Open config file\u{2026}", action: #selector(menuOpenConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open log", action: #selector(menuOpenLog), keyEquivalent: ""))
        menu.addItem(.separator())
        let about = NSMenuItem(title: "Claude Usage \(UsageClient.version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        // Menus need autoenablesItems off for the manual isEnabled above to stick.
        menu.autoenablesItems = false

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left click opens the dropdown again.
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { store.refresh(manual: true) }
    @objc private func menuScan() { store.scan() }
    @objc private func menuToggleLogin() { loginItem.setEnabled(!loginItem.isEnabled) }
    @objc private func menuOpenConfig() { openConfig() }
    @objc private func menuOpenLog() { openLog() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Files

    private func openConfig() {
        let url = store.configStore.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? store.configStore.save(store.config)
        }
        openInTextEditor(url)
    }

    private func openLog() {
        let url = store.configStore.logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        openInTextEditor(url)
    }

    /// `open -t` opens the file in the default text editor (a .json would otherwise go to Xcode or a browser).
    private func openInTextEditor(_ url: URL) {
        popover.performClose(nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", url.path]
        try? p.run()
    }
}
