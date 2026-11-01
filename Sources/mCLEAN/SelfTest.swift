#if MCLEAN_SELFTEST
import AppKit
import MCleanCore
import SwiftUI

/// Essais sans interface visible : `mCLEAN --selftest status|clean|deep|render <dossier>`. Absent des builds normaux.
@MainActor
enum SelfTest {
    static func runIfRequested(_ args: [String]) -> Bool {
        guard args.count >= 3 || args.contains("--selftest"), let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return false }
        switch args[i + 1] {
        case "status": status()
        case "clean": clean(.standard)
        case "deep": clean(.deep)
        case "render": render(to: URL(fileURLWithPath: args[i + 2]))
        default: print("commande inconnue")
        }
        return true
    }

    private static func describe(_ s: MemorySnapshot) -> String {
        let parts = [("total", s.total), ("app", s.app), ("wired", s.wired), ("compressed", s.compressed), ("cached", s.cached), ("free", s.free), ("available", s.available), ("swap", s.swapUsed)]
        return parts.map { "\($0.0)=\(MemoryFormat.size($0.1))" }.joined(separator: " ") + " pressure=\(s.pressure)"
    }

    private static func status() {
        guard let s = MemoryProbe.snapshot() else { print("relevé impossible"); return }
        print(describe(s))
        print("somme parts = total :", s.app + s.wired + s.compressed + s.cached + s.free == s.total)
        for (pid, bytes) in MemoryProbe.footprintsByResponsiblePID().sorted(by: { $0.value > $1.value }).prefix(6) {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            print(" ", name, MemoryFormat.size(bytes))
        }
    }

    /// Passe sans `purge` : le mot de passe reste l'affaire de l'utilisateur.
    private static func clean(_ kind: CleanKind) {
        guard let r = Cleaner.run(kind: kind, cancel: CancelFlag(), progress: { _ in }) else { print("échec"); return }
        print("avant :", describe(r.before))
        print("après :", describe(r.after))
        print("gain :", MemoryFormat.size(r.freed), "arrêt :", r.stop.rawValue, "durée :", String(format: "%.1f s", r.duration))
    }

    private static func save<V: View>(_ view: V, size: NSSize?, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if size == nil { host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func render(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited) // jamais de fenêtre ni d'icône pendant l'essai
        Socle.apply(.dark)
        Socle.brand("mCLEAN", color: Brand.color)
        let model = AppModel()
        model.start()
        model.refreshApps()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        save(PanelView(onMenu: { _ in }).environmentObject(model), size: nil, to: dir.appendingPathComponent("panel.png"))
        for tab in SettingsTab.allCases {
            save(SettingsView(tab: tab).environmentObject(model), size: NSSize(width: 440, height: 400), to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        print("OK", dir.path)
    }
}
#endif
