import Foundation
import MacStorageCore

public struct StorageClassifier: Sendable {
    public init() {}

    public func classify(path: String, isDirectory: Bool, fileExtension: String?, isPackage: Bool) -> StorageCategory {
        let expanded = (path as NSString).expandingTildeInPath
        let lower = expanded.lowercased()
        let name = (expanded as NSString).lastPathComponent.lowercased()

        // Developer caches & artifacts (check before generic cache)
        if matchesAny(lower, patterns: Self.developerCachePatterns) {
            return .developerCache
        }
        if matchesAny(lower, patterns: Self.buildArtifactPatterns) || name == "node_modules" || name == "deriveddata" || name == "target" && lower.contains("/target") {
            if name == "target" && (lower.contains("/rust") || lower.hasSuffix("/target") || lower.contains("/target/")) {
                return .buildArtifacts
            }
            if name == "node_modules" || name == "deriveddata" || lower.contains("/build/") && lower.contains("/xcode") {
                return .buildArtifacts
            }
            if matchesAny(lower, patterns: Self.buildArtifactPatterns) {
                return .buildArtifacts
            }
        }

        if matchesAny(lower, patterns: Self.browserCachePatterns) {
            return .browserCache
        }
        if matchesAny(lower, patterns: Self.cachePatterns) {
            return .cache
        }
        if matchesAny(lower, patterns: Self.logPatterns) || name.hasSuffix(".log") {
            return .logs
        }
        if matchesAny(lower, patterns: Self.tempPatterns) {
            return .temporary
        }
        if matchesAny(lower, patterns: Self.containerPatterns) {
            return .containers
        }
        if matchesAny(lower, patterns: Self.vmPatterns) {
            return .virtualMachines
        }
        if matchesAny(lower, patterns: Self.backupPatterns) {
            return .backups
        }
        if matchesAny(lower, patterns: Self.databasePatterns) {
            return .databases
        }

        if isPackage || name.hasSuffix(".app") || lower.contains("/applications/") {
            if name.hasSuffix(".app") || isPackage {
                return .applications
            }
        }

        if lower.contains("/downloads") {
            return .downloads
        }

        if let ext = fileExtension?.lowercased() {
            if Self.imageExts.contains(ext) { return .images }
            if Self.videoExts.contains(ext) { return .videos }
            if Self.audioExts.contains(ext) { return .audio }
            if Self.archiveExts.contains(ext) { return .archives }
            if Self.documentExts.contains(ext) { return .documents }
            if Self.sourceExts.contains(ext) { return .sourceCode }
        }

        if name.hasPrefix(".") {
            return .hidden
        }

        if lower.hasPrefix("/system") || lower.hasPrefix("/library") && !lower.hasPrefix(NSHomeDirectory().lowercased()) {
            return .system
        }

        if !isDirectory {
            return .userFiles
        }
        return .unknown
    }

    public func classify(_ record: WorkerFileRecord) -> StorageCategory {
        classify(
            path: record.path,
            isDirectory: record.isDirectory,
            fileExtension: record.fileExtension,
            isPackage: record.isPackage
        )
    }

    private func matchesAny(_ path: String, patterns: [String]) -> Bool {
        for p in patterns {
            if path.contains(p) { return true }
        }
        return false
    }

    // Patterns are lowercase path substrings
    private static let developerCachePatterns = [
        "/library/developer/xcode/deriveddata",
        "/library/developer/coreSimulator",
        "/library/developer/xcode/ios deviceSupport",
        "/library/android/sdk",
        "/.gradle/caches",
        "/.m2/repository",
        "/cocoapods",
        "/library/caches/org.swift.swiftpm",
        "/.swiftpm",
        "/library/caches/homebrew",
        "/.cargo/registry",
        "/.cargo/git",
        "/.npm",
        "/library/caches/pip",
        "/.cache/pip",
        "/.conda",
        "/library/caches/yarn",
        "/.pnpm-store",
        "/library/caches/pnpm",
        "/.terraform",
        "/library/application support/code/cachedextension",
        "/library/application support/code/cache",
        "/library/application support/cursor/cache",
        "/.docker",
        "/library/containers/com.docker",
    ]

    private static let buildArtifactPatterns = [
        "/deriveddata",
        "/node_modules",
        "/.build/",
        "/build/intermediates",
        "/pods/",
        "/carthage/build",
    ]

    private static let browserCachePatterns = [
        "/library/caches/google/chrome",
        "/library/caches/com.google.chrome",
        "/library/caches/firefox",
        "/library/caches/com.apple.safari",
        "/library/caches/company.thebrowser.browser",
        "/library/safari/localstorage",
        "/library/caches/com.brave.browser",
        "/library/caches/com.operasoftware.opera",
        "/library/caches/com.microsoft.edgemac",
        "/library/application support/google/chrome/default/service worker",
    ]

    private static let cachePatterns = [
        "/library/caches/",
        "/library/logs/",
        "/.cache/",
    ]

    private static let logPatterns = [
        "/library/logs/",
        "/private/var/log",
        "/var/log",
    ]

    private static let tempPatterns = [
        "/tmp/",
        "/private/tmp/",
        "/var/folders/",
        "/library/caches/temporaryitems",
    ]

    private static let containerPatterns = [
        "/library/containers/",
        "/library/group containers/",
        "docker/volumes",
        "docker/overlay",
    ]

    private static let vmPatterns = [
        "/utm/",
        "parallels",
        "vmware",
        ".vmdk",
        ".qcow2",
        "virtualbox",
        "library/containers/com.utmapp",
    ]

    private static let backupPatterns = [
        "/library/application support/mobilebackup",
        "timemachine",
        ".backup",
        "/backups/",
    ]

    private static let databasePatterns = [
        ".sqlite",
        ".sqlite3",
        ".db",
        ".realm",
        "postgres",
        "mysql",
    ]

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "raw", "svg"
    ]
    private static let videoExts: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg"
    ]
    private static let audioExts: Set<String> = [
        "mp3", "aac", "m4a", "wav", "aiff", "flac", "ogg", "caf"
    ]
    private static let archiveExts: Set<String> = [
        "zip", "dmg", "pkg", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz", "ipa"
    ]
    private static let documentExts: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "pages", "numbers", "key"
    ]
    private static let sourceExts: Set<String> = [
        "swift", "m", "mm", "h", "c", "cpp", "rs", "go", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rb", "sh"
    ]
}
