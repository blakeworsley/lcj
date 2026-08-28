/// StatusBarView.swift — Stats-style compact usage display for the macOS menu bar.
///
/// Four switchable visual styles (MenuBarStyle, persisted via MenuBarStyleStore).
/// Shared priorities across every style: the 5h reset time is
/// always visible, and Codex shows dollar cost with the calendar month framed
/// against a monthly budget barometer (default $100; green ≤ budget, yellow ≤ 2×,
/// red beyond — see ClodexCore.budgetBand).
///
///   grid     5H  ▓▓░ 42%   │ WK ▓░░ 17%  │ 1D $15.7 · 7D $29.7
///            RESETS 9:00PM │ F  ▓▓▓ 90%  │ MO ▓▓▓░░ $78.7          ← default
///   compact  5H 42%  RST 9:00PM  WK 17%  F 90%  MO $78.7           ← one line
///   rings    ◔ ◕ ◑ ◕  │ RESETS 9:00PM                              ← circular
///            (5 W F $) │ 1D $15.7 · MO $78.7
///   bars     ▂▅█▅  │ same text column as rings                     ← vertical
///
/// Claude data renders as percent-of-limit gauges; Codex renders as dollars
/// (or token counts per CodexDisplayStore) because Codex business/credit plans
/// expose no percent-of-limit windows — the budget gauge is the stand-in limit.
///
/// Rendering is pure NSColor / NSBezierPath so it adapts automatically to
/// light/dark menu bar appearance.

import AppKit
import ClodexCore

final class StatusBarView: NSView {

    // MARK: - Layout constants

    /// Half-spacing between the two row centers: rows sit at midY ± rowOffset.
    private static let rowOffset: CGFloat = 5.5

    // Fonts: 7pt labels / 9pt monospaced-digit values (grid + text columns).
    private static let labelFont   = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let timeFont    = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    // Compact style: slightly larger single-line values.
    private static let compactValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    // Tiny letters inside rings / under bars.
    private static let microFont = NSFont.systemFont(ofSize: 5.5, weight: .semibold)

    // Mini horizontal progress bar dimensions (grid gauges + MO budget bar)
    private static let barW: CGFloat = 20
    private static let barH: CGFloat = 4
    private static let barCorner: CGFloat = 2

    // Horizontal gaps
    private static let labelBarGap: CGFloat = 3   // label column → bar / value
    private static let barTextGap: CGFloat  = 3   // bar → value column
    private static let pairGap: CGFloat = 6       // between label/value pairs in one row

    // Vertical separator dimensions
    private static let sepW: CGFloat   = 1
    private static let sepH: CGFloat   = 16
    private static let sepPad: CGFloat = 6

    // Rings style
    private static let ringDiameter: CGFloat = 16
    private static let ringStroke: CGFloat = 2.5
    private static let ringGap: CGFloat = 5

    // Vertical-bars style
    private static let vBarW: CGFloat = 5
    private static let vBarH: CGFloat = 13
    private static let vBarGap: CGFloat = 5
    private static let vBarLabelGap: CGFloat = 1.5

    /// Grid reset-time row label (wider than "5H", sets the left label column width).
    private static let resetLabel = "RESETS"

    // MARK: - State

