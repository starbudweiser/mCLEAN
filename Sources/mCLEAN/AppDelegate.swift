import AppKit
import MCleanCore
import ServiceManagement
import SwiftUI

enum Brand {
    static let nsColor = NSColor(srgbRed: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255, alpha: 1)
    static let color = Color(nsColor)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Socle.brand("mCLEAN", color: Brand.color)
        Notifier.shared.configure(model: model)
        status = StatusController(model: model)
        model.start()
    }
}

/// Icône de barre de menus, panneau et menu contextuel.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var spinner: Timer?
    private var angle: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        super.init()
        // Roue du panneau : préférences directement ; clic droit sur l'icône : menu complet.
        let hosting = NSHostingController(rootView: PanelView(onMenu: { [weak self] _ in self?.openSettings() }).environmentObject(model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.panelOpen = false }
        }
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    #if MCLEAN_SELFTEST
    /// Essai : ouvre le panneau (rendu invisible) et renvoie les cadres de l'icône et du panneau.
    func probe() -> (button: NSRect?, screen: NSRect?, popover: NSRect?) {
        guard let button = item.button, let window = button.window else { return (nil, nil, nil) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.alphaValue = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let frame = popover.contentViewController?.view.window?.frame
        popover.performClose(nil)
        return (window.frame, window.screen?.frame, frame)
    }
    #endif

    @objc private func clicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            model.panelOpen = true
            model.refreshApps()
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey() // sinon le premier clic dans le panneau ne fait que l'activer
        }
    }

    private func showMenu(from view: NSView) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        add(L("menu.settings"), #selector(openSettings))
        add(L("menu.checkUpdates"), #selector(checkUpdates))
        menu.addItem(.separator())
        add(L("about.menu"), #selector(openAbout))
        add(L("menu.quit"), #selector(quit))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 6), in: view)
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        DispatchQueue.main.async { [model] in SettingsWindow.show(model: model) } // après la fermeture du panneau
    }

    @objc private func checkUpdates() {
        popover.performClose(nil)
        model.updater.check()
        DispatchQueue.main.async { [model] in SettingsWindow.show(model: model, tab: .updates) }
    }

    @objc private func openAbout() {
        popover.performClose(nil)
        DispatchQueue.main.async { About.show() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func render() {
        guard let button = item.button else { return }
        let s = model.settings
        let snapshot = model.snapshot
        let text = s.showPercent ? MemoryFormat.percent(snapshot.usedFraction) : MemoryFormat.size(snapshot.available)
        button.title = s.statusDisplay == .iconOnly ? "" : text
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.imagePosition = s.statusDisplay == .textOnly ? .noImage : .imageLeading
        button.image = StatusIcon.image(fraction: snapshot.usedFraction, pressure: snapshot.pressure, spinning: model.cleaning != nil, angle: angle)

        if model.cleaning != nil, spinner == nil {
            spinner = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.angle -= 24
                    self.render()
                }
            }
        } else if model.cleaning == nil {
            spinner?.invalidate()
            spinner = nil
        }
    }
}

/// Anneau de 18 pt : part de mémoire utilisée, ou arc tournant pendant un nettoyage.
enum StatusIcon {
    static func image(fraction: Double, pressure: PressureLevel, spinning: Bool, angle: CGFloat) -> NSImage {
        let color: NSColor? = switch pressure {
        case .normal: nil
        case .warning: .systemOrange
        case .critical: .systemRed
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.5
            let main = color ?? .black
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.5
            main.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            let start = spinning ? angle : 90
            let end = start - (spinning ? 110 : 360 * CGFloat(fraction))
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            main.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

/// Ouverture à la connexion.
@MainActor
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            Log.app.error("Ouverture à la connexion : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
