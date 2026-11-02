import AppKit
import MCleanCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, auto, apps, updates
    var title: String {
        switch self {
        case .general: L("settings.general")
        case .auto: L("settings.auto")
        case .apps: L("settings.apps")
        case .updates: L("settings.updates")
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static var requestedTab: SettingsTab?

    static func show(model: AppModel, tab: SettingsTab? = nil) {
        requestedTab = tab
        window?.close()
        window = nil
        do {
            let hosting = NSHostingController(rootView: SettingsView(tab: tab ?? .general).environmentObject(model))
            hosting.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable]
            w.title = L("menu.settings")
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.present()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State var tab = SettingsTab.general
    @State private var launchAtLogin = LoginItem.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            SocleSegmented(options: SettingsTab.allCases, selection: tab, label: { $0.title }, onSelect: { tab = $0 })
            switch tab {
            case .general: general
            case .auto: auto
            case .apps: apps
            case .updates: updates
            }
            Spacer(minLength: 0)
        }
        .padding(Socle.M.space5)
        .frame(width: 440, height: 400, alignment: .topLeading)
        .background(Socle.C.bg)
        .toggleStyle(.switch)
        .tint(Socle.C.accentFill)
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
    }

    private func slider(_ title: String, value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space1) {
            HStack {
                Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text)
                Spacer()
                Text(value).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
            }
            Slider(value: binding, in: range, step: step).controlSize(.small)
        }
    }

    private func intBinding(_ path: WritableKeyPath<AppSettings, Int>) -> Binding<Double> {
        Binding { Double(model.settings[keyPath: path]) } set: { model.settings[keyPath: path] = Int($0) }
    }

    private func labelled<V: Hashable>(_ title: String, options: [V], selection: V, label: @escaping (V) -> String, onSelect: @escaping (V) -> Void) -> some View {
        HStack {
            Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text)
            Spacer()
            SocleSegmented(options: options, selection: selection, label: label, onSelect: onSelect)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            toggle(L("settings.login"), Binding { launchAtLogin } set: { on in
                if LoginItem.set(on) { launchAtLogin = on }
            })
            labelled(L("settings.status"), options: StatusDisplay.allCases, selection: model.settings.statusDisplay,
                     label: statusLabel) { model.settings.statusDisplay = $0 }
            toggle(L("settings.percent"), $model.settings.showPercent)
            toggle(L("settings.deep"), $model.settings.showDeepClean)
            labelled(L("settings.theme"), options: ThemeChoice.allCases, selection: model.settings.theme,
                     label: themeLabel) { model.settings.theme = $0 }
            slider(L("settings.refresh"), value: L("unit.seconds", model.settings.refreshSeconds),
                   intBinding(\.refreshSeconds), 1...30, step: 1)
        }
    }

    private func statusLabel(_ value: StatusDisplay) -> String {
        switch value {
        case .iconAndText: L("status.both")
        case .textOnly: L("status.text")
        case .iconOnly: L("status.icon")
        }
    }

    private func themeLabel(_ value: ThemeChoice) -> String {
        switch value {
        case .dark: L("theme.dark")
        case .light: L("theme.light")
        case .system: L("theme.system")
        }
    }

    private var auto: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            toggle(L("settings.autoClean"), $model.settings.autoClean)
            Text(L("settings.autoHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            slider(L("settings.threshold"), value: MemoryFormat.size(UInt64(model.settings.thresholdGB * 1_073_741_824)),
                   $model.settings.thresholdGB, 1...max(2, (Double(model.snapshot.total) / 1_073_741_824 / 2).rounded()), step: 1)
            slider(L("settings.cooldown"), value: L("unit.minutes", model.settings.cooldownMinutes),
                   intBinding(\.cooldownMinutes), 5...120, step: 5)
            toggle(L("settings.notifyClean"), $model.settings.notifyClean)
        }
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            toggle(L("updates.auto"), $model.settings.autoUpdate)
            Text(L("updates.autoHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            Text(L("updates.current", model.updater.currentVersion)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
            Text(updateStatus).socle(Socle.T.body).foregroundStyle(updateIsError ? Socle.C.danger : Socle.C.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Socle.M.space2) {
                Button(L("updates.check")) { model.updater.checkNow() }
                    .buttonStyle(SocleButtonStyle(.secondary)).disabled(model.updater.isBusy)
                if case .available(let plan) = model.updater.state {
                    Button(L("updates.install")) { model.updater.present(plan) }.buttonStyle(SocleButtonStyle(.primary))
                }
            }
        }
    }

    private var updateIsError: Bool { if case .failed = model.updater.state { true } else { false } }

    private var updateStatus: String {
        switch model.updater.state {
        case .idle: L("updates.idle")
        case .checking: L("updates.checking")
        case .upToDate: L("updates.upToDate")
        case .available(let plan): L("updates.available", plan.target.version)
        case .downloading: L("updates.downloading", model.updater.plan?.target.version ?? "")
        case .verifying: model.updater.message(for: "verifying")
        case .installing: L("updates.installing")
        case .failed(let key): model.updater.message(for: key)
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            toggle(L("settings.showInactive"), $model.settings.showInactive)
            toggle(L("settings.notifyInactive"), $model.settings.notifyInactive)
            slider(L("settings.inactiveAfter"), value: L("unit.hours", model.settings.inactiveHours),
                   intBinding(\.inactiveHours), 1...24, step: 1)
            HStack {
                Text(L("settings.ignored")).socle(Socle.T.body).foregroundStyle(Socle.C.text)
                Spacer()
                Menu(L("settings.addIgnored")) {
                    ForEach(model.runningApps().filter { !model.settings.ignoredBundleIDs.contains($0.id) }, id: \.id) { app in
                        Button(app.name) { model.settings.ignoredBundleIDs.append(app.id) }
                    }
                }
                .fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Socle.M.space1) {
                    ForEach(model.settings.ignoredBundleIDs, id: \.self) { id in
                        HStack {
                            Text(id).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                            Spacer()
                            Button(L("action.remove")) { model.settings.ignoredBundleIDs.removeAll { $0 == id } }
                                .buttonStyle(SocleButtonStyle(.tertiary, height: 24))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Socle.M.space2)
            }
            .frame(maxHeight: .infinity)
            .background(Socle.C.bgSunken)
        }
    }
}
