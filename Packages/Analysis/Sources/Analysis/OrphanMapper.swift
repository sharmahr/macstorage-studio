import Foundation
import MacStorageCore

public struct OrphanMapper: Sendable {
    public init() {}

    public func analyze(sessionID: UUID, home: String = NSHomeDirectory(), entries: [FileEntry]) -> OrphanReport {
        let apps = discoverApplications(home: home, entries: entries)
        let installedBundleIDs = Set(apps.compactMap(\.bundleID).map { $0.lowercased() })
        let installedNames = Set(apps.map { sanitize($0.name) })
        var orphans: [OrphanArtifact] = []
        let supportRoots = [
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/Preferences",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Logs",
            "\(home)/Library/Application Support/CrashReporter",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/Internet Plug-Ins",
            "\(home)/Library/Audio/Plug-Ins",
            "\(home)/Library/PreferencePanes",
        ]

        // Index directory entries under support roots
        let dirs = entries.filter { $0.isDirectory }
        for dir in dirs {
            guard supportRoots.contains(where: { dir.path.hasPrefix($0 + "/") || dir.parentPath == $0 }) else {
                continue
            }
            // Only direct children of support roots for orphan candidates
            guard let parent = dir.parentPath, supportRoots.contains(parent) else { continue }

            let kind = kindFor(parentPath: parent)
            let token = sanitize(dir.name)
            let bundleGuess = extractBundleID(from: dir.name)

            let matchedApp = apps.first { app in
                if let bid = app.bundleID?.lowercased(), let g = bundleGuess?.lowercased(), bid == g {
                    return true
                }
                let n = sanitize(app.name)
                return token == n || token.contains(n) || n.contains(token)
            }

            if matchedApp != nil {
                // Owned — attach support path
                continue
            }

            // Prefer treating reverse-DNS folders without installed owner as orphans
            let looksLikeBundle = dir.name.contains(".") && dir.name.split(separator: ".").count >= 2
            let looksLikeAppName = !dir.name.hasPrefix(".") && dir.name.count > 2

            guard looksLikeBundle || looksLikeAppName else { continue }

            // Skip system/Apple folders
            if dir.name.hasPrefix("com.apple.") || dir.name.hasPrefix("com.apple") {
                continue
            }

            var confidence = 0.55
            var reason = "No installed application matches this support folder."
            if looksLikeBundle {
                confidence = 0.8
                reason = "Bundle-style folder \(dir.name) has no matching installed app bundle ID."
            }
            if installedBundleIDs.contains(dir.name.lowercased()) {
                continue
            }
            if installedNames.contains(token) {
                continue
            }

            orphans.append(OrphanArtifact(
                path: dir.path,
                name: dir.name,
                bytes: dir.size,
                kind: kind,
                suspectedOwner: bundleGuess ?? dir.name,
                confidence: confidence,
                reason: reason
            ))
        }

        // Also mark leftover .app paths under Applications that only have support remnants — already covered

        // Enrich apps with support paths from entries
        var enrichedApps = apps
        for i in enrichedApps.indices {
            let app = enrichedApps[i]
            let tokens = [sanitize(app.name), app.bundleID.map(sanitize)].compactMap { $0 }
            let supports = dirs.filter { dir in
                supportRoots.contains(where: { dir.parentPath == $0 }) &&
                tokens.contains(where: { t in
                    let n = sanitize(dir.name)
                    return n == t || n.contains(t) || (app.bundleID?.lowercased() == dir.name.lowercased())
                })
            }
            enrichedApps[i].supportPaths = supports.map(\.path)
            enrichedApps[i].totalSupportBytes = supports.reduce(0) { $0 + $1.size }
        }

        let total = orphans.reduce(Int64(0)) { $0 + $1.bytes }
        return OrphanReport(
            applications: enrichedApps.sorted { $0.totalSupportBytes > $1.totalSupportBytes },
            orphans: orphans.sorted { $0.bytes > $1.bytes },
            totalOrphanBytes: total
        )
    }

    public func discoverApplications(home: String, entries: [FileEntry]) -> [InstalledApplication] {
        var apps: [InstalledApplication] = []
        var seen = Set<String>()

        let searchPaths = [
            "/Applications",
            "\(home)/Applications",
            "/System/Applications",
        ]

        // From filesystem directly for accuracy
        for base in searchPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for name in contents where name.hasSuffix(".app") {
                let path = (base as NSString).appendingPathComponent(name)
                if seen.contains(path) { continue }
                seen.insert(path)
                let display = (name as NSString).deletingPathExtension
                let bid = readBundleID(appPath: path)
                apps.append(InstalledApplication(name: display, path: path, bundleID: bid))
            }
        }

        // Supplement from scan entries (packages)
        for e in entries where e.isPackage || e.name.hasSuffix(".app") {
            if seen.contains(e.path) { continue }
            if e.name.hasSuffix(".app") || e.isPackage {
                seen.insert(e.path)
                let display = e.name.replacingOccurrences(of: ".app", with: "")
                apps.append(InstalledApplication(
                    name: display,
                    path: e.path,
                    bundleID: readBundleID(appPath: e.path)
                ))
            }
        }

        return apps
    }

    private func kindFor(parentPath: String) -> OrphanKind {
        let p = parentPath.lowercased()
        if p.hasSuffix("caches") { return .caches }
        if p.hasSuffix("preferences") { return .preferences }
        if p.contains("containers") { return .containers }
        if p.hasSuffix("logs") { return .logs }
        if p.contains("plug-ins") || p.contains("plugins") { return .plugins }
        if p.contains("application support") { return .supportData }
        return .leftover
    }

    private func sanitize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func extractBundleID(from name: String) -> String? {
        let parts = name.split(separator: ".")
        guard parts.count >= 3 else { return name.contains(".") ? name : nil }
        return name
    }

    private func readBundleID(appPath: String) -> String? {
        let info = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOfFile: info) as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }
}
