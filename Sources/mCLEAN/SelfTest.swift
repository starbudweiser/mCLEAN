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
        case "update": update()
        case "login": login()
        case "popover": popover()
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

    /// Position du panneau par rapport à l'icône de la barre de menus.
    private static func popover() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Socle.apply(.dark)
        let model = AppModel()
        let status = StatusController(model: model)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let r = status.probe()
        for screen in NSScreen.screens { print("écran :", screen.frame) }
        print("icône :", r.button.map { "\($0)" } ?? "?", "sur écran", r.screen.map { "\($0)" } ?? "?")
        print("panneau :", r.popover.map { "\($0)" } ?? "?")
        if let b = r.button, let p = r.popover { print("centre icône x =", b.midX, " centre panneau x =", p.midX, " écart =", p.midX - b.midX) }
    }

    /// Active puis désactive l'ouverture à la connexion (sans laisser de trace).
    private static func login() {
        print("avant :", LoginItem.enabled)
        print("activation :", LoginItem.set(true), "->", LoginItem.enabled)
        print("désactivation :", LoginItem.set(false), "->", LoginItem.enabled)
    }

    /// Recherche, téléchargement et contrôle de la dernière release, sans rien installer.
    private static func update() {
        _ = NSApplication.shared
        let model = AppModel()
        model.updater.check()
        func wait(_ done: () -> Bool) { let end = Date().addingTimeInterval(60); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) } }
        wait { !model.updater.isBusy }
        print("état :", model.updater.state, "version locale :", model.updater.currentVersion)
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
        let about = About.makeWindow()
        about.appearance = NSAppearance(named: .darkAqua)
        about.contentView?.appearance = NSAppearance(named: .darkAqua)
        about.contentView?.wantsLayer = true
        about.contentView?.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        save(about.contentView.map { AnyView(NSViewBox($0)) } ?? AnyView(EmptyView()), size: about.contentView?.frame.size, to: dir.appendingPathComponent("about.png"))
        print("OK", dir.path)
    }
}

private struct NSViewBox: NSViewRepresentable {
    let view: NSView
    init(_ view: NSView) { self.view = view }
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
