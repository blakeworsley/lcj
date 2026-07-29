/// AppDelegate.swift — status item, menu wiring, and refresh cadence.
///
/// Plain AppKit; no SwiftUI. The status item hosts a custom StatusBarView subview
/// so we get pixel-precise Stats-style layout. The NSMenu is rebuilt on every open
/// (menuNeedsUpdate delegate) so the dropdown always shows fresh data.

import AppKit
import ClusageCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Ivars

    private var statusItem: NSStatusItem!
    private var statusView: StatusBarView!
    private let fetcher = UsageFetcher()
    private var latestState: FetchState?
    private var refreshTimer: Timer?

    // MARK: - applicationDidFinishLaunching

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        setupFetcher()
        setupRefreshTimer()
        setupWakeObserver()

        // Initial fetch — menu bar shows "–" until the first response arrives.
        fetcher.fetchNow()
        // First run: no cookie stored → open the paste dialog once, after launch settles.
        // WHY DispatchQueue.main.async: gives AppKit time to finish setting up the status
        // item before we show an alert; calling runModal() during launch can hang the app.
        if CookieStore.load() == nil {
            DispatchQueue.main.async { self.promptForCookie() }
        }
    }

    // MARK: - Main menu

    private func setupMainMenu() {
        // WHY: LSUIElement apps have no main menu by default. Without one, key
        // equivalents like ⌘V have no NSMenuItem to route through, so paste is
        // silently swallowed even when an NSTextField has keyboard focus.
        // A minimal Edit menu with the standard text actions fixes this.
        let mainMenu = NSMenu()

        // macOS requires a first item whose submenu is the application menu.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        // Custom view: draw inside the button's bounds. hitTest returns nil so
        // clicks fall through to the button → opens the menu.
        statusView = StatusBarView(frame: button.bounds)
        statusView.autoresizingMask = [.width, .height]
        button.addSubview(statusView)

        // Menu opens on click (standard NSStatusItem behaviour).
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Fetcher wiring

    private func setupFetcher() {
        fetcher.onUpdate = { [weak self] state in
            // Called on main thread by UsageFetcher.fetchNow().
            guard let self else { return }
            self.latestState = state
            self.applyState(state)
        }
    }

    private func applyState(_ state: FetchState) {
        switch state {
        case .ok(let snap, _):
            statusView.snapshot = snap
            statusView.resetDate = snap.session?.resetsAt
            statusView.isDegraded = false
        case .degraded:
            statusView.snapshot = nil
            statusView.isDegraded = true
        }
        statusView.needsDisplay = true
        statusItem.length = statusView.preferredWidth()
    }

    // MARK: - Refresh cadence

    private func setupRefreshTimer() {
        // Cadence comes from RefreshIntervalStore (user-selectable via the
        // "Refresh Every" submenu); it defaults to the historical 5-min value.
        // WHY invalidate() first: this is also called from setRefreshInterval(_:)
        // when the user picks a new interval, so it must be safe to re-enter.
        refreshTimer?.invalidate()
        let seconds = TimeInterval(RefreshIntervalStore.load() * 60)
        // WHY Task { @MainActor in }: Timer callbacks are nonisolated from Swift 6's static
        // perspective even though scheduledTimer runs on the main run loop. The Task hop is
        // a no-op at runtime (already on main) but satisfies the type system without using
        // DispatchQueue.main.async (which is unstructured and harder to reason about).
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fetcher.fetchNow() }
        }
        // Proportional slack lets the OS batch with other timers (saves battery);
        // 10% preserves the previous 30s-at-5-min ratio at every interval.
        timer.tolerance = seconds * 0.1
        refreshTimer = timer
    }

    private func setupWakeObserver() {
        // Re-fetch immediately after wake: usage data is likely stale post-sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func onWake() {
        fetcher.fetchNow()
    }

    // MARK: - NSMenuDelegate

    /// Rebuild the menu every time the user opens it so everything is fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        switch latestState {
        case .ok(let snap, let updatedAt):
            addUsageRows(to: menu, snap: snap)
            addUpdatedRow(to: menu, updatedAt: updatedAt)
        case .degraded(let reason, let updatedAt):
            addDegradedRow(to: menu, reason: reason)
            addUpdatedRow(to: menu, updatedAt: updatedAt)
        case nil:
            let waiting = NSMenuItem(title: "Waiting for first fetch…", action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(waiting)
        }

        menu.addItem(.separator())
        addRefreshItem(to: menu)
        addRefreshIntervalItem(to: menu)
        addSetCookieItem(to: menu)
        addLaunchAtLoginItem(to: menu)
        menu.addItem(.separator())
        addQuitItem(to: menu)
    }

    // MARK: - Menu helpers

    private func addUsageRows(to menu: NSMenu, snap: UsageSnapshot) {
        func row(_ bucket: Bucket?, kind: String) -> NSMenuItem {
            let label: String
            let resetsStr: String
            if let b = bucket {
                let kindLabel: String
                switch kind {
                case "session": kindLabel = "Session (5h)"
                case "weekly_scoped": kindLabel = b.label.capitalized + " (week)"
                default: kindLabel = "Weekly (all models)"
                }
                resetsStr = menuDetailTime(b.resetsAt)
                label = "\(kindLabel): \(b.percent)% — resets \(resetsStr)"
            } else {
                label = kind == "session" ? "Session (5h): –" :
                        kind == "weekly_scoped" ? "Fable (week): –" :
                        "Weekly (all models): –"
            }
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        menu.addItem(row(snap.session,      kind: "session"))
        menu.addItem(row(snap.weeklyScoped, kind: "weekly_scoped"))
        menu.addItem(row(snap.weeklyAll,    kind: "weekly_all"))
    }

    private func addDegradedRow(to menu: NSMenu, reason: String) {
        let msg: String
        switch reason {
        case "no_cookie":
            msg = "No session cookie — choose 'Set Session Cookie…' below"
        case "no_org_id":
            msg = "Org ID not found — re-copy the FULL cookie from claude.ai"
        case "http_401":
            msg = "Cookie rejected or expired — paste a fresh one from claude.ai"
        case "network":
            msg = "Network error"
        case "http_5xx":
            msg = "Anthropic API error"
        default:  // "bad_shape"
            msg = "Unexpected API response"
        }
        let item = NSMenuItem(title: "⚠︎ Usage unavailable: \(msg)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addUpdatedRow(to menu: NSMenu, updatedAt: Date) {
        let elapsed = Date().timeIntervalSince(updatedAt)
        let label: String
        if elapsed < 60 {
            label = "Updated just now"
        } else {
            let mins = Int(elapsed / 60)
            label = "Updated \(mins)m ago"
        }
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addRefreshItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        item.keyEquivalentModifierMask = .command
        item.target = self
        menu.addItem(item)
    }

    @objc private func refreshNow() {
        fetcher.fetchNow()
    }

    private func addRefreshIntervalItem(to menu: NSMenu) {
        // Menu is rebuilt on every open (menuNeedsUpdate), so the checkmark
        // re-reads the stored value here and needs no separate state sync.
        let parent = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = RefreshIntervalStore.load()
        for minutes in RefreshInterval.allowedMinutes {
            let title = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            let item = NSMenuItem(title: title, action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.tag = minutes   // carries the chosen value to the action
            item.state = minutes == current ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        RefreshIntervalStore.save(sender.tag)
        setupRefreshTimer()   // restart the cadence immediately at the new interval
    }

    private func addSetCookieItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Set Session Cookie…", action: #selector(promptForCookie as () -> Void), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc func promptForCookie() { promptForCookie(prefill: "") }

    private func promptForCookie(prefill: String) {
        // LSUIElement app: the app has no Dock icon, so NSAlert won't front without this.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set Claude session cookie"
        alert.informativeText = """
            1. Open claude.ai/settings/usage in your browser
            2. Open DevTools (⌘⌥I) → Network tab
            3. Refresh the page, click the "usage" request
            4. In Request Headers, copy the full "Cookie" value
            5. Paste it below
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "anthropic-device-id=…; lastActiveOrg=…; sessionKey=…"
        field.stringValue = prefill
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")                           // .alertFirstButtonReturn
        alert.addButton(withTitle: "Open claude.ai/settings/usage") // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")                        // .alertThirdButtonReturn
        // WHY layout() + makeFirstResponder: initialFirstResponder alone is not enough
        // for NSAlert accessoryViews in LSUIElement apps — AppKit won't focus the field
        // until the window is laid out, so ⌘V paste is swallowed. layout() finalises
        // the view hierarchy; makeFirstResponder() then gives the field keyboard focus.
        alert.layout()
        alert.window.makeFirstResponder(field)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let cookie = sanitizeCookie(field.stringValue)
            guard !cookie.isEmpty else { return }  // empty Save == Cancel; never clears
            CookieStore.save(cookie)
            fetcher.fetchNow()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            promptForCookie(prefill: field.stringValue)  // reopen; keep typed text
        default:
            break
        }
    }

    private func addLaunchAtLoginItem(to menu: NSMenu) {
        // WHY: SMAppService.mainApp only works when the app is installed as a proper
        // .app bundle (not via `swift run`). We wrap in try/catch and show an error
        // item if the service call fails, which it will during development.
        let service = SMAppService.mainApp
        let isEnabled: Bool
        do {
            isEnabled = service.status == .enabled
        }

        let item = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        item.state = isEnabled ? .on : .off
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // Show one-line error item on next menu open; state hasn't changed.
            let errItem = NSMenuItem(title: "Login item error: \(error.localizedDescription)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            statusItem.menu?.insertItem(errItem, at: 0)
        }
    }

    private func addQuitItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Quit Clusage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)
    }
}
