import AppKit
import MCleanCore

/// Mise à jour par les releases GitHub : recherche, téléchargement, contrôle de signature, remplacement et relance.
@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case downloading(String)
        case installing
        case failed(String) // clé de texte
    }

    static let repo = "starbudweiser/mCLEAN"
    private static let checkedKey = "update.checked"
    private static let day: TimeInterval = 24 * 3600

    @Published private(set) var state = State.idle
    private weak var model: AppModel?
    private var timer: Timer?
    private var token: String??

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    init(model: AppModel) { self.model = model }

    /// Au lancement puis toutes les heures : une vraie requête au plus une fois par jour.
    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 60
        checkIfDue()
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: Self.checkedKey)
        if last == 0 || Date().timeIntervalSince1970 - last >= Self.day { check() }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    func check() {
        guard !isBusy else { return }
        state = .checking
        Task {
            let fetched = await fetchLatest()
            if case .failed = fetched {
                state = .failed("updates.errNetwork")
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
            guard case .release(let release) = fetched, isUpdate(latest: release.version, over: currentVersion) else {
                state = .upToDate
                return
            }
            state = .available(release)
            if model?.settings.autoUpdate == true { install(release) }
        }
    }

    func install(_ release: ReleaseInfo) {
        guard !isBusy || { if case .available = state { return true } else { return false } }() else { return }
        guard model?.cleaning == nil else { state = .failed("updates.errBusy"); return }
        state = .downloading(release.version)
        Task {
            guard let zip = await download(release) else { state = .failed("updates.errNetwork"); return }
            let staged = await Task.detached { Self.stage(zip: zip, expected: release.version) }.value
            try? FileManager.default.removeItem(at: zip)
            guard let staged else { state = .failed("updates.errVerify"); return }
            guard launchInstaller(staged) else { state = .failed("updates.errInstall"); return }
            state = .installing
            NSApp.terminate(nil)
        }
    }

    // MARK: Réseau

    /// Jeton GitHub de l'utilisateur (via `gh`) : indispensable tant que le dépôt est privé. Il ne part que vers api.github.com.
    private func githubToken() async -> String? {
        if let token { return token }
        let value: String? = await Task.detached {
            for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
                let result = Self.run(path, ["auth", "token"])
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.status == 0, !text.isEmpty { return text }
            }
            return nil
        }.value
        token = .some(value)
        return value
    }

    private func request(_ url: URL, accept: String) async -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("mCLEAN-updater", forHTTPHeaderField: "User-Agent")
        if let token = await githubToken() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private enum Fetch { case release(ReleaseInfo), noRelease, failed }

    /// 404 : aucune release publiée, ou dépôt privé sans jeton (alors `gh` n'est pas connecté : c'est un échec).
    private func fetchLatest() async -> Fetch {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return .failed }
        let req = await request(url, accept: "application/vnd.github+json")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        if status == 404 { return await githubToken() == nil ? .failed : .noRelease }
        guard status == 200 else { return .failed }
        return ReleaseParser.parse(data, assetPrefix: "mCLEAN-").map(Fetch.release) ?? .noRelease
    }

    /// Évite d'envoyer le jeton GitHub au stockage de fichiers vers lequel GitHub redirige.
    private final class StripAuth: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var next = request
            if request.url?.host != "api.github.com" { next.setValue(nil, forHTTPHeaderField: "Authorization") }
            completionHandler(next)
        }
    }

    private func download(_ release: ReleaseInfo) async -> URL? {
        let req = await request(release.assetURL, accept: "application/octet-stream")
        let session = URLSession(configuration: .ephemeral, delegate: StripAuth(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (file, response) = try? await session.download(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("mCLEAN-\(UUID().uuidString).zip")
        do { try FileManager.default.moveItem(at: file, to: kept) } catch { return nil }
        return kept
    }

    // MARK: Contrôle et remplacement

    nonisolated static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private nonisolated static func requirement(of app: String) -> String? {
        let result = run("/usr/bin/codesign", ["-d", "-r-", app])
        return result.output.split(separator: "\n").first { $0.hasPrefix("designated =>") }.map(String.init)
    }

    /// Décompresse l'archive puis vérifie : identifiant, version annoncée, signature intacte et même exigence de signature que l'appli en cours.
    nonisolated static func stage(zip: URL, expected: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mCLEAN-update-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]).status == 0 else { return nil }
        let app = dir.appendingPathComponent("mCLEAN.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              AppVersion(version) == AppVersion(expected),
              run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path]).status == 0,
              let new = requirement(of: app.path), new == requirement(of: Bundle.main.bundlePath) else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return app
    }

    private func launchInstaller(_ newApp: URL) -> Bool {
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { return false }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("mCLEAN-install-\(UUID().uuidString).sh")
        let text = InstallScript.make(pid: ProcessInfo.processInfo.processIdentifier, newApp: newApp.path, destination: destination.path)
        do { try text.write(to: script, atomically: true, encoding: .utf8) } catch { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }
}
