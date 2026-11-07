import Foundation

public enum StatusDisplay: String, Codable, CaseIterable {
    case iconAndText, textOnly, iconOnly
}

public enum ThemeChoice: String, Codable, CaseIterable {
    case dark, light, system
}

/// Réglages de l'appli, enregistrés en JSON dans UserDefaults.
public struct AppSettings: Codable, Equatable {
    public var statusDisplay = StatusDisplay.iconAndText
    public var showPercent = true
    public var showDeepClean = true
    public var theme = ThemeChoice.dark
    public var autoClean = false
    public var thresholdGB = 8.0
    public var cooldownMinutes = 30
    public var refreshSeconds = 5
    public var notifyClean = true
    public var notifyInactive = false
    public var showInactive = true
    public var inactiveHours = 3
    public var ignoredBundleIDs: [String] = []
    public var autoUpdate = true
    public var guardEnabled = true
    public var guardAutoQuit = false
    public var guardCPU = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusDisplay = (try? c.decode(StatusDisplay.self, forKey: .statusDisplay)) ?? d.statusDisplay
        showPercent = (try? c.decode(Bool.self, forKey: .showPercent)) ?? d.showPercent
        showDeepClean = (try? c.decode(Bool.self, forKey: .showDeepClean)) ?? d.showDeepClean
        theme = (try? c.decode(ThemeChoice.self, forKey: .theme)) ?? d.theme
        autoClean = (try? c.decode(Bool.self, forKey: .autoClean)) ?? d.autoClean
        thresholdGB = (try? c.decode(Double.self, forKey: .thresholdGB)) ?? d.thresholdGB
        cooldownMinutes = (try? c.decode(Int.self, forKey: .cooldownMinutes)) ?? d.cooldownMinutes
        refreshSeconds = (try? c.decode(Int.self, forKey: .refreshSeconds)) ?? d.refreshSeconds
        notifyClean = (try? c.decode(Bool.self, forKey: .notifyClean)) ?? d.notifyClean
        notifyInactive = (try? c.decode(Bool.self, forKey: .notifyInactive)) ?? d.notifyInactive
        showInactive = (try? c.decode(Bool.self, forKey: .showInactive)) ?? d.showInactive
        inactiveHours = (try? c.decode(Int.self, forKey: .inactiveHours)) ?? d.inactiveHours
        ignoredBundleIDs = (try? c.decode([String].self, forKey: .ignoredBundleIDs)) ?? d.ignoredBundleIDs
        autoUpdate = (try? c.decode(Bool.self, forKey: .autoUpdate)) ?? d.autoUpdate
        guardEnabled = (try? c.decode(Bool.self, forKey: .guardEnabled)) ?? d.guardEnabled
        guardAutoQuit = (try? c.decode(Bool.self, forKey: .guardAutoQuit)) ?? d.guardAutoQuit
        guardCPU = (try? c.decode(Bool.self, forKey: .guardCPU)) ?? d.guardCPU
    }

    /// Ramène les valeurs dans les plages de l'interface.
    public func normalized() -> AppSettings {
        var s = self
        s.thresholdGB = min(max(thresholdGB, 1), 64)
        s.cooldownMinutes = min(max(cooldownMinutes, 5), 240)
        s.refreshSeconds = min(max(refreshSeconds, 1), 60)
        s.inactiveHours = min(max(inactiveHours, 1), 48)
        return s
    }

    public static func decode(_ data: Data?) -> AppSettings {
        guard let data, let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s.normalized()
    }
}

/// Délai d'inactivité de l'utilisateur au-delà duquel on ne nettoie plus : sans lui, nettoyer ne fait que repousser en swap la mémoire des applis endormies.
public let autoCleanMaxIdle: TimeInterval = 20 * 60
/// Calme exigé après la dernière alerte du garde-fou avant de relancer un nettoyage.
public let autoCleanCalmNeeded: TimeInterval = 10 * 60

/// Faut-il lancer le nettoyage automatique ? Jamais sous pression (c'est le système qui libère alors la mémoire),
/// jamais juste après une alerte, jamais pendant que l'utilisateur est absent.
public func shouldAutoClean(settings: AppSettings, snapshot: MemorySnapshot, lastRun: Date?, now: Date, busy: Bool,
                            calmFor: TimeInterval = .infinity, userIdle: TimeInterval = 0) -> Bool {
    guard settings.autoClean, !busy, snapshot.pressure == .normal else { return false }
    guard calmFor >= autoCleanCalmNeeded, userIdle < autoCleanMaxIdle else { return false }
    guard Double(snapshot.available) < settings.thresholdGB * 1_073_741_824 else { return false }
    guard let lastRun else { return true }
    return now.timeIntervalSince(lastRun) >= Double(settings.cooldownMinutes) * 60
}

/// Une appli en cours d'exécution telle que vue par le suivi d'activité.
public struct AppActivity: Equatable {
    public var bundleID: String
    public var lastActive: Date

    public init(bundleID: String, lastActive: Date) {
        self.bundleID = bundleID
        self.lastActive = lastActive
    }
}

/// Une appli est inactive si elle n'a pas été au premier plan depuis `hours` heures. Le Finder et les applis ignorées n'en font jamais partie.
public func isInactive(_ app: AppActivity, hours: Int, ignored: [String], frontmost: String?, now: Date) -> Bool {
    guard app.bundleID != frontmost, app.bundleID != "com.apple.finder", !ignored.contains(app.bundleID) else { return false }
    return now.timeIntervalSince(app.lastActive) >= Double(hours) * 3600
}
