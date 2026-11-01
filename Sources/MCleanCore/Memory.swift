import Foundation

/// Compteurs bruts de `host_statistics64`, en pages.
public struct VMCounters: Equatable {
    public var pageSize: UInt64
    public var wired: UInt64
    public var compressor: UInt64
    public var internalPages: UInt64
    public var externalPages: UInt64
    public var purgeable: UInt64

    public init(pageSize: UInt64, wired: UInt64, compressor: UInt64, internalPages: UInt64, externalPages: UInt64, purgeable: UInt64) {
        self.pageSize = pageSize
        self.wired = wired
        self.compressor = compressor
        self.internalPages = internalPages
        self.externalPages = externalPages
        self.purgeable = purgeable
    }
}

/// Niveau de pression mémoire du système (`kern.memorystatus_vm_pressure_level`).
public enum PressureLevel: Int {
    case normal = 1, warning = 2, critical = 4
}

/// État de la mémoire, en octets, avec les mêmes définitions que le Moniteur d'activité.
/// Les cinq parts (applis, résidente, compressée, cache, libre) totalisent `total`.
public struct MemorySnapshot: Equatable {
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var pressure: PressureLevel

    public init(counters c: VMCounters, total: UInt64, swapUsed: UInt64, pressure: PressureLevel) {
        self.total = total
        self.swapUsed = swapUsed
        self.pressure = pressure
        app = c.internalPages.subtractingClamped(c.purgeable) * c.pageSize
        wired = c.wired * c.pageSize
        compressed = c.compressor * c.pageSize
        let available = total.subtractingClamped(app + wired + compressed)
        cached = min((c.externalPages + c.purgeable) * c.pageSize, available)
        free = available - cached
    }

    public var used: UInt64 { app + wired + compressed }
    /// Mémoire utilisable sans toucher aux applis : le cache se récupère à la demande.
    public var available: UInt64 { total.subtractingClamped(used) }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
    public var availableFraction: Double { 1 - usedFraction }
}

extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}

public enum MemoryFormat {
    private static func number(_ value: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Taille lisible : en Go au-delà de 1 Go, sinon en Mo.
    public static func size(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return L("unit.gb", number(gb, digits: gb >= 100 ? 0 : (gb >= 10 ? 1 : 2))) }
        return L("unit.mb", number(Double(bytes) / 1_048_576, digits: 0))
    }

    public static func percent(_ fraction: Double) -> String {
        L("unit.percent", Int((fraction * 100).rounded()))
    }
}
