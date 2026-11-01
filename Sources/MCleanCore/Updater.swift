import Foundation

/// Version `x.y.z` (les suffixes `-beta` et le préfixe `v` sont ignorés).
public struct AppVersion: Comparable, Equatable {
    public let parts: [Int]

    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        core = core.split(separator: "-").first.map(String.init) ?? core
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }), numbers.count <= 3 else { return nil }
        parts = numbers.compactMap { $0 } + Array(repeating: 0, count: 3 - numbers.count)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

/// Dernière version publiée : balise et archive `.zip` de l'appli.
public struct ReleaseInfo: Equatable {
    public var tag: String
    public var version: String
    public var assetURL: URL
    public var assetName: String
    public var notes: String
}

public enum ReleaseParser {
    /// Lit la réponse de `GET /repos/<dépôt>/releases/latest`. Rien si la release est un brouillon, une préversion ou sans archive `<prefix>*.zip`.
    public static func parse(_ data: Data, assetPrefix: String) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              (json["draft"] as? Bool) != true, (json["prerelease"] as? Bool) != true,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        for asset in assets {
            guard let name = asset["name"] as? String, name.hasPrefix(assetPrefix), name.hasSuffix(".zip"),
                  let text = asset["url"] as? String, let url = URL(string: text),
                  url.scheme == "https", url.host == "api.github.com" else { continue }
            let shown = version.parts.map(String.init).joined(separator: ".")
            return ReleaseInfo(tag: tag, version: shown, assetURL: url, assetName: name, notes: json["body"] as? String ?? "")
        }
        return nil
    }
}

public func isUpdate(latest: String, over current: String) -> Bool {
    guard let a = AppVersion(latest), let b = AppVersion(current) else { return false }
    return a > b
}

public enum InstallScript {
    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Script lancé à part : attend la fin de l'appli, remplace le paquet (en le remettant si la copie échoue) puis relance en arrière-plan.
    public static func make(pid: Int32, newApp: String, destination: String) -> String {
        let old = destination + ".old"
        return """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(quoted(old))
        mv \(quoted(destination)) \(quoted(old)) || exit 1
        if /usr/bin/ditto \(quoted(newApp)) \(quoted(destination)); then
            rm -rf \(quoted(old)) \(quoted(newApp))
        else
            rm -rf \(quoted(destination)); mv \(quoted(old)) \(quoted(destination))
        fi
        /usr/bin/xattr -cr \(quoted(destination)) 2>/dev/null
        /usr/bin/open -g \(quoted(destination))

        """
    }
}
