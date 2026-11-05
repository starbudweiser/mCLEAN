import Foundation

/// Niveau d'alerte du garde-fou : `emergency` = le Mac risque de se figer (swap massif, plus de mémoire récupérable).
public enum GuardLevel: Int, Comparable {
    case ok, alert, emergency

    public static func < (a: GuardLevel, b: GuardLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Niveau d'après la pression du système et la mémoire récupérable sans toucher aux applis.
/// Les seuils suivent la taille de la machine, avec un plancher absolu.
public func guardLevel(_ s: MemorySnapshot) -> GuardLevel {
    let gib: UInt64 = 1_073_741_824
    let emergencyBelow = max(gib * 3 / 2, s.total / 33)
    let alertBelow = max(gib * 3, s.total / 16)
    if s.pressure == .critical || s.available < emergencyBelow { return .emergency }
    if s.pressure == .warning || s.available < alertBelow { return .alert }
    return .ok
}

/// Un processus à un instant donné. `group` est le processus responsable (l'appli qui l'a lancé).
public struct ProcessSample: Equatable {
    public var pid: pid_t
    public var group: pid_t
    public var footprint: UInt64
    /// Temps processeur cumulé (utilisateur + système), en nanosecondes.
    public var cpuNanos: UInt64

    public init(pid: pid_t, group: pid_t, footprint: UInt64, cpuNanos: UInt64) {
        self.pid = pid
        self.group = group
        self.footprint = footprint
        self.cpuNanos = cpuNanos
    }
}

public struct GuardFindings: Equatable {
    /// Processus qui occupent au moins `cpuThreshold` cœur depuis `cpuSustain` secondes.
    public var cpuHogs: [pid_t] = []
    /// Applis dont l'empreinte a grimpé d'au moins `growthBytes` dans la fenêtre, avec la hausse.
    public var growers: [(group: pid_t, grown: UInt64)] = []

    public init() {}

    public static func == (a: GuardFindings, b: GuardFindings) -> Bool {
        a.cpuHogs == b.cpuHogs && a.growers.map(\.group) == b.growers.map(\.group) && a.growers.map(\.grown) == b.growers.map(\.grown)
    }
}

/// Suit les relevés successifs pour repérer ce qu'un seul relevé ne montre pas : le processeur tenu dans la durée et la mémoire qui s'emballe.
public struct GuardTracker {
    public var cpuThreshold = 0.5
    public var cpuSustain: TimeInterval = 30
    public var growthBytes: UInt64 = 3 * 1_073_741_824
    public var growthWindow: TimeInterval = 30

    private var lastCPU: [pid_t: (nanos: UInt64, at: Date)] = [:]
    private var hotSince: [pid_t: Date] = [:]
    private var history: [pid_t: [(at: Date, bytes: UInt64)]] = [:]

    public init() {}

    public mutating func ingest(_ samples: [ProcessSample], now: Date) -> GuardFindings {
        var findings = GuardFindings()
        var seen = Set<pid_t>()
        var groups: [pid_t: UInt64] = [:]
        for s in samples {
            seen.insert(s.pid)
            groups[s.group, default: 0] += s.footprint
            if let prev = lastCPU[s.pid], now > prev.at, s.cpuNanos >= prev.nanos {
                let share = Double(s.cpuNanos - prev.nanos) / 1e9 / now.timeIntervalSince(prev.at)
                if share >= cpuThreshold {
                    let since = hotSince[s.pid] ?? prev.at
                    hotSince[s.pid] = since
                    if now.timeIntervalSince(since) >= cpuSustain { findings.cpuHogs.append(s.pid) }
                } else {
                    hotSince[s.pid] = nil
                }
            }
            lastCPU[s.pid] = (s.cpuNanos, now)
        }
        for pid in lastCPU.keys where !seen.contains(pid) { lastCPU[pid] = nil; hotSince[pid] = nil }

        for (group, bytes) in groups {
            var h = (history[group] ?? []).filter { now.timeIntervalSince($0.at) <= growthWindow }
            h.append((now, bytes))
            history[group] = h
            if let low = h.map(\.bytes).min(), bytes >= low + growthBytes { findings.growers.append((group, bytes - low)) }
        }
        for group in history.keys where groups[group] == nil { history[group] = nil }
        findings.cpuHogs.sort()
        findings.growers.sort { $0.grown > $1.grown }
        return findings
    }
}

/// Charge moyenne sur 1 minute rapportée au nombre de cœurs : au-delà de 1,5, le processeur est saturé.
public func cpuSaturated(load1: Double, cores: Int) -> Bool {
    cores > 0 && load1 > 1.5 * Double(cores)
}
