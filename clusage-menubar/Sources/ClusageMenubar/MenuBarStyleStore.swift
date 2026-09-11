/// MenuBarStyleStore.swift — UserDefaults-backed persistence for the menu bar
/// layout. Same per-user domain/pattern as RefreshIntervalStore; validation
/// lives in ClusageCore.MenuBarStyle so it stays unit-testable.

import ClusageCore
import Foundation

enum MenuBarStyleStore {
    static let defaultsKey = "menubar_style"

    static func load() -> MenuBarStyle {
        MenuBarStyle.normalize(UserDefaults.standard.string(forKey: defaultsKey))
    }

    static func save(_ style: MenuBarStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: defaultsKey)
    }
}
