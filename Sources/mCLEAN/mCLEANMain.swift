import AppKit

@main
enum MCleanMain {
    @MainActor
    static func main() {
        #if MCLEAN_SELFTEST
        if SelfTest.runIfRequested(CommandLine.arguments) { return }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // app de barre de menus, sans icône dans le Dock
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
