/// RefreshInterval.swift — allowed auto-refresh cadences and validation.
/// Ported from mlg87/lcj clusage-menubar.
///
/// WHY in ClodexCore: ClodexTests only depends on ClodexCore (Package.swift),
/// so the normalize policy lives here to stay unit-testable. UserDefaults I/O
/// stays in ClodexMenubar (RefreshIntervalStore).
public enum RefreshInterval {
    /// Menu choices, in display order.
    public static let allowedMinutes = [1, 2, 3, 5, 8, 13]

    /// Default cadence; also the fallback for absent/invalid stored values.
    public static let defaultMinutes = 5

    /// Clamp any stored value to an allowed choice. 0 (UserDefaults "absent")
    /// and anything not in allowedMinutes fall back to defaultMinutes.
    public static func normalize(_ minutes: Int) -> Int {
        allowedMinutes.contains(minutes) ? minutes : defaultMinutes
    }
}
