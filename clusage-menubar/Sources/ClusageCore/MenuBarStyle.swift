/// MenuBarStyle.swift — the user's choice of menu bar layout, and its validation.
///
/// WHY in ClusageCore: same reason as RefreshInterval — the normalize policy
/// stays unit-testable while UserDefaults I/O lives in the app (MenuBarStyleStore).
public enum MenuBarStyle: String, CaseIterable, Sendable {
    /// The original Stats-style grid: percent USED per limit, reset time in its
    /// own RESETS cell, Codex costs in the third column.
    case grid
    /// Two provider blocks (Claude ✻ / Codex blossom); every displayed limit is
    /// rendered as "N% left · ↻<countdown>" on a draining segmented bar. Dollar
    /// estimates and secondary limits live in the dropdown only.
    case remaining

    /// Pre-existing layout, also the fallback for absent/unknown stored values.
    public static let defaultStyle = MenuBarStyle.grid

    /// Menu title.
    public var displayName: String {
        switch self {
        case .grid:      return "Usage Grid (% used, reset time)"
        case .remaining: return "Remaining Capacity (% left, countdown)"
        }
    }

    /// Map a stored raw value to a style; nil/unknown → default.
    public static func normalize(_ raw: String?) -> MenuBarStyle {
        raw.flatMap(MenuBarStyle.init(rawValue:)) ?? defaultStyle
    }
}
