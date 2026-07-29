/// RefreshInterval.swift — allowed auto-refresh cadences and validation.
///
/// WHY in ClusageCore: ClusageTests only depends on ClusageCore (Package.swift),
/// so the normalize policy lives here to stay unit-testable. UserDefaults I/O
/// stays in ClusageMenubar (RefreshIntervalStore).
public enum RefreshInterval {
    /// Menu choices, in display order.
    public static let allowedMinutes = [1, 2, 3, 5, 8, 13]

    /// Pre-existing hard-coded cadence (v0.1.0 shipped a fixed 5-min timer);
    /// also the fallback for absent/invalid stored values.
    public static let defaultMinutes = 5

    /// Clamp any stored value to an allowed choice. 0 (UserDefaults "absent")
    /// and anything not in allowedMinutes fall back to defaultMinutes.
    public static func normalize(_ minutes: Int) -> Int {
        allowedMinutes.contains(minutes) ? minutes : defaultMinutes
    }
}
