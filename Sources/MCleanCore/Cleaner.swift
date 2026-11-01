import Darwin
import Foundation

public enum CleanKind: String, Codable {
    case standard, deep
}

/// Raison de la fin d'une passe de nettoyage.
public enum CleanStop: String {
    case done, cancelled, pressure, swap, compression, reserve, timeLimit
}

/// Limites d'une passe : on sollicite la mémoire par paliers et on s'arrête dès que le système commence à en souffrir.
public struct CleanLimits: Equatable {
    public var stepBytes: UInt64
    public var maxCompressedGrowth: UInt64
    public var maxSwapGrowth: UInt64
    public var reserve: UInt64
    public var maxDuration: TimeInterval
    /// Part de la mémoire des applis visée en plus du cache.
    public var appFraction: Double

    private static let gb: UInt64 = 1_073_741_824

    public static let standard = CleanLimits(stepBytes: gb / 2, maxCompressedGrowth: gb / 4, maxSwapGrowth: gb / 32,
                                             reserve: 2 * gb, maxDuration: 20, appFraction: 0)
    public static let deep = CleanLimits(stepBytes: gb / 2, maxCompressedGrowth: 4 * gb, maxSwapGrowth: gb / 4,
                                         reserve: 2 * gb, maxDuration: 40, appFraction: 0.25)

    public static func limits(for kind: CleanKind) -> CleanLimits { kind == .deep ? deep : standard }

    public func target(from start: MemorySnapshot) -> UInt64 {
        start.cached + UInt64(Double(start.app) * appFraction)
    }

    /// Prochain palier à allouer, ou raison de s'arrêter.
    public func next(start: MemorySnapshot, now: MemorySnapshot, allocated: UInt64, elapsed: TimeInterval) -> CleanDecision {
        if now.pressure != .normal { return .stop(.pressure) }
        if elapsed >= maxDuration { return .stop(.timeLimit) }
        if now.swapUsed.subtractingClamped(start.swapUsed) > maxSwapGrowth { return .stop(.swap) }
        if now.compressed.subtractingClamped(start.compressed) > maxCompressedGrowth { return .stop(.compression) }
        let remaining = target(from: start).subtractingClamped(allocated)
        if remaining == 0 { return .stop(.done) }
        let room = now.available.subtractingClamped(reserve)
        if room == 0 { return .stop(.reserve) }
        return .allocate(min(stepBytes, remaining, room))
    }
}

public enum CleanDecision: Equatable {
    case allocate(UInt64)
    case stop(CleanStop)
}

public struct CleanResult: Equatable {
    public var kind: CleanKind
    public var before: MemorySnapshot
    public var after: MemorySnapshot
    public var stop: CleanStop
    public var duration: TimeInterval

    public init(kind: CleanKind, before: MemorySnapshot, after: MemorySnapshot, stop: CleanStop, duration: TimeInterval) {
        self.kind = kind
        self.before = before
        self.after = after
        self.stop = stop
        self.duration = duration
    }

    /// Gain en mémoire réellement libre (cache et applis poussés hors de la RAM).
    public var freed: UInt64 { after.free.subtractingClamped(before.free) }
}

/// Demande d'annulation partagée entre l'interface et la passe en cours.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { value } }
    public func cancel() { lock.withLock { value = true } }
}

public enum Cleaner {
    /// Alloue puis libère de la mémoire pour pousser le cache de fichiers hors de la RAM. Bloquant : à lancer hors du fil principal.
    public static func run(kind: CleanKind, cancel: CancelFlag, progress: @Sendable (Double) -> Void) -> CleanResult? {
        guard let start = MemoryProbe.snapshot() else { return nil }
        let limits = CleanLimits.limits(for: kind)
        let target = limits.target(from: start)
        let began = Date()
        var regions: [(UnsafeMutableRawPointer, Int)] = []
        var allocated: UInt64 = 0
        var stop = CleanStop.done

        loop: while true {
            if cancel.isCancelled { stop = .cancelled; break }
            guard let now = MemoryProbe.snapshot() else { break }
            switch limits.next(start: start, now: now, allocated: allocated, elapsed: Date().timeIntervalSince(began)) {
            case .stop(let reason):
                stop = reason
                break loop
            case .allocate(let bytes):
                let size = Int(bytes)
                let pointer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
                guard let pointer, pointer != MAP_FAILED else { stop = .reserve; break loop }
                memset(pointer, 0xA5, size) // des pages écrites, sinon elles n'occupent pas la RAM
                regions.append((pointer, size))
                allocated += bytes
                progress(target == 0 ? 1 : min(1, Double(allocated) / Double(target)))
            }
        }
        for (pointer, size) in regions { munmap(pointer, size) }
        regions.removeAll()
        Thread.sleep(forTimeInterval: 0.5) // le système comptabilise les pages rendues
        guard let after = MemoryProbe.snapshot() else { return nil }
        return CleanResult(kind: kind, before: start, after: after, stop: stop, duration: Date().timeIntervalSince(began))
    }

    /// `purge` (cache disque) avec la demande de mot de passe du système. Faux si l'utilisateur annule ou si la commande échoue.
    public static func purgeWithAdminPrompt() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
