import Foundation
import AppKit

/// Full Disk Access helpers. macOS never auto-lists most apps — user must add via +.
public final class AccessController: @unchecked Sendable {
    public static let shared = AccessController()

    public static let applicationsInstallName = "MacStorage Studio.app"

    private let defaults = UserDefaults.standard
    private let allowAllKey = "mss.access.allowAll"
    private let onboardingShownKey = "mss.access.onboardingShown"

    private init() {}

    public var allowAllAccess: Bool {
        get { defaults.bool(forKey: allowAllKey) }
        set {
            defaults.set(newValue, forKey: allowAllKey)
            defaults.synchronize()
        }
    }

    public var hasSeenOnboarding: Bool {
        get { defaults.bool(forKey: onboardingShownKey) }
        set { defaults.set(newValue, forKey: onboardingShownKey) }
    }

    public var hasFullDiskAccess: Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Safari",
            NSHomeDirectory() + "/Library/Mail",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC",
            NSHomeDirectory() + "/Library/Suggestions",
            NSHomeDirectory() + "/Library/Assistant/SiriVocabulary",
            NSHomeDirectory() + "/Library/Containers/com.apple.Safari",
        ]
        for path in probes {
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                return true
            }
        }
        return false
    }

    public var isFullyAuthorized: Bool {
        allowAllAccess && hasFullDiskAccess
    }

    public var applicationsInstallURL: URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(Self.applicationsInstallName)
    }

    /// Prefer /Applications install, then running bundle, then dist build.
    public var appBundleURL: URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: applicationsInstallURL.path) {
            return applicationsInstallURL
        }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return bundle
        }
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/MacStorage Studio.app"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/MacStorageStudio.app"),
            bundle.deletingLastPathComponent().appendingPathComponent("MacStorage Studio.app"),
            bundle.deletingLastPathComponent().appendingPathComponent("MacStorageStudio.app"),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            return url
        }
        return bundle.pathExtension == "app" ? bundle : applicationsInstallURL
    }

    public var workerExecutableURL: URL? {
        if let builtIn = Bundle.main.url(forAuxiliaryExecutable: "ScannerWorker") {
            return builtIn
        }
        let sibling = appBundleURL.appendingPathComponent("Contents/MacOS/ScannerWorker")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    public func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @discardableResult
    public func registerWithTCC() -> Bool {
        _ = hasFullDiskAccess
        return hasFullDiskAccess
    }

    public func revealAppInFinder() {
        let url = appBundleURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    public func revealWorkerInFinder() {
        if let worker = workerExecutableURL {
            NSWorkspace.shared.activateFileViewerSelecting([worker])
        } else {
            revealAppInFinder()
        }
    }

    /// Copy the best available .app into /Applications as "MacStorage Studio.app".
    /// This is the path users should add with + in Full Disk Access.
    @discardableResult
    public func installToApplications() throws -> URL {
        let fm = FileManager.default
        let dest = applicationsInstallURL

        // Prefer currently running .app; else dist builds
        var source: URL?
        let running = Bundle.main.bundleURL
        if running.pathExtension == "app", fm.fileExists(atPath: running.path) {
            source = running
        }
        if source == nil {
            let distCandidates = [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("dist/MacStorage Studio.app"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("dist/MacStorageStudio.app"),
                running.deletingLastPathComponent().appendingPathComponent("MacStorageStudio.app"),
            ]
            source = distCandidates.first { fm.fileExists(atPath: $0.path) }
        }
        guard let source else {
            throw NSError(
                domain: "MacStorageStudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not find MacStorage Studio.app to install. Build with make app first."]
            )
        }

        if source.standardizedFileURL == dest.standardizedFileURL {
            return dest
        }

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)

        // Ad-hoc re-sign after copy (Gatekeeper / identity stability)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--force", "--deep", "--sign", "-", dest.path]
        try? task.run()
        task.waitUntilExit()

        return dest
    }

    /// Install to Applications, open FDA settings, reveal app for the + button.
    public func requestAllowAllAccess() {
        allowAllAccess = true
        hasSeenOnboarding = true
        do {
            let installed = try installToApplications()
            registerWithTCC()
            openFullDiskAccessSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSWorkspace.shared.activateFileViewerSelecting([installed])
            }
        } catch {
            registerWithTCC()
            openFullDiskAccessSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.revealAppInFinder()
            }
        }
    }

    public func revokeAllowAllAccess() {
        allowAllAccess = false
    }

    public func scanRoots(home: String = NSHomeDirectory()) -> [String] {
        let raw: [String]
        if allowAllAccess {
            raw = VolumeEnumerator.fullAccessScanRoots(home: home)
        } else {
            raw = VolumeEnumerator.limitedScanRoots(home: home)
        }
        return SystemGuardrails.shared.filterRoots(raw)
    }

    public func scanRootsAllowingLimited(home: String = NSHomeDirectory()) -> [String] {
        let roots = scanRoots(home: home)
        if roots.isEmpty {
            return SystemGuardrails.shared.filterRoots([home])
        }
        return roots
    }
}

extension VolumeEnumerator {
    public static func limitedScanRoots(home: String = NSHomeDirectory()) -> [String] {
        defaultScanRoots(home: home)
    }

    public static func fullAccessScanRoots(home: String = NSHomeDirectory()) -> [String] {
        var roots: [String] = []
        let candidates = [
            home,
            "/Applications",
            "\(home)/Applications",
            "/Library",
            "/Users",
            "/opt",
            "/usr/local",
        ]
        for path in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                if !roots.contains(path) { roots.append(path) }
            }
        }
        for volume in mountedVolumes() {
            if volume.path.hasPrefix("/System") { continue }
            if !roots.contains(volume.path) {
                roots.append(volume.path)
            }
        }
        return roots.sorted { $0.count < $1.count }
    }
}
