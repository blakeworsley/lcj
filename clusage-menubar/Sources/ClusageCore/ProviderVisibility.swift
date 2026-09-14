/// ProviderVisibility.swift — which providers the menu bar shows, and the rule
/// that keeps at least one of them visible.
///
/// WHY a type instead of two loose Bools: "you may hide either provider, but
/// never both" is a rule about the pair, not about either flag. Putting it here
/// (Foundation-only, unit-tested) means the menu, the view, and the refresh
/// lanes all consult one implementation instead of re-deriving it.

/// A usage provider the app can display.
public enum Provider: String, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}

/// The user's per-provider visibility preferences.
public struct ProviderVisibility: Equatable, Sendable {
    public let claude: Bool
    public let codex: Bool

    /// Both visible — the shipped default.
    public static let both = ProviderVisibility(claude: true, codex: true)
    /// The pre-Codex behaviour, and the fallback when stored values are unusable.
    public static let claudeOnly = ProviderVisibility(claude: true, codex: false)

    public init(claude: Bool, codex: Bool) {
        self.claude = claude
        self.codex = codex
    }

    /// Build from stored flags, repairing the impossible "nothing visible" state
    /// (hand-edited defaults, or a future provider being removed) by falling
    /// back to Claude — the provider this app started as.
    public static func normalize(claude: Bool, codex: Bool) -> ProviderVisibility {
        (claude || codex) ? ProviderVisibility(claude: claude, codex: codex) : .claudeOnly
    }

    public func isVisible(_ provider: Provider) -> Bool {
        switch provider {
        case .claude: return claude
        case .codex:  return codex
        }
    }

    /// True when `provider` may be toggled: always when turning one on, and when
    /// turning one off only if the other stays visible.
    public func canToggle(_ provider: Provider) -> Bool {
        isVisible(provider) ? isVisible(other(provider)) : true
    }

    /// The visibility after flipping `provider`, or nil when that would hide the
    /// last visible provider. Callers disable the menu item on nil rather than
    /// silently ignoring a click.
    public func toggling(_ provider: Provider) -> ProviderVisibility? {
        guard canToggle(provider) else { return nil }
        switch provider {
        case .claude: return ProviderVisibility(claude: !claude, codex: codex)
        case .codex:  return ProviderVisibility(claude: claude, codex: !codex)
        }
    }

    private func other(_ provider: Provider) -> Provider {
        provider == .claude ? .codex : .claude
    }
}
