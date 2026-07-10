import Foundation
import AppKit

/// Single "Allow All Access" gate — avoids per-folder / per-app permission prompts in-app.
/// Full Disk Access must still be granted once by the user in System Settings (macOS requirement).
public final class AccessController: @unchecked Sendable {
    public static let shared = AccessController()

    private let defaults = UserDefaults.standard
    private let allowAllKey = "mss.access.allowAll"
    private let onboardingShownKey = "mss.access.onboardingShown"

    private init() {}

    /// User opted into full scanning (all apps, Library, volumes).
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

    /// Heuristic: can we read a TCC-protected location that requires Full Disk Access?
    public var hasFullDiskAccess: Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Safari",
            NSHomeDirectory() + "/Library/Mail",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC",
            NSHomeDirectory() + "/Library/Suggestions",
        ]
        for path in probes {
            if FileManager.default.isReadableFile(atPath: path) {
                // Directory readable is a strong signal
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                            return true
                        }
                    } else {
                        return true
                    }
                }
            }
            // Attempt list
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                return true
            }
        }
        return false
    }

    /// Ready for unrestricted scan of apps + protected user data.
    public var isFullyAuthorized: Bool {
        allowAllAccess && hasFullDiskAccess
    }

    public func openFullDiskAccessSettings() {
        // Prefer modern Privacy & Security deep link; fall back to legacy.
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Enable allow-all in preferences and open System Settings so the user can grant FDA once.
    public func requestAllowAllAccess() {
        allowAllAccess = true
        hasSeenOnboarding = true
        openFullDiskAccessSettings()
    }

    public func revokeAllowAllAccess() {
        allowAllAccess = false
    }

    /// Scan roots for the current policy.
    public func scanRoots(home: String = NSHomeDirectory()) -> [String] {
        let raw: [String]
        if allowAllAccess {
            raw = VolumeEnumerator.fullAccessScanRoots(home: home)
        } else {
            raw = VolumeEnumerator.limitedScanRoots(home: home)
        }
        return SystemGuardrails.shared.filterRoots(raw)
    }
}

extension VolumeEnumerator {
    /// Limited: user home + external volumes only (may still hit TCC for Desktop/Documents without FDA).
    public static func limitedScanRoots(home: String = NSHomeDirectory()) -> [String] {
        defaultScanRoots(home: home)
    }

    /// Full: home, Applications, system Applications, startup volume user areas, external volumes.
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
            // Include root volume and externals when allow-all is on
            if !roots.contains(volume.path) {
                // Avoid double-scanning home if it's under /
                roots.append(volume.path)
            }
        }
        // Prefer shorter roots first; scanner still skips SIP prefixes.
        return roots.sorted { $0.count < $1.count }
    }
}
