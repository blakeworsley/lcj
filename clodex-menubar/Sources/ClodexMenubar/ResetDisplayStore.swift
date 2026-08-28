/// ResetDisplayStore.swift — how reset cells render: absolute ("9:29 AM",
/// "8/31") or as a countdown from now ("2h14m", "4d9h"). Same per-user
/// UserDefaults pattern as the other stores.

import Foundation

enum ResetDisplayStore {
    static let defaultsKey = "reset_shows_countdown"

    /// Defaults to absolute times/dates (the clusage-style original).
    static func showsCountdown() -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func save(showsCountdown: Bool) {
        UserDefaults.standard.set(showsCountdown, forKey: defaultsKey)
    }
}
