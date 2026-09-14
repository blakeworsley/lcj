/// AppDelegate.swift — status item, menu wiring, and refresh cadence.
///
/// Plain AppKit; no SwiftUI. The status item hosts a custom StatusBarView subview
/// so we get pixel-precise Stats-style layout. The NSMenu is rebuilt on every open
/// (menuNeedsUpdate delegate) so the dropdown always shows fresh data.
///
/// Three refresh lanes share one cadence: the claude.ai limit fetch (UsageFetcher),
/// the Codex local session-log scan (CodexScanner), and the ChatGPT monthly
/// spend-control fetch (CodexPlanFetcher). The Codex lanes are no-ops on Macs
/// without a Codex install — the scanner degrades before touching the network,
/// and the plan fetcher stops at the missing ~/.codex/auth.json.

import AppKit
import ClusageCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Ivars

    private var statusItem: NSStatusItem!
    private var statusView: StatusBarView!
    private let fetcher = UsageFetcher()
    private let planFetcher = CodexPlanFetcher()
    private var latestState: FetchState?
    private var latestCodexState: CodexScanState?
    private var latestPlanState: CodexPlanState?
    private var refreshTimer: Timer?
    /// Minute tick that repaints countdowns in the Remaining layout; display only.
    private var countdownTimer: Timer?
    /// Guards against overlapping scans. A cold scan runs for tens of seconds
    /// while the timer, wake, ⌘R and every provider toggle all call refreshAll(),
    /// so without this two scans parse the same files, each occupy a utility
    /// thread in synchronous file I/O, and can land out of order — a slow older
    /// scan overwriting latestCodexState with staler data than is on screen.
    private var scanInFlight = false

    // MARK: - applicationDidFinishLaunching

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        setupFetcher()
        setupRefreshTimer()
        setupWakeObserver()

        // Initial fetch — menu bar shows "–" until the first response arrives.
        refreshAll()
        // First run: no cookie stored → open the paste dialog once, after launch settles.
        // WHY DispatchQueue.main.async: gives AppKit time to finish setting up the status
        // item before we show an alert; calling runModal() during launch can hang the app.
        if CookieStore.load() == nil && statusView.visibility.claude {
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
        setupCountdownTimer()
        statusView.visibility = ProviderVisibilityStore.load()
        statusView.codexShowsDollars = CodexDisplayStore.showsDollars()
        statusView.codexBudget = CodexBudgetStore.load()
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

    /// Kick the lanes for visible providers only. A hidden provider costs
    /// nothing: no claude.ai request, and no filesystem scan (the expensive one).
    /// Re-enabling a provider refreshes it immediately, so the pause is invisible.
    ///
    /// The Codex lanes also require an actual install. Without that gate, a Mac
    /// with ~/.codex/auth.json but no sessions (signed in, logs cleaned up) would
    /// send a Bearer-authenticated request to an undocumented endpoint on every
    /// refresh, forever, while the UI never shows the result.
    private func refreshAll() {
        let visibility = ProviderVisibilityStore.load()
        if visibility.claude {
            fetcher.fetchNow()
        }
        if visibility.codex && CodexScanner.isCodexInstalled() {
            planFetcher.fetchNow()
            scanCodexNow()
        }
    }

    /// Run the blocking filesystem scan off the main thread, then apply on main.
    /// WHY Task.detached: the first-ever scan reads hundreds of MB of session
    /// logs; inheriting the main actor would freeze the menu bar for seconds.
    private func scanCodexNow() {
        guard !scanInFlight else { return }
        scanInFlight = true
        Task.detached(priority: .utility) {
            let state = CodexScanner.shared.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanInFlight = false
                self.latestCodexState = state
                self.applyCodexState(state)
            }
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
        redraw()
    }

    private func applyCodexState(_ state: CodexScanState) {
        switch state {
        case .ok(let summary, _):
            statusView.codexSummary = summary
        case .degraded:
            statusView.codexSummary = nil
        }
        redraw()
    }

    private func redraw() {
        // One reference date per repaint: preferredWidth() measures the countdown
        // text and draw() renders it, so two separate Date() reads could straddle
        // a minute boundary and clip "1h" into "59m".
        statusView.renderDate = Date()
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
            Task { @MainActor [weak self] in self?.refreshAll() }
        }
        // Proportional slack lets the OS batch with other timers (saves battery);
        // 10% preserves the previous 30s-at-5-min ratio at every interval.
        timer.tolerance = seconds * 0.1
        refreshTimer = timer
    }

    /// The Remaining layout shows "↻19m" countdowns, which go stale between data
    /// refreshes; repaint each minute while that layout is active. No I/O.
    private func setupCountdownTimer() {
        countdownTimer?.invalidate()
        guard statusView.style == .remaining else {
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

        // Sections mirror the menu bar: a hidden provider is absent here too.
        // Codex additionally needs an install to have anything to report, so a
        // Claude-only Mac sees no CLAUDE/CODEX headers and no Codex rows. It is
        // not byte-for-byte the pre-Codex dropdown: the usage rows now say
        // "% used", and Menu Bar Layout / Show in Menu Bar are always present.
        let visibility = ProviderVisibilityStore.load()
        let showCodexSection = visibility.codex && CodexScanner.isCodexInstalled()
        let showClaudeSection = visibility.claude || !showCodexSection

        if showClaudeSection && showCodexSection { addSectionHeader(to: menu, title: "Claude") }
        if showClaudeSection {
            switch latestState {
            case .ok(let snap, let updatedAt):
                addUsageRows(to: menu, snap: snap)
                addUpdatedRow(to: menu, updatedAt: updatedAt)
            case .degraded(let reason, let updatedAt):
                addDegradedRow(to: menu, reason: reason)
                addUpdatedRow(to: menu, updatedAt: updatedAt)
            case nil:
                addDisabledRow(to: menu, title: "Waiting for first fetch…")
            }
        }

        if showCodexSection {
            if showClaudeSection { menu.addItem(.separator()) }
            addSectionHeader(to: menu, title: "Codex")
            switch latestCodexState {
            case .ok(let summary, let updatedAt):
                addCodexRows(to: menu, summary: summary)
                addUpdatedRow(to: menu, updatedAt: updatedAt)
            case .degraded:
                addDisabledRow(to: menu, title: "⚠︎ Codex usage unavailable: session scan failed")
            case nil:
                addDisabledRow(to: menu, title: "Waiting for first scan…")
            }
        }

        menu.addItem(.separator())
        addRefreshItem(to: menu)
        addRefreshIntervalItem(to: menu)
        addMenuBarLayoutItem(to: menu)
        addShowInMenuBarItem(to: menu)
        if showCodexSection { addCodexColumnItem(to: menu) }
        if showClaudeSection { addSetCookieItem(to: menu) }
        addLaunchAtLoginItem(to: menu)
        menu.addItem(.separator())
        addQuitItem(to: menu)
    }

    // MARK: - Menu helpers

    private func addDisabledRow(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

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
                label = "\(kindLabel): \(b.percent)% used — resets \(resetsStr)"
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
        addDisabledRow(to: menu, title: "⚠︎ Usage unavailable: \(msg)")
    }

    // MARK: Codex rows

    private func addCodexRows(to menu: NSMenu, summary: CodexSummary) {
        addPlanRow(to: menu)
        addDisabledRow(to: menu, title:
            "Today: ≈\(formatCost(summary.todayCost)) — \(formatTokensLong(summary.todayTotal)) tokens (\(formatTokensLong(summary.todayOutput)) output)")
        addDisabledRow(to: menu, title:
            "Last 7 days: ≈\(formatCost(summary.last7DaysCost)) — \(formatTokensLong(summary.last7DaysTotal)) tokens")
        addDisabledRow(to: menu, title:
            "Last 30 days: ≈\(formatCost(summary.last30DaysCost)) — \(formatTokensLong(summary.last30DaysTotal)) tokens")
        // The $ budget line is the MO gauge's meaning only when no real limit is
        // reported; with a spend control the plan row above already covers MO.
        if case .ok? = latestPlanState {
            addDisabledRow(to: menu, title:
                "This month: ≈\(formatCost(summary.monthToDateCost)) — \(formatTokensLong(summary.monthToDateTotal)) tokens")
        } else {
            let budget = CodexBudgetStore.load()
            let pct = budget > 0 ? Int((summary.monthToDateCost / budget * 100).rounded()) : 0
            addDisabledRow(to: menu, title:
                "This month: ≈\(formatCost(summary.monthToDateCost)) — \(pct)% of your \(formatCost(budget))/mo budget (personal budget, not a provider limit)")
        }
        for m in summary.perModel {
            addDisabledRow(to: menu, title:
                "    \(m.model): ≈\(formatCost(m.cost)) — \(formatTokens(m.totalTokens)) (7d)")
        }
        addDisabledRow(to: menu, title: "Sessions today: \(summary.sessionsToday)")
        addLimitStatusRow(to: menu, summary: summary)
        if summary.lastActivity == nil {
            addDisabledRow(to: menu, title: "No Codex activity in the last 30 days")
        }
        addDisabledRow(to: menu, title: "Costs are API-equivalent estimates (standard tier)")
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
                    "Monthly limit (ChatGPT spend control): \(plan.usedPercent)% used — "
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

    /// One line answering "am I near a limit?" with whatever the backend reports
    /// in the session logs. Today that's usually "no limit data"; the richer
    /// branches light up the moment Codex starts populating balance / windows /
    /// spend-control flags.
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
        } else if case .ok? = latestPlanState {
            // The spend-control row already answers the limit question.
        } else {
            let plan = limit.planType.map { " (\($0) plan)" } ?? ""
            addDisabledRow(to: menu, title: "No provider limit or balance reported by OpenAI\(plan) — MO gauge uses your budget")
        }
    }

    // MARK: Shared rows

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

    // MARK: Menu bar layout

    private func addMenuBarLayoutItem(to menu: NSMenu) {
        // Menu is rebuilt on every open, so the checkmark re-reads the stored value.
        let parent = NSMenuItem(title: "Menu Bar Layout", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = MenuBarStyleStore.load()
        for (i, style) in MenuBarStyle.allCases.enumerated() {
            let item = NSMenuItem(title: style.displayName, action: #selector(setMenuBarStyle(_:)), keyEquivalent: "")
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
        guard styles.indices.contains(sender.tag) else { return }
        MenuBarStyleStore.save(styles[sender.tag])
        statusView.style = styles[sender.tag]
        setupCountdownTimer()
        redraw()
    }

    // MARK: Codex column settings

    /// Per-provider visibility. Either can be hidden, never both: the last
    /// visible provider's item is drawn checked but disabled (action nil) so the
    /// rule is visible in the menu rather than a click that silently does
    /// nothing. Hiding Claude is also blocked when Codex has no install to
    /// report on, which would otherwise leave a menu bar of dashes.
    private func addShowInMenuBarItem(to menu: NSMenu) {
        let parent = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let visibility = ProviderVisibilityStore.load()
        let codexUsable = CodexScanner.isCodexInstalled()

        for (i, provider) in Provider.allCases.enumerated() {
            let shown = visibility.isVisible(provider)
            var allowed = visibility.canToggle(provider)
            // Claude can't be hidden when Codex has nothing to show, and the
            // Codex row itself is inert on a Mac without Codex — leaving it
            // checked and clickable would promise a column that never appears.
            if !codexUsable { allowed = false }
            let item = NSMenuItem(title: provider.displayName,
                                  action: allowed ? #selector(toggleProvider(_:)) : nil,
                                  keyEquivalent: "")
            item.tag = i   // index into Provider.allCases
            item.state = shown ? .on : .off
            if allowed { item.target = self }
            submenu.addItem(item)
        }
        if !codexUsable {
            addDisabledRow(to: submenu, title: "No Codex install detected (~/.codex/sessions or archived_sessions)")
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        let providers = Provider.allCases
        guard providers.indices.contains(sender.tag),
              let next = ProviderVisibilityStore.load().toggling(providers[sender.tag])
        else { return }
        ProviderVisibilityStore.save(next)
        statusView.visibility = next
        // A provider just turned back on has stale (or no) data — refresh now so
        // it doesn't sit on dashes until the next tick.
        refreshAll()
        redraw()
    }

    /// One "Codex Column" submenu holds the remaining Codex preferences:
    /// $ vs tokens, and the fallback budget.
    private func addCodexColumnItem(to menu: NSMenu) {
        let parent = NSMenuItem(title: "Codex Column", action: nil, keyEquivalent: "")
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

        submenu.addItem(.separator())
        let budgetParent = NSMenuItem(title: "Monthly Budget", action: nil, keyEquivalent: "")
        let budgetMenu = NSMenu()
        let current = CodexBudgetStore.load()
        for amount in CodexBudgetStore.options {
            let item = NSMenuItem(title: String(format: "$%.0f / month", amount),
                                  action: #selector(setCodexBudget(_:)), keyEquivalent: "")
            item.tag = Int(amount)
            item.state = amount == current ? .on : .off
            item.target = self
            budgetMenu.addItem(item)
        }
        budgetParent.submenu = budgetMenu
        submenu.addItem(budgetParent)

        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setCodexDisplay(_ sender: NSMenuItem) {
        CodexDisplayStore.save(showsDollars: sender.tag == 1)
        statusView.codexShowsDollars = sender.tag == 1
        redraw()
    }

    @objc private func setCodexBudget(_ sender: NSMenuItem) {
        CodexBudgetStore.save(Double(sender.tag))
        statusView.codexBudget = Double(sender.tag)
        redraw()
    }

    // MARK: Cookie

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

    // MARK: Launch at login / quit

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
