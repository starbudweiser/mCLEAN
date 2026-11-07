import Foundation
import MCleanCore

/// Journal persistant des décisions de mCLEAN (`~/Library/Logs/mCLEAN/journal.log`) : les journaux système ne gardent pas
/// ces messages, or après un gel il faut savoir ce que l'appli a fait. Une ligne par événement, tourne à 1 Mo.
enum Journal {
    private static let queue = DispatchQueue(label: "mclean.journal", qos: .utility)
    private static let limit = 1_000_000
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/mCLEAN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("journal.log")
    }()

    static func write(_ event: String, _ detail: String = "") {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(event)\(detail.isEmpty ? "" : " | " + detail)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
                let old = url.deletingLastPathComponent().appendingPathComponent("journal.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url), let data = line.data(using: .utf8) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Résumé d'un relevé pour une ligne de journal.
    static func summary(_ s: MemorySnapshot) -> String {
        "dispo \(MemoryFormat.size(s.available)), pression \(s.pressure), swap \(MemoryFormat.size(s.swapUsed))"
    }
}
