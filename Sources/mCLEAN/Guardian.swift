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
    /// Calculs lourds mis en pause (SIGSTOP) pour garder la marge de mémoire, avec leur veilleur de reprise.
    private var paused: [pid_t: (name: String, since: Date, watcher: Process?)] = [:]
    private var lastResume = Date.distantPast
    private static let pausedFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mCLEAN/paused.txt")
    private(set) var level = GuardLevel.ok
    private var lastAlert = Date.distantPast
    private var lastBeat = Date()
    /// Durée écoulée depuis la dernière alerte (infinie s'il n'y en a pas eu depuis le lancement).
    var calmFor: TimeInterval { level > .ok ? 0 : (lastAlert == .distantPast ? .infinity : Date().timeIntervalSince(lastAlert)) }

    init(model: AppModel) { self.model = model }

    func start() {
        Self.resumeLeftovers()
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
        let underReserve = snapshot.available < aiReserve(total: snapshot.total)
        if model.settings.guardAI { resumeIfPossible(snapshot) } else if !paused.isEmpty { resumeAll("garde-fou IA désactivé") }
        let stressed = level > .ok || saturated || underReserve
        let wait = underReserve || !paused.isEmpty ? Self.fastInterval : (stressed ? Self.scanInterval : Self.calmScanInterval)
        guard !scanning, Date().timeIntervalSince(lastScan) >= wait else { return }
        lastScan = Date()
        scanning = true
        if level > .ok { model.refreshApps() }
        Task.detached(priority: .utility) { [weak self] in
            let samples = MemoryProbe.processSamples()
            await self?.process(samples, level: guardLevel(snapshot), saturated: saturated, snapshot: snapshot)
        }
    }

    private func process(_ samples: [ProcessSample], level: GuardLevel, saturated: Bool, snapshot: MemorySnapshot) {
        scanning = false
        if model.settings.guardAI { pauseHeavyCompute(samples, snapshot: snapshot) }
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

    // MARK: - Calculs lourds (IA, rendus)

    /// Sous la marge de sécurité, met en pause (SIGSTOP) le calcul lourd le plus gourmand : il cesse d'avaler de la mémoire
    /// et du processeur, le Mac reste réactif. La reprise est automatique (voir `resumeIfPossible`) et garantie même si mCLEAN plante.
    private func pauseHeavyCompute(_ samples: [ProcessSample], snapshot: MemorySnapshot) {
        guard aiAction(snapshot, paused: false, pausedFor: 0) == .pause,
              Date().timeIntervalSince(lastResume) >= 15 else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = samples
            .filter { $0.pid != me && $0.pid > 1 && $0.group != front && $0.group != me && paused[$0.pid] == nil }
            .compactMap { s -> (ProcessSample, String)? in
                let path = MemoryProbe.path(of: s.pid)
                let gui = NSRunningApplication(processIdentifier: s.pid)?.activationPolicy == .regular
                return isHeavyCompute(path: path, footprint: s.footprint, isGUIApp: gui) ? (s, path) : nil
            }
            .sorted { $0.0.footprint > $1.0.footprint }
        guard let (victim, path) = candidates.first, kill(victim.pid, SIGSTOP) == 0 else { return }
        let name = (path as NSString).lastPathComponent.isEmpty ? "pid \(victim.pid)" : (path as NSString).lastPathComponent
        paused[victim.pid] = (name, Date(), startWatcher(for: victim.pid))
        savePaused()
        Journal.write("calcul mis en pause", "\(name) (pid \(victim.pid), \(MemoryFormat.size(victim.footprint))), \(Journal.summary(snapshot))")
        notify(key: "pause", title: L("notify.guardPauseTitle", name),
               body: L("notify.guardPauseBody", MemoryFormat.size(victim.footprint)))
    }

    /// Reprend les calculs en pause un par un, dès que la mémoire est revenue assez haut ou après la pause maximale.
    private func resumeIfPossible(_ snapshot: MemorySnapshot) {
        for pid in paused.keys where kill(pid, 0) != 0 { paused[pid]?.watcher?.terminate(); paused[pid] = nil; savePaused() }
        guard let oldest = paused.min(by: { $0.value.since < $1.value.since }),
              Date().timeIntervalSince(lastResume) >= 5,
              aiAction(snapshot, paused: true, pausedFor: Date().timeIntervalSince(oldest.value.since)) == .resume else { return }
        resume(oldest.key, reason: "mémoire revenue à \(MemoryFormat.size(snapshot.available))")
    }

    private func resume(_ pid: pid_t, reason: String) {
        guard let entry = paused[pid] else { return }
        kill(pid, SIGCONT)
        entry.watcher?.terminate()
        paused[pid] = nil
        lastResume = Date()
        savePaused()
        Journal.write("calcul repris", "\(entry.name) (pid \(pid)), \(reason)")
    }

    /// Reprend tout, sans délai (arrêt de mCLEAN, garde-fou désactivé).
    func resumeAll(_ reason: String) {
        for pid in Array(paused.keys) { resume(pid, reason: reason) }
    }

    /// Veilleur indépendant : si mCLEAN disparaît (plantage, kill), il relance le calcul au lieu de le laisser gelé.
    private func startWatcher(for pid: pid_t) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 2; done; kill -CONT \(pid) 2>/dev/null"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return (try? p.run()) != nil ? p : nil
    }

    private func savePaused() {
        let text = paused.keys.map(String.init).joined(separator: "\n")
        try? FileManager.default.createDirectory(at: Self.pausedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: Self.pausedFile, atomically: true, encoding: .utf8)
    }

    /// Au lancement : un calcul laissé en pause par une exécution précédente est relancé.
    private static func resumeLeftovers() {
        guard let text = try? String(contentsOf: pausedFile, encoding: .utf8) else { return }
        for pid in text.split(separator: "\n").compactMap({ pid_t($0) }) where pid > 1 { kill(pid, SIGCONT) }
        try? FileManager.default.removeItem(at: pausedFile)
    }
}
