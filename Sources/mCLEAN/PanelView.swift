import AppKit
import MCleanCore
import SwiftUI

/// Couleurs des parts de la mémoire, communes à l'anneau et à la légende.
private enum Part {
    static let app = Socle.C.accent
    static let wired = Socle.C.action
    static let compressed = Socle.C.bubbleAi
    static let cached = Socle.C.textSubtle
    static let free = Brand.color
}

/// Panneau de la barre de menus.
struct PanelView: View {
    @EnvironmentObject private var model: AppModel
    let onMenu: (NSView) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            updateBanner
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                gauge
                breakdown
                if model.history.count > 1 { Sparkline(values: model.history).frame(height: 28) }
                if !model.hogs.isEmpty { list(L("section.hogs"), apps: model.hogs, inactive: false) }
                if !model.inactive.isEmpty { list(L("section.inactive"), apps: model.inactive, inactive: true) }
            }
            .padding(Socle.M.space4)
            footer
        }
        .frame(width: 320)
        .background(Socle.C.bg)
    }

    private var header: some View {
        HStack {
            Text(branded: "mCLEAN").socle(Socle.T.title)
            Spacer()
            MenuAnchor(onMenu: onMenu).frame(width: 24, height: 24)
        }
        .padding(.horizontal, Socle.M.space4)
        .frame(minHeight: Socle.M.sizeBar)
        .background(Socle.C.surfaceRaised)
    }

    @ViewBuilder private var updateBanner: some View {
        if case .available(let plan) = model.updater.state {
            HStack {
                Text(L("updates.available", plan.target.version)).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
                Spacer()
                Button(L("updates.install")) { model.updater.present(plan) }.buttonStyle(SocleButtonStyle(.primary, height: 26))
            }
            .padding(.horizontal, Socle.M.space4).padding(.vertical, Socle.M.space2)
            .background(Socle.C.surfaceSelected)
        }
    }

    private var gauge: some View {
        let s = model.snapshot
        let busy = model.cleaning != nil
        return ZStack {
            Circle().stroke(Socle.C.control, lineWidth: 10)
            Circle()
                .trim(from: 0, to: busy ? model.progress : s.availableFraction)
                .stroke(busy ? Socle.C.accent : pressureColor(s.pressure), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: busy ? model.progress : s.availableFraction)
            VStack(spacing: 2) {
                if busy {
                    Text(MemoryFormat.percent(model.progress)).socle(Socle.T.display)
                    Text(L("clean.running")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                } else {
                    Text(MemoryFormat.size(s.available)).socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
                    Text(L("panel.available")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                }
            }
        }
        .frame(width: 136, height: 136)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Socle.M.space1)
    }

    private func pressureColor(_ level: PressureLevel) -> Color {
        switch level {
        case .normal: Brand.color
        case .warning: Socle.C.warning
        case .critical: Socle.C.danger
        }
    }

    private var breakdown: some View {
        let s = model.snapshot
        return VStack(spacing: Socle.M.space1) {
            legend(Part.app, L("legend.app"), s.app)
            legend(Part.wired, L("legend.wired"), s.wired)
            legend(Part.compressed, L("legend.compressed"), s.compressed)
            legend(Part.cached, L("legend.cached"), s.cached)
            legend(Part.free, L("legend.free"), s.free)
            HStack {
                Text(pressureText(s.pressure)).socle(Socle.T.meta).foregroundStyle(pressureColor(s.pressure))
                Spacer()
                Text(L("panel.swap", MemoryFormat.size(s.swapUsed))).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
            }
            .padding(.top, Socle.M.space1)
        }
    }

    private func pressureText(_ level: PressureLevel) -> String {
        switch level {
        case .normal: L("pressure.normal")
        case .warning: L("pressure.warning")
        case .critical: L("pressure.critical")
        }
    }

    private func legend(_ color: Color, _ title: String, _ bytes: UInt64) -> some View {
        HStack(spacing: Socle.M.space2) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text)
            Spacer()
            Text(MemoryFormat.size(bytes)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
        }
    }

    private func list(_ title: String, apps: [AppUsage], inactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space1) {
            Text(title).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textMuted)
            ForEach(apps) { app in
                HStack(spacing: Socle.M.space2) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(app.name).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(MemoryFormat.size(app.bytes)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                    if inactive {
                        Button(L("action.quit")) { model.quit(app) }
                            .buttonStyle(SocleButtonStyle(.tertiary, height: 24))
                            .help(L("inactive.since", since(app.lastActive)))
                    }
                }
            }
        }
    }

    private func since(_ date: Date) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: Date().timeIntervalSince(date)) ?? ""
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: Socle.M.space2) {
            if let result = model.lastResult, model.cleaning == nil {
                Text(resultText(result)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            HStack(spacing: Socle.M.space2) {
                if model.cleaning != nil {
                    Button(L("action.cancel")) { model.cancelClean() }.buttonStyle(SocleButtonStyle(.secondary))
                } else {
                    Button(L("action.clean")) { model.clean(.standard) }.buttonStyle(SocleButtonStyle(.primary))
                    if model.settings.showDeepClean {
                        Button(L("action.deep")) { model.clean(.deep) }
                            .buttonStyle(SocleButtonStyle(.action))
                            .help(L("action.deepHelp"))
                    }
                }
            }
        }
        .padding(Socle.M.space4)
        .background(Socle.C.surfaceRaised)
    }

    private func resultText(_ result: CleanResult) -> String {
        let freed = MemoryFormat.size(result.freed)
        switch result.stop {
        case .cancelled: return L("result.cancelled", freed)
        case .pressure, .swap, .compression, .reserve: return L("result.limit", freed)
        case .done, .timeLimit: return L("result.done", freed)
        }
    }
}

/// Bouton de menu : garde sa vue AppKit pour y ancrer le menu contextuel.
/// Bouton qui agit dès le premier clic, même si le panneau n'est pas encore la fenêtre active.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MenuAnchor: NSViewRepresentable {
    let onMenu: (NSView) -> Void

    final class Coordinator: NSObject {
        var onMenu: (NSView) -> Void
        init(onMenu: @escaping (NSView) -> Void) { self.onMenu = onMenu }
        @objc func clicked(_ sender: NSButton) { onMenu(sender) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onMenu: onMenu) }

    func makeNSView(context: Context) -> NSButton {
        let button = FirstClickButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("menu.settings")) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.clicked))
        button.isBordered = false
        button.contentTintColor = NSColor(Socle.C.action) // jaune Socle
        button.toolTip = L("menu.settings")
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.onMenu = onMenu }
}

/// Historique de la mémoire utilisée.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step = size.width / CGFloat(max(values.count - 1, 1))
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - v))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(Socle.C.accent), lineWidth: 1.5)
        }
        .background(Socle.C.bgSunken)
    }
}
