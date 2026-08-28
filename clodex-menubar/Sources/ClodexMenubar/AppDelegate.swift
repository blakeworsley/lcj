/// AppDelegate.swift — status item, menu wiring, and refresh cadence.
/// Structure ported from mlg87/lcj clusage-menubar; adds a Codex local-scan lane
/// that refreshes on the same cadence as the Claude fetch.
///
/// Plain AppKit; no SwiftUI. The status item hosts a custom StatusBarView subview
/// for pixel-precise Stats-style layout. The NSMenu is rebuilt on every open
/// (menuNeedsUpdate delegate) so the dropdown always shows fresh data.

import AppKit
import ClodexCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Ivars

    private var statusItem: NSStatusItem!
    private var statusView: StatusBarView!
    private let fetcher = UsageFetcher()
    private let planFetcher = CodexPlanFetcher()
    private var latestPlanState: CodexPlanState?
    private var latestClaudeState: FetchState?
    private var latestCodexState: CodexScanState?
    private var latestClaudeLocalState: ClaudeLocalState?
    private var refreshTimer: Timer?
    /// Minute tick that repaints countdowns; no data fetch, display only.
    private var countdownTimer: Timer?

    // MARK: - applicationDidFinishLaunching

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        setupFetcher()
        setupRefreshTimer()
        setupWakeObserver()

        // Initial refresh — menu bar shows "–" until the first data arrives.
        refreshAll()
        // First run with no auth at all — no Claude Code sign-in and no cookie
        // anywhere (own store or clusage fallback): open the paste dialog once,
        // after launch settles. Users with Claude Code installed never see it.
        // WHY DispatchQueue.main.async: gives AppKit time to finish setting up the status
        // item before we show an alert; calling runModal() during launch can hang the app.
        if !ClaudeCodeAuth.hasToken() && CookieStore.load() == nil {
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
        statusView.style = MenuBarStyleStore.load()
        statusView.resetShowsCountdown = ResetDisplayStore.showsCountdown()
        setupCountdownTimer()
        statusView.autoresizingMask = [.width, .height]
        button.addSubview(statusView)

        // Menu opens on click (standard NSStatusItem behaviour).
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Refresh lanes

    private func setupFetcher() {
        fetcher.onUpdate = { [weak self] state in
            // Called on main thread by UsageFetcher.fetchNow().
            guard let self else { return }
            self.latestClaudeState = state
            self.applyClaudeState(state)
        }
        planFetcher.onUpdate = { [weak self] state in
            guard let self else { return }
            self.latestPlanState = state
            if case .ok(let usage, _) = state {
                self.statusView.codexPlan = usage
            } else {
                self.statusView.codexPlan = nil
            }
            self.redraw()
        }
    }

    /// Kick all three lanes: the claude.ai limit fetch, the Codex log scan, and
    /// the Claude Code local-log scan (cost history for the trend styles).
    private func refreshAll() {
        fetcher.fetchNow()
        planFetcher.fetchNow()
        scanCodexNow()
        scanClaudeLocalNow()
    }

    /// Run the blocking filesystem scans off the main thread, then apply on main.
    private func scanCodexNow() {
        Task.detached(priority: .utility) {
            let state = CodexScanner.shared.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.latestCodexState = state
                self.applyCodexState(state)
            }
        }
    }

    private func scanClaudeLocalNow() {
        Task.detached(priority: .utility) {
            let state = ClaudeScanner.shared.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.latestClaudeLocalState = state
                if case .ok(let history, _) = state {
                    self.statusView.claudeHistory = history
                } else {
                    self.statusView.claudeHistory = nil
                }
                self.redraw()
            }
        }
    }

    private func applyClaudeState(_ state: FetchState) {
        switch state {
        case .ok(let snap, _, _):
            statusView.snapshot = snap
            statusView.resetDate = snap.session?.resetsAt
            statusView.isDegraded = false
        case .degraded:
            statusView.snapshot = nil
            statusView.isDegraded = true
        }
        redraw()
    }

    private func applyCodexState(_ state: CodexScanState) {
        switch state {
        case .ok(let summary, let history, _):
            statusView.codexSummary = summary
            statusView.codexHistory = history
            statusView.codexDegraded = false
        case .degraded:
            statusView.codexSummary = nil
            statusView.codexHistory = nil
            statusView.codexDegraded = true
        }
        statusView.codexShowsDollars = CodexDisplayStore.showsDollars()
        statusView.codexBudget = CodexBudgetStore.load()
        redraw()
    }

    private func redraw() {
        statusView.needsDisplay = true
        statusItem.length = statusView.preferredWidth()
    }

    // MARK: - Refresh cadence

    private func setupRefreshTimer() {
        // Cadence comes from RefreshIntervalStore (user-selectable via the
        // "Refresh Every" submenu). WHY invalidate() first: also called from
        // setRefreshInterval(_:) when the user picks a new interval, so it must
        // be safe to re-enter.
        refreshTimer?.invalidate()
        let seconds = TimeInterval(RefreshIntervalStore.load() * 60)
        // WHY Task { @MainActor in }: Timer callbacks are nonisolated from Swift 6's
        // static perspective even though scheduledTimer runs on the main run loop.
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        }
        // Proportional slack lets the OS batch with other timers (saves battery).
        timer.tolerance = seconds * 0.1
        refreshTimer = timer
    }

    /// Repaint every minute so countdown text stays current between data
    /// refreshes. Runs only while countdown mode is on; pure redraw, no I/O.
    private func setupCountdownTimer() {
        countdownTimer?.invalidate()
        guard ResetDisplayStore.showsCountdown() else {
            countdownTimer = nil
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.redraw() }
        }
        timer.tolerance = 5
        countdownTimer = timer
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
        refreshAll()
    }

    // MARK: - NSMenuDelegate

    /// Rebuild the menu every time the user opens it so everything is fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addSectionHeader(to: menu, title: "Claude")
        switch latestClaudeState {
        case .ok(let snap, let updatedAt, let via):
            addClaudeRows(to: menu, snap: snap, via: via)
            addClaudeLocalRow(to: menu)
            addUpdatedRow(to: menu, updatedAt: updatedAt)
        case .degraded(let reason, let updatedAt):
            addClaudeDegradedRow(to: menu, reason: reason)
            addClaudeLocalRow(to: menu)
            addUpdatedRow(to: menu, updatedAt: updatedAt)
        case nil:
            addDisabledRow(to: menu, title: "Waiting for first fetch…")
        }

        menu.addItem(.separator())
        addSectionHeader(to: menu, title: "Codex")
        switch latestCodexState {
        case .ok(let summary, _, let updatedAt):
            addCodexRows(to: menu, summary: summary)
            addUpdatedRow(to: menu, updatedAt: updatedAt)
        case .degraded(let reason, _):
            let msg = reason == "no_sessions_dir"
                ? "No ~/.codex/sessions directory found"
                : "Session scan failed"
            addDisabledRow(to: menu, title: "⚠︎ Codex usage unavailable: \(msg)")
        case nil:
            addDisabledRow(to: menu, title: "Waiting for first scan…")
        }

        menu.addItem(.separator())
        addRefreshItem(to: menu)
        addRefreshIntervalItem(to: menu)
        addMenuBarStyleItem(to: menu)
        addResetDisplayItem(to: menu)
        addCodexDisplayItem(to: menu)
        addCodexBudgetItem(to: menu)
        addSetCookieItem(to: menu)
        addLaunchAtLoginItem(to: menu)
        menu.addItem(.separator())
        addQuitItem(to: menu)
    }

    // MARK: - Menu helpers

    private func addSectionHeader(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        menu.addItem(item)
    }

    private func addDisabledRow(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addClaudeRows(to menu: NSMenu, snap: UsageSnapshot, via: ClaudeAuthSource) {
        func row(_ bucket: Bucket?, kind: String) -> NSMenuItem {
            let label: String
            if let b = bucket {
                let kindLabel: String
                switch kind {
                case "session": kindLabel = "Session (5h)"
                case "weekly_scoped": kindLabel = b.label.capitalized + " (week)"
                default: kindLabel = "Weekly (all models)"
                }
                let resetsStr = menuDetailTime(b.resetsAt)
                label = "\(kindLabel): \(b.percent)% — resets \(resetsStr)"
            } else {
                label = kind == "session" ? "Session (5h): –" :
                        kind == "weekly_scoped" ? "Model (week): –" :
                        "Weekly (all models): –"
            }
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        menu.addItem(row(snap.session,      kind: "session"))
        menu.addItem(row(snap.weeklyScoped, kind: "weekly_scoped"))
        menu.addItem(row(snap.weeklyAll,    kind: "weekly_all"))
        switch via {
        case .claudeCode:
            addDisabledRow(to: menu, title: "Signed in via Claude Code — no cookie needed")
        case .cookie:
            if CookieStore.isUsingClusageFallback() {
                addDisabledRow(to: menu, title: "Cookie shared from Clusage")
            }
        }
    }

    /// API-equivalent value extracted from local Claude Code logs — the Claude
    /// half of the trend charts, distinct from the percent-of-limit gauges.
    private func addClaudeLocalRow(to menu: NSMenu) {
        guard case .ok(let history, _)? = latestClaudeLocalState else { return }
        let now = Date()
        let today = history.total(days: 1, endingAt: now)
        let week = history.total(days: 7, endingAt: now)
        let month = history.total(days: 30, endingAt: now)
        addDisabledRow(to: menu, title:
            "Value est.: today \(formatCost(today)) · 7d \(formatCost(week)) · 30d \(formatCost(month))")
    }

    private func addClaudeDegradedRow(to menu: NSMenu, reason: String) {
        let msg: String
        switch reason {
        case "no_auth":
            msg = "No Claude Code sign-in or cookie found — run `claude` once, or set a cookie below"
        case "oauth_http_401":
            msg = "Claude Code token rejected — run `claude` once to refresh, or set a cookie below"
        case "oauth_bad_shape":
            msg = "Unexpected API response"
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
        addDisabledRow(to: menu, title: "⚠︎ Usage unavailable: \(msg)")
    }

    /// The real monthly limit from ChatGPT's spend controls, when reported.
    private func addPlanRow(to menu: NSMenu) {
        switch latestPlanState {
        case .ok(let plan, _)?:
            let resets = menuDetailTime(plan.resetsAt)
            if plan.reached {
                addDisabledRow(to: menu, title:
                    "⚠︎ Monthly limit REACHED — \(Int(plan.limitCredits.rounded())) credits, resets \(resets)")
            } else {
                addDisabledRow(to: menu, title:
                    "Monthly limit: \(plan.usedPercent)% — "
                    + "\(Int(plan.usedCredits.rounded())) / \(Int(plan.limitCredits.rounded())) credits"
                    + " — resets \(resets)")
            }
        case .degraded(let reason, _)?:
            switch reason {
            case "no_token":
                addDisabledRow(to: menu, title: "Monthly limit: sign in with the Codex CLI to enable")
            case "http_401":
                addDisabledRow(to: menu, title: "Monthly limit: token expired — run codex once to refresh")
            default:
                break   // no spend control on this plan / transient network — budget row covers it
            }
        case nil:
            break
        }
    }

    private func addCodexRows(to menu: NSMenu, summary: CodexSummary) {
        addPlanRow(to: menu)
        let budget = CodexBudgetStore.load()
        let pct = budget > 0 ? Int((summary.monthToDateCost / budget * 100).rounded()) : 0
        addDisabledRow(to: menu, title:
            "Today: ≈\(formatCost(summary.todayCost)) — \(formatTokensLong(summary.todayTotal)) tokens (\(formatTokensLong(summary.todayOutput)) output)")
        addDisabledRow(to: menu, title:
            "Last 7 days: ≈\(formatCost(summary.last7DaysCost)) — \(formatTokensLong(summary.last7DaysTotal)) tokens")
        addDisabledRow(to: menu, title:
            "Last 30 days: ≈\(formatCost(summary.last30DaysCost)) — \(formatTokensLong(summary.last30DaysTotal)) tokens")
        addDisabledRow(to: menu, title:
            "This month: ≈\(formatCost(summary.monthToDateCost)) — \(pct)% of \(formatCost(budget))/mo budget")
        for m in summary.perModel {
            addDisabledRow(to: menu, title:
                "    \(m.model): ≈\(formatCost(m.cost)) — \(formatTokens(m.totalTokens)) (7d)")
        }
        addDisabledRow(to: menu, title: "Sessions today: \(summary.sessionsToday)")
        addLimitStatusRow(to: menu, summary: summary)
        if summary.lastActivity == nil {
            addDisabledRow(to: menu, title: "No Codex activity in the last 8 days")
        }
        addDisabledRow(to: menu, title: "Costs are API-equivalent estimates (standard tier)")
    }

    /// One line answering "am I near a limit?" with whatever the backend reports.
    /// Today that's "no limit data"; the richer branches light up the moment
    /// Codex starts populating balance / windows / spend-control flags.
    private func addLimitStatusRow(to menu: NSMenu, summary: CodexSummary) {
        guard let limit = summary.limitStatus else { return }
        if limit.isLimited {
            var reason = "usage limited"
            if limit.spendControlReached == true { reason = "org spend control reached" }
            else if let t = limit.rateLimitReachedType { reason = "rate limit reached (\(t))" }
            else if limit.hasCredits == false { reason = "out of credits" }
            addDisabledRow(to: menu, title: "⚠︎ Codex: \(reason)")
            return
        }
        if let balance = limit.creditBalance {
            addDisabledRow(to: menu, title: "Credits remaining: \(formatCost(balance))")
        } else if let pct = limit.primaryUsedPercent {
            addDisabledRow(to: menu, title: "Limit window: \(pct)% used")
        } else {
            let plan = limit.planType.map { " (\($0) plan)" } ?? ""
            addDisabledRow(to: menu, title: "No limit/balance reported by OpenAI\(plan)")
        }
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
        addDisabledRow(to: menu, title: label)
    }

    private func addRefreshItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        item.keyEquivalentModifierMask = .command
        item.target = self
        menu.addItem(item)
    }

    @objc private func refreshNow() {
        refreshAll()
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

    private func addMenuBarStyleItem(to menu: NSMenu) {
        // Menu is rebuilt on every open, so the checkmarks re-read the stored value.
        let parent = NSMenuItem(title: "Menu Bar Style", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = MenuBarStyleStore.load()
        for (i, style) in MenuBarStyle.allCases.enumerated() {
            let item = NSMenuItem(title: style.displayName,
                                  action: #selector(setMenuBarStyle(_:)), keyEquivalent: "")
            item.tag = i   // index into MenuBarStyle.allCases
            item.state = style == current ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setMenuBarStyle(_ sender: NSMenuItem) {
        let styles = MenuBarStyle.allCases
        guard sender.tag >= 0, sender.tag < styles.count else { return }
        let style = styles[sender.tag]
        MenuBarStyleStore.save(style)
        statusView.style = style
        redraw()
    }

    private func addResetDisplayItem(to menu: NSMenu) {
        // Menu is rebuilt on every open, so the checkmarks re-read the stored value.
        let parent = NSMenuItem(title: "Resets Show", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let countdown = ResetDisplayStore.showsCountdown()

        let absItem = NSMenuItem(title: "Time & Date (9:29 AM, 8/31)",
                                 action: #selector(setResetDisplay(_:)), keyEquivalent: "")
        absItem.tag = 0
        absItem.state = countdown ? .off : .on
        absItem.target = self
        submenu.addItem(absItem)

        let cdItem = NSMenuItem(title: "Time From Now (2h14m, 4d9h)",
                                action: #selector(setResetDisplay(_:)), keyEquivalent: "")
        cdItem.tag = 1
        cdItem.state = countdown ? .on : .off
        cdItem.target = self
        submenu.addItem(cdItem)

        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setResetDisplay(_ sender: NSMenuItem) {
        ResetDisplayStore.save(showsCountdown: sender.tag == 1)
        statusView.resetShowsCountdown = sender.tag == 1
        setupCountdownTimer()
        redraw()
    }

    private func addCodexDisplayItem(to menu: NSMenu) {
        // Menu is rebuilt on every open, so the checkmarks re-read the stored value.
        let parent = NSMenuItem(title: "Codex Column Shows", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let dollars = CodexDisplayStore.showsDollars()

        let dollarItem = NSMenuItem(title: "Estimated Cost ($)", action: #selector(setCodexDisplay(_:)), keyEquivalent: "")
        dollarItem.tag = 1
        dollarItem.state = dollars ? .on : .off
        dollarItem.target = self
        submenu.addItem(dollarItem)

        let tokenItem = NSMenuItem(title: "Token Counts", action: #selector(setCodexDisplay(_:)), keyEquivalent: "")
        tokenItem.tag = 0
        tokenItem.state = dollars ? .off : .on
        tokenItem.target = self
        submenu.addItem(tokenItem)

        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setCodexDisplay(_ sender: NSMenuItem) {
        CodexDisplayStore.save(showsDollars: sender.tag == 1)
        statusView.codexShowsDollars = sender.tag == 1
        redraw()
    }

    private func addCodexBudgetItem(to menu: NSMenu) {
        // Menu is rebuilt on every open, so the checkmarks re-read the stored value.
        let parent = NSMenuItem(title: "Codex Monthly Budget", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = CodexBudgetStore.load()
        for dollars in CodexBudgetStore.options {
            let item = NSMenuItem(title: String(format: "$%.0f / month", dollars),
                                  action: #selector(setCodexBudget(_:)), keyEquivalent: "")
            item.tag = Int(dollars)
            item.state = dollars == current ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setCodexBudget(_ sender: NSMenuItem) {
        CodexBudgetStore.save(Double(sender.tag))
        statusView.codexBudget = Double(sender.tag)
        redraw()
    }

    private func addSetCookieItem(to menu: NSMenu) {
        // Cookie is now the fallback path — Claude Code sign-in covers most users.
        let item = NSMenuItem(title: "Set Session Cookie (fallback)…", action: #selector(promptForCookie as () -> Void), keyEquivalent: "")
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
        // .app bundle (not via `swift run`).
        let service = SMAppService.mainApp
        let isEnabled = service.status == .enabled

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
        let item = NSMenuItem(title: "Quit Clodex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)
    }
}
