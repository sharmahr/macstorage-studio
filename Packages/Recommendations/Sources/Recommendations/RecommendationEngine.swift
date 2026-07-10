import Foundation
import MacStorageCore
import Classifier

public struct RecommendationEngine: Sendable {
    private let classifier: StorageClassifier

    public init(classifier: StorageClassifier = StorageClassifier()) {
        self.classifier = classifier
    }

    /// Build cleanup recommendations from scanned entries (typically directories with aggregated sizes).
    public func recommendations(
        sessionID: UUID,
        entries: [FileEntry],
        minimumBytes: Int64 = 5_000_000
    ) -> [CleanupRecommendation] {
        var results: [CleanupRecommendation] = []
        var seenPaths = Set<String>()

        // Prefer directory-level recommendations for known safe caches
        let candidates = entries.filter { entry in
            entry.size >= minimumBytes || entry.isDirectory
        }

        for entry in candidates {
            let category = entry.category == .unknown
                ? classifier.classify(
                    path: entry.path,
                    isDirectory: entry.isDirectory,
                    fileExtension: entry.fileExtension,
                    isPackage: entry.isPackage
                )
                : entry.category

            guard let rule = Self.rules.first(where: { $0.matches(path: entry.path, category: category) }) else {
                continue
            }

            // Deduplicate nested paths: skip if a parent was already recommended
            if seenPaths.contains(where: { entry.path.hasPrefix($0 + "/") }) {
                continue
            }
            // If we recommend a parent later, fine; prefer higher paths via sort

            let size = max(entry.size, entry.allocatedSize)
            guard size >= minimumBytes else { continue }

            seenPaths.insert(entry.path)
            results.append(
                CleanupRecommendation(
                    sessionID: sessionID,
                    path: entry.path,
                    title: rule.title,
                    reason: rule.reason,
                    explanation: rule.explanation(for: entry),
                    confidence: rule.confidence,
                    reclaimableBytes: size,
                    owner: rule.owner,
                    risk: rule.risk,
                    regenerable: rule.regenerable,
                    category: category,
                    dependencies: rule.dependencies
                )
            )
        }

        // Also surface large old downloads (files)
        let downloads = entries.filter {
            $0.category == .downloads && !$0.isDirectory && $0.size >= 50_000_000
        }
        for file in downloads.prefix(20) {
            if seenPaths.contains(file.path) { continue }
            let ageDays: Int
            if let modified = file.modifiedAt {
                ageDays = Calendar.current.dateComponents([.day], from: modified, to: Date()).day ?? 0
            } else {
                ageDays = 0
            }
            guard ageDays >= 30 else { continue }
            results.append(
                CleanupRecommendation(
                    sessionID: sessionID,
                    path: file.path,
                    title: "Large old download",
                    reason: "File sits in Downloads and has not been modified in \(ageDays) days",
                    explanation: "Downloads often accumulate installers and archives that are safe to remove after use. Preview the file before deleting. It will be moved to Trash, not permanently erased.",
                    confidence: 0.7,
                    reclaimableBytes: file.size,
                    owner: "Downloads",
                    risk: .low,
                    regenerable: false,
                    category: .downloads,
                    dependencies: []
                )
            )
        }

        return results.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    private struct Rule {
        var title: String
        var reason: String
        var confidence: Double
        var risk: RiskLevel
        var regenerable: Bool
        var owner: String?
        var dependencies: [String]
        var match: (String, StorageCategory) -> Bool

        func matches(path: String, category: StorageCategory) -> Bool {
            match(path.lowercased(), category)
        }

        func explanation(for entry: FileEntry) -> String {
            """
            Path: \(entry.path)
            Category: \(entry.category.displayName)
            Size: \(ByteFormat.string(entry.size))
            
            \(reason)
            
            Safety: Items are moved to Trash only after confirmation. Regenerable data can usually be recreated by the owning app or toolchain.
            """
        }
    }

    private static let rules: [Rule] = [
        Rule(
            title: "Xcode DerivedData",
            reason: "Xcode rebuilds DerivedData automatically; safe to clear when not mid-compile.",
            confidence: 0.95,
            risk: .safe,
            regenerable: true,
            owner: "Xcode",
            dependencies: ["Xcode may rebuild on next compile"],
            match: { path, _ in path.contains("/library/developer/xcode/deriveddata") }
        ),
        Rule(
            title: "iOS Simulator data",
            reason: "Simulator device data can be reset; reclaim space from unused runtimes/devices.",
            confidence: 0.85,
            risk: .low,
            regenerable: true,
            owner: "Xcode / Simulator",
            dependencies: ["Installed simulator devices"],
            match: { path, _ in path.contains("/library/developer/coresimulator") }
        ),
        Rule(
            title: "SwiftPM cache",
            reason: "Swift package caches are downloaded again as needed.",
            confidence: 0.9,
            risk: .safe,
            regenerable: true,
            owner: "Swift Package Manager",
            dependencies: [],
            match: { path, _ in path.contains("swiftpm") || path.contains("/.swiftpm") }
        ),
        Rule(
            title: "Cargo registry cache",
            reason: "Rust crate sources in the Cargo registry are re-fetched on demand.",
            confidence: 0.9,
            risk: .safe,
            regenerable: true,
            owner: "Rust / Cargo",
            dependencies: [],
            match: { path, _ in path.contains("/.cargo/registry") || path.contains("/.cargo/git") }
        ),
        Rule(
            title: "Gradle cache",
            reason: "Android/Gradle caches can be regenerated; may slow the next build.",
            confidence: 0.88,
            risk: .safe,
            regenerable: true,
            owner: "Gradle",
            dependencies: [],
            match: { path, _ in path.contains("/.gradle/caches") }
        ),
        Rule(
            title: "npm / yarn / pnpm cache",
            reason: "JavaScript package caches are safe to clear and will re-download.",
            confidence: 0.9,
            risk: .safe,
            regenerable: true,
            owner: "Node.js package managers",
            dependencies: [],
            match: { path, _ in
                path.contains("/.npm") || path.contains("yarn") && path.contains("cache")
                    || path.contains("pnpm") && path.contains("cache")
                    || path.contains("/.pnpm-store")
            }
        ),
        Rule(
            title: "Homebrew cache",
            reason: "Downloaded bottles in the Homebrew cache can be re-fetched.",
            confidence: 0.92,
            risk: .safe,
            regenerable: true,
            owner: "Homebrew",
            dependencies: [],
            match: { path, _ in path.contains("homebrew") && path.contains("cache") }
        ),
        Rule(
            title: "Browser cache",
            reason: "Browser caches regenerate while browsing; may briefly slow page loads.",
            confidence: 0.8,
            risk: .low,
            regenerable: true,
            owner: "Web browser",
            dependencies: [],
            match: { _, cat in cat == .browserCache }
        ),
        Rule(
            title: "User Library caches",
            reason: "Generic app caches under ~/Library/Caches are usually regenerable.",
            confidence: 0.75,
            risk: .low,
            regenerable: true,
            owner: "Applications",
            dependencies: [],
            match: { path, cat in
                cat == .cache && path.contains("/library/caches/")
            }
        ),
        Rule(
            title: "Application logs",
            reason: "Log files are diagnostic only and safe to remove when not debugging.",
            confidence: 0.85,
            risk: .safe,
            regenerable: true,
            owner: "Applications",
            dependencies: [],
            match: { path, cat in cat == .logs || path.contains("/library/logs/") }
        ),
        Rule(
            title: "node_modules",
            reason: "Dependencies can be restored with npm/pnpm/yarn install.",
            confidence: 0.8,
            risk: .low,
            regenerable: true,
            owner: "Node project",
            dependencies: ["package.json / lockfile"],
            match: { path, _ in path.hasSuffix("/node_modules") || path.contains("/node_modules/") && path.components(separatedBy: "/").last == "node_modules" }
        ),
        Rule(
            title: "Installer package",
            reason: "Old .dmg/.pkg installers in Downloads are often leftovers after install.",
            confidence: 0.7,
            risk: .low,
            regenerable: false,
            owner: "Downloads",
            dependencies: [],
            match: { path, cat in
                cat == .archives && path.contains("/downloads/")
                    && (path.hasSuffix(".dmg") || path.hasSuffix(".pkg") || path.hasSuffix(".zip"))
            }
        ),
    ]
}