    var snapshot: UsageSnapshot?
    var resetDate: Date?          // session.resetsAt
    var isDegraded = false        // Claude fetch degraded
    var codexSummary: CodexSummary?
    var codexDegraded = false
    /// true → Codex values show estimated dollars; false → compact token counts.
    var codexShowsDollars = true
    var codexBudget: Double = 100
    /// Monthly spend-control state from ChatGPT; when present, the MO slot
    /// becomes a true percent-of-limit gauge instead of the $-budget barometer.
    var codexPlan: CodexPlanUsage?
    /// true → reset cells show a countdown ("2h14m", "4d9h") instead of the
    /// absolute time/date.
    var resetShowsCountdown = false
    var style: MenuBarStyle = .grid
    /// Local-log cost histories for the trend styles (nil until first scan).
    var claudeHistory: CostHistory?
    var codexHistory: CostHistory?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = false   // translucent menu bar shows through
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = false
    }

    // MARK: - Hit testing

    /// Return nil so clicks fall through to the status item's button,
    /// which opens the NSMenu.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Dispatch by style

    /// Total drawing width for the current content; AppDelegate sets
    /// statusItem.length from this.
    func preferredWidth() -> CGFloat {
        switch style {
        case .grid:    return gridPreferredWidth()
        case .lanes:   return lanesPreferredWidth()
        case .compact: return compactPreferredWidth()
        case .rings, .bars: return gaugesRowPreferredWidth()
        case .dayPulse, .weekTrend, .monthTrend:
            return trendPreferredWidth(config: trendConfig())
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .grid:    drawGrid()
        case .lanes:   drawLanes()
        case .compact: drawCompact()
        case .rings:   drawGaugesRow(rings: true)
        case .bars:    drawGaugesRow(rings: false)
        case .dayPulse, .weekTrend, .monthTrend:
            drawTrend(config: trendConfig())
        }
    }

    // MARK: - Shared measurement / drawing primitives

    private func measured(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// One 7pt secondary label + one 9pt value, drawn left-to-right at x.
    /// Returns the x after the pair.
    @discardableResult
    private func drawPair(label: String, value: String, tint: NSColor,
                          x: CGFloat, centerY: CGFloat,
                          valueFont: NSFont = StatusBarView.percentFont) -> CGFloat {
        var cx = x
        let lAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let lStr = label as NSString
        let lSize = lStr.size(withAttributes: lAttrs)
        lStr.draw(at: NSPoint(x: cx, y: centerY - lSize.height / 2), withAttributes: lAttrs)
        cx += ceil(lSize.width) + Self.labelBarGap

        let vAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont, .foregroundColor: tint]
        let vStr = value as NSString
        let vSize = vStr.size(withAttributes: vAttrs)
        vStr.draw(at: NSPoint(x: cx, y: centerY - vSize.height / 2), withAttributes: vAttrs)
        return cx + ceil(vSize.width)
    }

    private func pairWidth(label: String, value: String,
                           valueFont: NSFont = StatusBarView.percentFont) -> CGFloat {
        measured(label, font: Self.labelFont) + Self.labelBarGap
            + measured(value, font: valueFont)
    }

    /// Horizontal mini gauge (track + fill) at x, returns x after the bar.
    @discardableResult
    private func drawMiniBar(percent: Int, color: NSColor, x: CGFloat, centerY: CGFloat) -> CGFloat {
        let trackRect = NSRect(x: x, y: centerY - Self.barH / 2, width: Self.barW, height: Self.barH)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: Self.barCorner, yRadius: Self.barCorner).fill()
        let fillW = CGFloat(percent) / 100 * Self.barW
        if fillW > 0 {
            let fillRect = NSRect(x: x, y: centerY - Self.barH / 2, width: fillW, height: Self.barH)
            color.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: Self.barCorner, yRadius: Self.barCorner).fill()
        }
        return x + Self.barW
    }

    @discardableResult
    private func drawSeparator(x: CGFloat, midY: CGFloat) -> CGFloat {
        let sepRect = NSRect(x: x + Self.sepPad, y: midY - Self.sepH / 2,
                             width: Self.sepW, height: Self.sepH)
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect: sepRect).fill()
        return x + Self.sepPad + Self.sepW + Self.sepPad
    }

    private func fillColor(for percent: Int) -> NSColor {
        color(for: band(forPercent: percent))
    }

    private func color(for band: Band) -> NSColor {
        switch band {
        case .ok:       return .systemGreen
        case .warn:     return .systemYellow
        case .critical: return .systemRed
        }
    }

    // MARK: - Data helpers

    private struct GaugeEntry {
        let label: String
        let percent: Int
        let percentText: String
    }

    /// Codex display values, nil parts dash out when degraded.
    private struct CodexDisplay {
        let day: String
        let week: String
        let month: String
        let budgetPercent: Int
        let budgetColor: NSColor
        /// Short monthly-reset date ("8/31") — only when the real spend-control
        /// limit is reported; nil hides the RST pair in the Codex lane.
        let monthReset: String?
    }

    private func entriesForDisplay() -> (session: GaugeEntry, fable: GaugeEntry, week: GaugeEntry) {
        if isDegraded || snapshot == nil {
            return (
                session: GaugeEntry(label: menuBarShortLabel("5H"),    percent: 0, percentText: "–"),
                fable:   GaugeEntry(label: menuBarShortLabel("FABLE"), percent: 0, percentText: "–"),
                week:    GaugeEntry(label: menuBarShortLabel("WEEK"),  percent: 0, percentText: "–")
            )
        }
        let snap = snapshot!
        func entry(_ bucket: Bucket?, fallbackLabel: String) -> GaugeEntry {
            guard let b = bucket else {
                return GaugeEntry(label: menuBarShortLabel(fallbackLabel), percent: 0, percentText: "–")
            }
            return GaugeEntry(label: menuBarShortLabel(b.label), percent: b.percent, percentText: "\(b.percent)%")
        }
        return (
            session: entry(snap.session,      fallbackLabel: "5H"),
            fable:   entry(snap.weeklyScoped, fallbackLabel: "FABLE"),
            week:    entry(snap.weeklyAll,    fallbackLabel: "WEEK")
        )
    }

    private func codexDisplay() -> CodexDisplay {
        guard !codexDegraded, let s = codexSummary else {
            return CodexDisplay(day: "–", week: "–", month: "–",
                                budgetPercent: 0, budgetColor: .labelColor,
                                monthReset: nil)
        }
        // MO slot: prefer the real monthly limit percent (ChatGPT spend control,
        // standard limit bands); fall back to the local $-budget barometer.
        let monthText: String
        let monthPercent: Int
        let monthColor: NSColor
        let monthReset: String?
        if let plan = codexPlan {
            monthText = "\(plan.usedPercent)%"
            monthPercent = plan.usedPercent
            monthColor = color(for: band(forPercent: plan.usedPercent))
            monthReset = resetShowsCountdown
                ? menuBarCountdown(to: plan.resetsAt)
                : menuBarShortDate(plan.resetsAt)
        } else {
            let mtd = s.monthToDateCost
            monthText = codexShowsDollars ? formatCost(mtd) : formatTokens(s.monthToDateTotal)
            monthPercent = budgetFillPercent(monthCost: mtd, budget: codexBudget)
            monthColor = color(for: budgetBand(monthCost: mtd, budget: codexBudget))
            monthReset = nil
        }
        if codexShowsDollars {
            return CodexDisplay(
                day: formatCost(s.todayCost),
                week: formatCost(s.last7DaysCost),
                month: monthText,
                budgetPercent: monthPercent, budgetColor: monthColor,
                monthReset: monthReset)
        }
        return CodexDisplay(
            day: formatTokens(s.todayTotal),
            week: formatTokens(s.last7DaysTotal),
            month: monthText,
            budgetPercent: monthPercent, budgetColor: monthColor,
            monthReset: monthReset)
    }

    private func timeText() -> String {
        if isDegraded { return "–:–" }
        if resetShowsCountdown { return menuBarCountdown(to: resetDate) }
        return menuBarTime(resetDate)
    }

    // MARK: - Grid style (default)
    //
    //   5H  ▓▓░ 42%   │ WK ▓░░ 17% │ 1D $15.7 · 7D $29.7
    //   RESETS 9:00PM │ F  ▓▓▓ 90% │ MO ▓▓▓░░ $78.7

    private struct GridMetrics {
        let leftLabelW: CGFloat
        let midLabelW: CGFloat
        let pctW: CGFloat
        let leftColW: CGFloat
        let midColW: CGFloat
        let codexColW: CGFloat
    }

    private func gridMetrics() -> GridMetrics {
        let e = entriesForDisplay()

        let leftLabelW  = max(measured(e.session.label, font: Self.labelFont),
                              measured(Self.resetLabel, font: Self.labelFont))
        let midLabelW   = max(measured(e.week.label, font: Self.labelFont),
                              measured(e.fable.label, font: Self.labelFont))
        let allPctW     = max(measured(e.session.percentText, font: Self.percentFont),
                          max(measured(e.fable.percentText, font: Self.percentFont),
                              measured(e.week.percentText, font: Self.percentFont)))

        func gaugeRowW(_ lw: CGFloat) -> CGFloat {
            lw + Self.labelBarGap + Self.barW + Self.barTextGap + allPctW
        }
        let timeRowW = leftLabelW + Self.labelBarGap + measured(timeText(), font: Self.timeFont)

        return GridMetrics(
            leftLabelW: leftLabelW,
            midLabelW: midLabelW,
            pctW: allPctW,
            leftColW: max(gaugeRowW(leftLabelW), timeRowW),
            midColW: gaugeRowW(midLabelW),
            codexColW: cellGridWidth(codexGridColumns())
        )
    }

    private func gridPreferredWidth() -> CGFloat {
        let m = gridMetrics()
        let sepUnit = Self.sepPad + Self.sepW + Self.sepPad
        return 2 + m.leftColW + sepUnit + m.midColW + sepUnit + m.codexColW + 2
    }

    private func drawGrid() {
        let e = entriesForDisplay()
        let m = gridMetrics()
        let midY = bounds.midY
        let topY = midY + Self.rowOffset
        let botY = midY - Self.rowOffset
        let x0: CGFloat = 2

        drawGaugeRow(entry: e.session, x: x0, centerY: topY,
                     labelW: m.leftLabelW, pctW: m.pctW)
        drawTimeRow(x: x0, centerY: botY, labelW: m.leftLabelW, colW: m.leftColW)

        let mx = drawSeparator(x: x0 + m.leftColW, midY: midY)
        drawGaugeRow(entry: e.week,  x: mx, centerY: topY,
                     labelW: m.midLabelW, pctW: m.pctW)
        drawGaugeRow(entry: e.fable, x: mx, centerY: botY,
                     labelW: m.midLabelW, pctW: m.pctW)

        let cx = drawSeparator(x: mx + m.midColW, midY: midY)
        drawCellGrid(codexGridColumns(), x: cx, topY: topY, botY: botY)
    }

    private func drawGaugeRow(entry: GaugeEntry, x: CGFloat, centerY: CGFloat,
                              labelW: CGFloat, pctW: CGFloat) {
        drawRightAlignedLabel(entry.label, x: x, labelW: labelW, centerY: centerY)
        let barX = x + labelW + Self.labelBarGap
        drawMiniBar(percent: entry.percent, color: fillColor(for: entry.percent),
                    x: barX, centerY: centerY)
        let pAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.percentFont, .foregroundColor: NSColor.labelColor]
        let pStr = entry.percentText as NSString
        let pSize = pStr.size(withAttributes: pAttrs)
        pStr.draw(at: NSPoint(x: barX + Self.barW + Self.barTextGap + pctW - pSize.width,
                              y: centerY - pSize.height / 2),
                  withAttributes: pAttrs)
    }

    /// Reset time right-aligned to the column edge, so it lines up with the
    /// gauge percent above it instead of floating after the label.
    private func drawTimeRow(x: CGFloat, centerY: CGFloat, labelW: CGFloat, colW: CGFloat) {
        drawRightAlignedLabel(Self.resetLabel, x: x, labelW: labelW, centerY: centerY)
        drawRightAlignedValue(timeText(), tint: .labelColor,
                              rightEdge: x + colW, centerY: centerY)
    }

    private func drawRightAlignedLabel(_ label: String, x: CGFloat, labelW: CGFloat, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let str = label as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: x + labelW - size.width, y: centerY - size.height / 2),
                 withAttributes: attrs)
    }

    // MARK: - Split-lanes style
    //
    //   🦀  5H ▓▓░ 42%  WK ▓░░ 17%  F ▓▓▓ 90%  RST 9:00PM
    //   ✻   1D $15.7  7D $29.7  MO ▓▓▓░░ $78.7
    //
    // One tool per row: everything Claude on top, everything Codex below,
    // marked by tiny lane icons — the Claude Code crab and a vector rendering
    // of the OpenAI blossom (no emoji exists for it; six rounded petals at 60°
    // steps read as the mark at 10px). Same primitives as the grid, flowed
    // inline at natural widths instead of aligned columns.

    private static let laneItemGap: CGFloat = 8
    private static let laneIconSize: CGFloat = 10
    private static let crabFont = NSFont.systemFont(ofSize: 8)

    /// Icon column width shared by both lanes.
    private func laneIconW() -> CGFloat {
        max(Self.laneIconSize, measured("🦀", font: Self.crabFont))
    }

    private func drawCrabIcon(center: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.crabFont]
        let str = "🦀" as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                 withAttributes: attrs)
    }

    /// Simplified OpenAI blossom: six rounded petals rotated 60° apart.
    private func drawOpenAIIcon(center: NSPoint) {
        let size = Self.laneIconSize
        let petalW = size * 0.28
        let petalH = size * 0.92
        NSColor.labelColor.withAlphaComponent(0.75).setFill()
        for i in 0..<6 {
            let rect = NSRect(x: -petalW / 2, y: -petalH / 2, width: petalW, height: petalH)
            let petal = NSBezierPath(roundedRect: rect, xRadius: petalW / 2, yRadius: petalW / 2)
            petal.transform(using: AffineTransform(rotationByDegrees: CGFloat(i) * 60))
            petal.transform(using: AffineTransform(translationByX: center.x, byY: center.y))
            petal.fill()
        }
    }

    // MARK: Shared 2-row cell grid
    //
    // A column = one label + one cell per row. Label widths and content widths
    // are shared across both rows, so labels right-align to a common edge,
    // bars stack exactly, and values right-align so digits line up.

    /// One cell: a gauge (bar left, value right) or a plain value (right-aligned).
    private enum GridCell {
        case gauge(percent: Int, text: String, color: NSColor)
        case text(String, tint: NSColor)
        case empty
    }

    private struct GridColumn {
        let topLabel: String
        let bottomLabel: String
        let top: GridCell
        let bottom: GridCell
    }

    private func cellContentW(_ cell: GridCell) -> CGFloat {
        switch cell {
        case .gauge(_, let text, _):
            return Self.barW + Self.barTextGap + measured(text, font: Self.percentFont)
        case .text(let value, _):
            return measured(value, font: Self.percentFont)
        case .empty:
            return 0
        }
    }

    private func cellGridMetrics(_ cols: [GridColumn]) -> [(labelW: CGFloat, contentW: CGFloat)] {
        cols.map { col in
            (labelW: max(measured(col.topLabel, font: Self.labelFont),
                         measured(col.bottomLabel, font: Self.labelFont)),
             contentW: max(cellContentW(col.top), cellContentW(col.bottom)))
        }
    }

    private func cellGridWidth(_ cols: [GridColumn]) -> CGFloat {
        let metrics = cellGridMetrics(cols)
        var w: CGFloat = 0
        for (i, m) in metrics.enumerated() {
            w += m.labelW + Self.labelBarGap + m.contentW
            if i < metrics.count - 1 { w += Self.laneItemGap }
        }
        return w
    }

    private func drawCell(_ cell: GridCell, x: CGFloat, contentW: CGFloat, centerY: CGFloat) {
        switch cell {
        case .gauge(let percent, let text, let color):
            drawMiniBar(percent: percent, color: color, x: x, centerY: centerY)
            drawRightAlignedValue(text, tint: .labelColor, rightEdge: x + contentW, centerY: centerY)
        case .text(let value, let tint):
            drawRightAlignedValue(value, tint: tint, rightEdge: x + contentW, centerY: centerY)
        case .empty:
            break
        }
    }

    private func drawRightAlignedValue(_ value: String, tint: NSColor,
                                       rightEdge: CGFloat, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.percentFont, .foregroundColor: tint]
        let str = value as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: rightEdge - ceil(size.width),
                             y: centerY - size.height / 2), withAttributes: attrs)
    }

    /// Draw a cell grid starting at x; returns the x after the grid.
    @discardableResult
    private func drawCellGrid(_ cols: [GridColumn], x: CGFloat,
                              topY: CGFloat, botY: CGFloat) -> CGFloat {
        let metrics = cellGridMetrics(cols)
        var cx = x
        for i in 0..<cols.count {
            let m = metrics[i]
            if case .empty = cols[i].top {} else {
                drawRightAlignedLabel(cols[i].topLabel, x: cx, labelW: m.labelW, centerY: topY)
            }
            if case .empty = cols[i].bottom {} else {
                drawRightAlignedLabel(cols[i].bottomLabel, x: cx, labelW: m.labelW, centerY: botY)
            }
            let contentX = cx + m.labelW + Self.labelBarGap
            drawCell(cols[i].top, x: contentX, contentW: m.contentW, centerY: topY)
            drawCell(cols[i].bottom, x: contentX, contentW: m.contentW, centerY: botY)
            cx = contentX + m.contentW + Self.laneItemGap
        }
        return cx - Self.laneItemGap
    }

    /// The Codex 2×2 block shared by grid (as its right column) and lanes:
    ///   1D $16.2   7D $30.1
    ///   MO ▓ 84%   RST 8/31
    private func codexGridColumns() -> [GridColumn] {
        let c = codexDisplay()
        return [
            GridColumn(topLabel: "1D", bottomLabel: "MO",
                       top: .text(c.day, tint: .labelColor),
                       bottom: .gauge(percent: c.budgetPercent, text: c.month, color: c.budgetColor)),
            GridColumn(topLabel: "7D", bottomLabel: c.monthReset != nil ? "RST" : "",
                       top: .text(c.week, tint: .labelColor),
                       bottom: c.monthReset.map { .text($0, tint: .labelColor) } ?? .empty),
        ]
    }

    /// The 2×4 lanes grid: 5H/1D · WK/7D · F/MO (bars stack) · RST/RST.
    private func laneColumns() -> [GridColumn] {
        let e = entriesForDisplay()
        let c = codexDisplay()
        func gauge(_ entry: GaugeEntry) -> GridCell {
            .gauge(percent: entry.percent, text: entry.percentText,
                   color: fillColor(for: entry.percent))
        }
        return [
            GridColumn(topLabel: e.session.label, bottomLabel: "1D",
                       top: gauge(e.session), bottom: .text(c.day, tint: .labelColor)),
            GridColumn(topLabel: e.week.label, bottomLabel: "7D",
                       top: gauge(e.week), bottom: .text(c.week, tint: .labelColor)),
            GridColumn(topLabel: e.fable.label, bottomLabel: "MO",
                       top: gauge(e.fable),
                       bottom: .gauge(percent: c.budgetPercent, text: c.month, color: c.budgetColor)),
            GridColumn(topLabel: "RST", bottomLabel: c.monthReset != nil ? "RST" : "",
                       top: .text(timeText(), tint: .labelColor),
                       bottom: c.monthReset.map { .text($0, tint: .labelColor) } ?? .empty),
        ]
    }

    private func lanesPreferredWidth() -> CGFloat {
        2 + laneIconW() + Self.labelBarGap + 1 + cellGridWidth(laneColumns()) + 2
    }

    private func drawLanes() {
        let midY = bounds.midY
        let topY = midY + Self.rowOffset
        let botY = midY - Self.rowOffset
        let iconW = laneIconW()

        drawCrabIcon(center: NSPoint(x: 2 + iconW / 2, y: topY))
        drawOpenAIIcon(center: NSPoint(x: 2 + iconW / 2, y: botY))
        drawCellGrid(laneColumns(), x: 2 + iconW + Self.labelBarGap + 1,
                     topY: topY, botY: botY)
    }

    // MARK: - Compact style
    //
    //   5H 42%  RST 9:00PM  WK 17%  F 90%  MO $78.7
    //   (percent values tinted by limit band; MO tinted by budget band;
    //    1D/7D live in the dropdown to keep the line short)

    private func compactItems() -> [(label: String, value: String, tint: NSColor)] {
        let e = entriesForDisplay()
        let c = codexDisplay()
        func tint(_ entry: GaugeEntry) -> NSColor {
            entry.percentText == "–" ? .labelColor : fillColor(for: entry.percent)
        }
        var items: [(label: String, value: String, tint: NSColor)] = [
            (e.session.label, e.session.percentText, tint(e.session)),
            ("RST", timeText(), .labelColor),
            (e.week.label, e.week.percentText, tint(e.week)),
            (e.fable.label, e.fable.percentText, tint(e.fable)),
            ("MO", c.month, c.month == "–" ? .labelColor : c.budgetColor),
        ]
        if let reset = c.monthReset {
            items.append(("RST", reset, .labelColor))
        }
        return items
    }

    private static let compactGroupGap: CGFloat = 8

    private func compactPreferredWidth() -> CGFloat {
        let items = compactItems()
        var w: CGFloat = 2 + 2
        for (i, item) in items.enumerated() {
            w += pairWidth(label: item.label, value: item.value,
                           valueFont: Self.compactValueFont)
            if i < items.count - 1 { w += Self.compactGroupGap }
        }
        return w
    }

    private func drawCompact() {
        let midY = bounds.midY
        var x: CGFloat = 2
        for item in compactItems() {
            x = drawPair(label: item.label, value: item.value, tint: item.tint,
                         x: x, centerY: midY, valueFont: Self.compactValueFont)
            x += Self.compactGroupGap
        }
    }

    // MARK: - Rings / vertical-bars styles (shared layout)
    //
    //   ◔ ◕ ◑ ◕  │ RESETS 9:00PM
    //   5 W F $   │ 1D $15.7 · MO $78.7
    //
    // Gauges: three Claude limits + the Codex monthly budget ("$"). The text
    // column keeps the reset time on top and day + month cost below.

    private func gaugeCellW() -> CGFloat {
        style == .rings ? Self.ringDiameter : max(Self.vBarW, 7)
    }

    private func gaugesBlockWidth() -> CGFloat {
        let gap = style == .rings ? Self.ringGap : Self.vBarGap
        return 4 * gaugeCellW() + 3 * gap
    }

    private func gaugesTextColWidth() -> CGFloat {
        let c = codexDisplay()
        let row1 = pairWidth(label: "RST", value: timeText())
        var row2 = pairWidth(label: "1D", value: c.day) + Self.pairGap
            + pairWidth(label: "MO", value: c.month)
        if let reset = c.monthReset {
            row2 += Self.pairGap + pairWidth(label: "RST", value: reset)
        }
        return max(row1, row2)
    }

    private func gaugesRowPreferredWidth() -> CGFloat {
        let sepUnit = Self.sepPad + Self.sepW + Self.sepPad
        return 2 + gaugesBlockWidth() + sepUnit + gaugesTextColWidth() + 2
    }

    private func drawGaugesRow(rings: Bool) {
        let e = entriesForDisplay()
        let c = codexDisplay()
        let midY = bounds.midY
        let gap = rings ? Self.ringGap : Self.vBarGap
        let cellW = gaugeCellW()

        // (letter, percent, color) for the four gauges.
        let gauges: [(String, Int, NSColor)] = [
            (String(e.session.label.prefix(1)), e.session.percent, fillColor(for: e.session.percent)),
            (String(e.week.label.prefix(1)),    e.week.percent,    fillColor(for: e.week.percent)),
            (String(e.fable.label.prefix(1)),   e.fable.percent,   fillColor(for: e.fable.percent)),
            ("$", c.budgetPercent, c.budgetColor),
        ]

        var x: CGFloat = 2
        for (letter, percent, color) in gauges {
            if rings {
                drawRing(letter: letter, percent: percent, color: color, x: x, midY: midY)
            } else {
                drawVBar(letter: letter, percent: percent, color: color, x: x, cellW: cellW, midY: midY)
            }
            x += cellW + gap
        }
        x -= gap

        let cx = drawSeparator(x: x, midY: midY)
        drawPair(label: "RST", value: timeText(), tint: .labelColor,
                 x: cx, centerY: midY + Self.rowOffset)
        let afterDay = drawPair(label: "1D", value: c.day, tint: .labelColor,
                                x: cx, centerY: midY - Self.rowOffset)
        let afterMonth = drawPair(label: "MO", value: c.month,
                                  tint: c.month == "–" ? .labelColor : c.budgetColor,
                                  x: afterDay + Self.pairGap, centerY: midY - Self.rowOffset)
        if let reset = c.monthReset {
            drawPair(label: "RST", value: reset, tint: .labelColor,
                     x: afterMonth + Self.pairGap, centerY: midY - Self.rowOffset)
        }
    }

    private func drawRing(letter: String, percent: Int, color: NSColor, x: CGFloat, midY: CGFloat) {
        let d = Self.ringDiameter
        let center = NSPoint(x: x + d / 2, y: midY)
        let radius = (d - Self.ringStroke) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = Self.ringStroke
        NSColor.labelColor.withAlphaComponent(0.15).setStroke()
        track.stroke()

        if percent > 0 {
            let sweep = 360 * CGFloat(percent) / 100
            let fill = NSBezierPath()
            fill.appendArc(withCenter: center, radius: radius,
                           startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            fill.lineWidth = Self.ringStroke
            fill.lineCapStyle = .round
            color.setStroke()
            fill.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.microFont, .foregroundColor: NSColor.secondaryLabelColor]
        let str = letter as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                 withAttributes: attrs)
    }

    // MARK: - Trend styles (dayPulse / weekTrend / monthTrend)
    //
    //   ▁▃▂▅▁▂█  │ C $205 · X $15.7
    //   (stacked) │ 5H 42% · RST 9:00PM
    //
    // Design language: history is NEVER traffic-light colored — trends aren't
    // alarms. Claude is neutral gray, Codex is the user's accent color, stacked
    // per bucket and scaled to the window max; the current bucket renders at
    // full opacity so "now" pops. The C/X totals beside the chart are tinted in
    // their bar colors, forming the legend. Limit colors stay reserved for the
    // 5H percent (and budget elsewhere).

    private struct TrendConfig {
        let buckets: [String]      // oldest → newest; last one is "now"
        let hourly: Bool
        let barW: CGFloat
        let barGap: CGFloat
        let claudeTotalLabel: String
        let codexTotalLabel: String
        let claudeTotal: Double?   // nil → "–"
        let codexTotal: Double?
    }

    private func trendConfig() -> TrendConfig {
        let now = Date()
        switch style {
        case .weekTrend:
            return TrendConfig(
                buckets: dayKeys(last: 7, endingAt: now), hourly: false,
                barW: 4, barGap: 1.5,
                claudeTotalLabel: "C7D", codexTotalLabel: "X7D",
                claudeTotal: claudeHistory?.total(days: 7, endingAt: now),
                codexTotal: codexHistory != nil ? codexSummary?.last7DaysCost : nil)
        case .monthTrend:
            return TrendConfig(
                buckets: dayKeys(last: 30, endingAt: now), hourly: false,
                barW: 2, barGap: 1,
                claudeTotalLabel: "C30", codexTotalLabel: "X30",
                claudeTotal: claudeHistory?.total(days: 30, endingAt: now),
                codexTotal: codexHistory != nil ? codexSummary?.last30DaysCost : nil)
        default: // .dayPulse
            return TrendConfig(
                buckets: hourKeys(last: 12, endingAt: now), hourly: true,
                barW: 3, barGap: 1,
                claudeTotalLabel: "C1D", codexTotalLabel: "X1D",
                claudeTotal: claudeHistory?.total(days: 1, endingAt: now),
                codexTotal: codexHistory != nil ? codexSummary?.todayCost : nil)
        }
    }

    private var claudeBarColor: NSColor { NSColor.labelColor.withAlphaComponent(0.4) }
    private var codexBarColor: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.85) }

    private func trendChartWidth(_ c: TrendConfig) -> CGFloat {
        CGFloat(c.buckets.count) * c.barW + CGFloat(c.buckets.count - 1) * c.barGap
    }

    private func trendTextColWidth(_ c: TrendConfig) -> CGFloat {
        let e = entriesForDisplay()
        let row1 = pairWidth(label: c.claudeTotalLabel, value: trendMoney(c.claudeTotal))
            + Self.pairGap
            + pairWidth(label: c.codexTotalLabel, value: trendMoney(c.codexTotal))
        let row2 = pairWidth(label: e.session.label, value: e.session.percentText)
            + Self.pairGap
            + pairWidth(label: "RST", value: timeText())
        return max(row1, row2)
    }

    private func trendMoney(_ v: Double?) -> String {
        guard let v else { return "–" }
        return formatCost(v)
    }

    private func trendPreferredWidth(config c: TrendConfig) -> CGFloat {
        let sepUnit = Self.sepPad + Self.sepW + Self.sepPad
        return 2 + trendChartWidth(c) + sepUnit + trendTextColWidth(c) + 2
    }

    private func drawTrend(config c: TrendConfig) {
        let midY = bounds.midY
        let chartH: CGFloat = 15
        let chartBottom = midY - chartH / 2
        let chartW = trendChartWidth(c)

        // Baseline anchors the chart even when every bucket is zero.
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(rect: NSRect(x: 2, y: chartBottom - 1.5, width: chartW, height: 1)).fill()

        let claudeSeries = historySeries(
            c.hourly ? (claudeHistory?.hourlyCost ?? [:]) : (claudeHistory?.dailyCost ?? [:]),
            keys: c.buckets)
        let codexSeries = historySeries(
            c.hourly ? (codexHistory?.hourlyCost ?? [:]) : (codexHistory?.dailyCost ?? [:]),
            keys: c.buckets)
        let maxTotal = max(zip(claudeSeries, codexSeries).map(+).max() ?? 0, 0.0001)

        var x: CGFloat = 2
        for i in 0..<c.buckets.count {
            let isCurrent = i == c.buckets.count - 1
            let cH = chartH * CGFloat(claudeSeries[i] / maxTotal)
            let xH = chartH * CGFloat(codexSeries[i] / maxTotal)
            if cH > 0.4 {
                (isCurrent ? NSColor.labelColor.withAlphaComponent(0.8) : claudeBarColor).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: chartBottom, width: c.barW, height: cH),
                             xRadius: 0.8, yRadius: 0.8).fill()
            }
            if xH > 0.4 {
                (isCurrent ? NSColor.controlAccentColor : codexBarColor).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: chartBottom + cH, width: c.barW, height: xH),
                             xRadius: 0.8, yRadius: 0.8).fill()
            }
            x += c.barW + c.barGap
        }
        x -= c.barGap

        let e = entriesForDisplay()
        let cx = drawSeparator(x: x, midY: midY)
        // Row 1: window totals, tinted as the legend for the stacked segments.
        let afterClaude = drawPair(
            label: c.claudeTotalLabel, value: trendMoney(c.claudeTotal),
            tint: .labelColor, x: cx, centerY: midY + Self.rowOffset)
        drawPair(label: c.codexTotalLabel, value: trendMoney(c.codexTotal),
                 tint: .controlAccentColor,
                 x: afterClaude + Self.pairGap, centerY: midY + Self.rowOffset)
        // Row 2: the always-on signals — 5H percent (band-tinted) + reset time.
        let sessionTint: NSColor = e.session.percentText == "–"
            ? .labelColor : fillColor(for: e.session.percent)
        let afterSession = drawPair(
            label: e.session.label, value: e.session.percentText,
            tint: sessionTint, x: cx, centerY: midY - Self.rowOffset)
        drawPair(label: "RST", value: timeText(), tint: .labelColor,
                 x: afterSession + Self.pairGap, centerY: midY - Self.rowOffset)
    }

    private func drawVBar(letter: String, percent: Int, color: NSColor,
                          x: CGFloat, cellW: CGFloat, midY: CGFloat) {
        let labelH: CGFloat = 7
        let totalH = Self.vBarH + Self.vBarLabelGap + labelH
        let barBottom = midY - totalH / 2 + labelH + Self.vBarLabelGap

        let barX = x + (cellW - Self.vBarW) / 2
        let trackRect = NSRect(x: barX, y: barBottom, width: Self.vBarW, height: Self.vBarH)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 1.5, yRadius: 1.5).fill()

        let fillH = Self.vBarH * CGFloat(percent) / 100
        if fillH > 0 {
            let fillRect = NSRect(x: barX, y: barBottom, width: Self.vBarW, height: fillH)
            color.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.microFont, .foregroundColor: NSColor.secondaryLabelColor]
        let str = letter as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: x + (cellW - size.width) / 2,
                             y: barBottom - Self.vBarLabelGap - size.height + 1),
                 withAttributes: attrs)
    }
}
