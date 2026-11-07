import AppKit
import Darwin
import MCleanCore

/// Garde-fou : surveille de près la mémoire et le processeur pour éviter que le Mac ne se fige.
/// Il ne fait rien de destructeur sans accord : par défaut il prévient et ralentit (priorité baissée) ; fermer des applis est une option.
@MainActor
final class Guardian {
    private static let fastInterval: TimeInterval = 2
    private static let scanInterval: TimeInterval = 5
    private static let calmScanInterval: TimeInterval = 30
    private static let quitCooldown: TimeInterval = 20
    private static let notifyCooldown: TimeInterval = 300
    /// En dessous, fermer une appli ne change rien à la situation.
    private static let quitMinimum: UInt64 = 300 * 1_048_576

    private unowned let model: AppModel
    private var timer: Timer?
    private var tracker = GuardTracker()
    private var scanning = false
    private var lastScan = Date.distantPast
    private var lastQuit = Date.distantPast
    private var notified: [String: Date] = [:]
    private var throttled = Set<pid_t>()
    private(set) var level = GuardLevel.ok
    private var lastAlert = Date.distantPast
    private var lastBeat = Date()
    /// Durée écoulée depuis la dernière alerte (infinie s'il n'y en a pas eu depuis le lancement).
    var calmFor: TimeInterval { level > .ok ? 0 : (lastAlert == .distantPast ? .infinity : Date().timeIntervalSince(lastAlert)) }

    init(model: AppModel) { self.model = model }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.fastInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 0.5
    }

    private func check() {
        guard model.settings.guardEnabled, let snapshot = MemoryProbe.snapshot() else { level = .ok; return }
        let newLevel = guardLevel(snapshot)
        if newLevel != level { Journal.write("niveau \(level) -> \(newLevel)", Journal.summary(snapshot)) }
        level = newLevel
        if level > .ok { lastAlert = Date() }
        if Date().timeIntervalSince(lastBeat) >= 300 {
            lastBeat = Date()
            Journal.write("point", "\(Journal.summary(snapshot)), gourmands : " + model.hogs.prefix(3).map { "\($0.name) \(MemoryFormat.size($0.bytes))" }.joined(separator: ", "))
        }
        var load = [Double](repeating: 0, count: 1)
        let saturated = getloadavg(&load, 1) == 1 && cpuSaturated(load1: load[0], cores: ProcessInfo.processInfo.activeProcessorCount)
        let stressed = level > .ok || saturated
        let wait = stressed ? Self.scanInterval : Self.calmScanInterval
        guard !scanning, Date().timeIntervalSince(lastScan) >= wait else { return }
        lastScan = Date()
        scanning = true
        if level > .ok { model.refreshApps() }
        Task.detached(priority: .utility) { [weak self] in
            let samples = MemoryProbe.processSamples()
            await self?.process(samples, level: guardLevel(snapshot), saturated: saturated)
        }
    }

    private func process(_ samples: [ProcessSample], level: GuardLevel, saturated: Bool) {
        scanning = false
        let findings = tracker.ingest(samples, now: Date())
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let me = ProcessInfo.processInfo.processIdentifier

        if saturated, model.settings.guardCPU {
            let groups = Dictionary(samples.map { ($0.pid, $0.group) }, uniquingKeysWith: { a, _ in a })
            for pid in findings.cpuHogs where !throttled.contains(pid) && pid != me {
                let group = groups[pid] ?? pid
                guard group != front, group != me else { continue } // jamais l'appli que l'utilisateur utilise
                guard getpriority(PRIO_PROCESS, id_t(pid)) < 10, setpriority(PRIO_PROCESS, id_t(pid), 10) == 0 else { continue }
                throttled.insert(pid)
                let name = displayName(group)
                Journal.write("priorité baissée", "\(name) (pid \(pid))")
                Log.app.info("Garde-fou : priorité baissée pour \(name, privacy: .public) (pid \(pid))")
                notify(key: "cpu.\(group)", title: L("notify.guardCPUTitle", name), body: L("notify.guardCPUBody"))
            }
        }
        throttled.formIntersection(Set(samples.map(\.pid)))

        if level > .ok, let grower = findings.growers.first, grower.group != me, let app = NSRunningApplication(processIdentifier: grower.group) {
            let name = app.localizedName ?? "?"
            notify(key: "grow.\(grower.group)", title: L("notify.guardGrowTitle", name),
                   body: L("notify.guardGrowBody", MemoryFormat.size(grower.grown)), bundleID: app.bundleIdentifier)
        }

        guard level == .emergency else { return }
        let culprit = model.hogs.first
        if let culprit {
            notify(key: "emergency", title: L("notify.guardEmergencyTitle"),
                   body: L("notify.guardEmergencyBody", culprit.name, MemoryFormat.size(culprit.bytes)), bundleID: culprit.bundleID)
        }
        if model.settings.guardAutoQuit, Date().timeIntervalSince(lastQuit) >= Self.quitCooldown,
           let victim = model.idleApps.first(where: { $0.bytes >= Self.quitMinimum }) {
            lastQuit = Date()
            NSRunningApplication(processIdentifier: victim.id)?.terminate() // demande normale : l'appli peut proposer d'enregistrer
            Journal.write("fermeture", "\(victim.name), \(MemoryFormat.size(victim.bytes))")
            Log.app.info("Garde-fou : fermeture de \(victim.name, privacy: .public) (\(victim.bytes) octets)")
            Notifier.shared.guardQuit(app: victim)
            Task {
                try? await Task.sleep(for: .seconds(2))
                model.refreshApps()
            }
        }
    }

    private func displayName(_ pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "pid \(pid)"
    }

    private func notify(key: String, title: String, body: String, bundleID: String? = nil) {
        if let last = notified[key], Date().timeIntervalSince(last) < Self.notifyCooldown { return }
        notified[key] = Date()
        Journal.write("alerte", title + " — " + body)
        Notifier.shared.guardAlert(id: key, title: title, body: body, bundleID: bundleID)
    }
}
