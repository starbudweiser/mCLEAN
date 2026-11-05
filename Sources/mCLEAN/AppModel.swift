import AppKit
import Combine
import MCleanCore
import os

enum Log {
    static let app = Logger(subsystem: "com.stephan.mclean", category: "app")
}

/// Une appli affichée dans le panneau.
struct AppUsage: Identifiable, Equatable {
    var id: pid_t
    var name: String
    var bundleID: String
    var icon: NSImage?
    var bytes: UInt64
    var lastActive: Date
}

/// État de l'appli : relevés, applis, nettoyage, réglages.
@MainActor
final class AppModel: ObservableObject {
    private static let settingsKey = "settings"
    private static let historySize = 120
    private static let appCount = 4
    /// En dessous, une appli inactive ne vaut pas une alerte.
    private static let notifyMinimum: UInt64 = 200 * 1_048_576

    @Published private(set) var snapshot: MemorySnapshot
    @Published private(set) var history: [Double] = []
    @Published private(set) var hogs: [AppUsage] = []
    @Published private(set) var inactive: [AppUsage] = []
    /// Toutes les applis inactives (le panneau n'en montre que quelques-unes), les plus lourdes d'abord.
    private(set) var idleApps: [AppUsage] = []
    @Published private(set) var cleaning: CleanKind?
    @Published private(set) var progress = 0.0
    @Published private(set) var lastResult: CleanResult?
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            let clean = settings.normalized()
            if clean != settings { settings = clean; return }
            UserDefaults.standard.set(try? JSONEncoder().encode(clean), forKey: Self.settingsKey)
            applyTheme()
            if clean.refreshSeconds != oldValue.refreshSeconds { scheduleTimer() }
            onChange?()
        }
    }
    var panelOpen = false
    let updater = UpdateEngine.shared  // mise à jour automatique commune (_tools/shared/Updater.swift)
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var ticks = 0
    private var cancelFlag: CancelFlag?
    private var lastAutoClean: Date?
    private var lastActive: [String: Date] = [:]
    private var notified = Set<String>()
    private var activation: NSObjectProtocol?
    private var bag = Set<AnyCancellable>()
    private(set) lazy var guardian = Guardian(model: self)

    init() {
        snapshot = MemoryProbe.snapshot() ?? MemorySnapshot(
            counters: VMCounters(pageSize: 1, wired: 0, compressor: 0, internalPages: 0, externalPages: 0, purgeable: 0),
            total: 0, swapUsed: 0, pressure: .normal)
        settings = AppSettings.decode(UserDefaults.standard.data(forKey: Self.settingsKey))
    }

    func start() {
        applyTheme()
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let id else { return }
                self.lastActive[id] = Date()
                self.notified.remove(id)
            }
        }
        scheduleTimer()
        tick()
        guardian.start()
        updater.configure(repo: "mCLEAN", lang: { Bundle.main.preferredLocalizations.first ?? "en" })
        updater.autoCheck = { [weak self] in self?.settings.autoUpdate ?? true }
        updater.canInstall = { [weak self] in self?.cleaning == nil }
        updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        updater.start()
    }

    private func applyTheme() {
        switch settings.theme {
        case .dark: Socle.apply(.dark)
        case .light: Socle.apply(.light)
        case .system: Socle.apply(.system)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.refreshSeconds), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.5
    }

    private func tick() {
        guard let now = MemoryProbe.snapshot() else { return }
        snapshot = now
        history.append(now.usedFraction)
        if history.count > Self.historySize { history.removeFirst(history.count - Self.historySize) }
        ticks += 1
        // Le détail par appli coûte plus cher : au rythme du relevé panneau ouvert, sinon toutes les minutes.
        if panelOpen || ticks * settings.refreshSeconds % 60 < settings.refreshSeconds { refreshApps() }
        if shouldAutoClean(settings: settings, snapshot: now, lastRun: lastAutoClean, now: Date(), busy: cleaning != nil) {
            lastAutoClean = Date()
            clean(.standard)
        }
        onChange?()
    }

    /// Applis visibles, avec leur empreinte cumulée, calculée hors du fil principal.
    func refreshApps() {
        Task.detached(priority: .utility) { [weak self] in
            let totals = MemoryProbe.footprintsByResponsiblePID()
            await self?.applyFootprints(totals)
        }
    }

    private func applyFootprints(_ totals: [pid_t: UInt64]) {
        let now = Date()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var apps: [AppUsage] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            let seen = lastActive[id] ?? app.launchDate ?? now
            if lastActive[id] == nil { lastActive[id] = seen }
            apps.append(AppUsage(id: app.processIdentifier, name: app.localizedName ?? id, bundleID: id, icon: app.icon,
                                 bytes: totals[app.processIdentifier] ?? 0, lastActive: seen))
        }
        apps.sort { $0.bytes > $1.bytes }
        hogs = Array(apps.prefix(Self.appCount))
        let idle = apps.filter {
            isInactive(AppActivity(bundleID: $0.bundleID, lastActive: $0.lastActive), hours: settings.inactiveHours,
                       ignored: settings.ignoredBundleIDs, frontmost: frontmost, now: now)
        }
        idleApps = idle
        inactive = settings.showInactive ? Array(idle.prefix(Self.appCount)) : []
        if settings.notifyInactive {
            for app in idle where app.bytes >= Self.notifyMinimum && !notified.contains(app.bundleID) {
                notified.insert(app.bundleID)
                Notifier.shared.inactive(app: app)
            }
        }
    }

    func quit(_ app: AppUsage) {
        NSRunningApplication(processIdentifier: app.id)?.terminate() // demande normale : l'appli peut proposer d'enregistrer
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshApps()
        }
    }

    func runningApps() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    func clean(_ kind: CleanKind) {
        guard cleaning == nil else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        cleaning = kind
        progress = 0
        lastResult = nil
        onChange?()
        Task.detached(priority: .userInitiated) { [weak self] in
            if kind == .deep, !Cleaner.purgeWithAdminPrompt() {
                await self?.finish(nil) // mot de passe refusé : rien n'est lancé
                return
            }
            let result = Cleaner.run(kind: kind, cancel: flag) { value in
                Task { @MainActor [weak self] in self?.progress = value }
            }
            await self?.finish(result)
        }
    }

    func cancelClean() { cancelFlag?.cancel() }

    private func finish(_ result: CleanResult?) {
        cleaning = nil
        cancelFlag = nil
        lastResult = result
        if let result {
            Log.app.info("Nettoyage \(result.kind.rawValue, privacy: .public) : \(result.freed) octets, arrêt \(result.stop.rawValue, privacy: .public)")
            if settings.notifyClean, result.stop != .cancelled { Notifier.shared.cleaned(result) }
        }
        tick()
        refreshApps()
    }
}
