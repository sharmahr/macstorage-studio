import Foundation
import SwiftUI
import Combine
import MacStorageCore
import MetadataStore
import ScannerClient
import Classifier
import Recommendations
import CleanupEngine
import Analysis

enum StudioDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case hierarchy
    case graph
    case history
    case orphans
    case duplicates
    case cleanup
    case search
    case guardrails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .hierarchy: return "Hierarchy"
        case .graph: return "Graph"
        case .history: return "History"
        case .orphans: return "Orphans"
        case .duplicates: return "Duplicates"
        case .cleanup: return "Cleanup"
        case .search: return "Search"
        case .guardrails: return "Guardrails"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .hierarchy: return "folder"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .history: return "chart.xyaxis.line"
        case .orphans: return "app.badge.checkmark"
        case .duplicates: return "doc.on.doc"
        case .cleanup: return "trash"
        case .search: return "magnifyingglass"
        case .guardrails: return "lock.shield"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var session: ScanSession?
    @Published var isScanning = false
    @Published var progress = ScanProgress()
    @Published var statusMessage = "Ready"
    @Published var roots: [String] = VolumeEnumerator.defaultScanRoots()
    @Published var volumes: [VolumeInfo] = VolumeEnumerator.mountedVolumes()
    @Published var hierarchy: [FileEntry] = []
    @Published var selectedPath: String?
    @Published var recommendations: [CleanupRecommendation] = []
    @Published var categoryBreakdown: [(StorageCategory, Int64, Int)] = []
    @Published var largestFiles: [FileEntry] = []
    @Published var searchQuery = ""
    @Published var searchResults: [FileEntry] = []
    @Published var errorMessage: String?
    @Published var lastCrashNote: String?
    @Published var destination: StudioDestination = .overview
    @Published var allowAllAccess: Bool = AccessController.shared.allowAllAccess
    @Published var hasFullDiskAccess: Bool = AccessController.shared.hasFullDiskAccess
    @Published var showAccessSheet: Bool = false
    @Published var guardrailRules: [GuardrailRuleUI] = []
    @Published var activeExcludePrefixes: [String] = []
    @Published var lastSkippedSystem: Int = 0

    // Analysis
    @Published var dependencyGraph = DependencyGraph()
    @Published var historyReport = HistoryReport()
    @Published var orphanReport = OrphanReport()
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var isAnalyzingOrphans = false
    @Published var isFindingDuplicates = false
    @Published var allSessions: [ScanSession] = []

    let store: MetadataStore
    private let classifier = StorageClassifier()
    private let recommendationEngine = RecommendationEngine()
    private let cleanupEngine = CleanupEngine()
    private let graphBuilder = GraphBuilder()
    private let orphanMapper = OrphanMapper()
    private let historyAnalytics = HistoryAnalytics()
    private var scanner: ScannerClient?
    private var entryBuffer: [FileEntry] = []
    private let bufferLimit = 200

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacStorageStudio", isDirectory: true)
        let dbURL = support.appendingPathComponent("library.sqlite")
        do {
            store = try MetadataStore(databaseURL: dbURL)
        } catch {
            store = try! MetadataStore(
                databaseURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("macstorage-fallback.sqlite")
            )
            errorMessage = "Database error: \(error.localizedDescription)"
        }

        if let worker = ScannerClient.locateWorker() {
            scanner = ScannerClient(workerURL: worker)
            statusMessage = "Ready · worker isolated"
        } else {
            statusMessage = "ScannerWorker not found — build the worker first"
        }

        refreshVolumes()
        reloadGuardrails()
        if !AccessController.shared.hasSeenOnboarding || !AccessController.shared.allowAllAccess {
            showAccessSheet = true
        }
        Task {
            await loadLatestSession()
            await refreshHistory()
        }
    }

    func reloadGuardrails() {
        let g = SystemGuardrails.shared
        guardrailRules = g.catalog.map {
            GuardrailRuleUI(rule: $0, enabled: g.isEnabled($0))
        }
        activeExcludePrefixes = g.excludePrefixes()
    }

    func setGuardrail(_ rule: GuardrailRule, enabled: Bool) {
        SystemGuardrails.shared.setEnabled(rule, enabled: enabled)
        reloadGuardrails()
        roots = AccessController.shared.scanRoots()
        statusMessage = enabled
            ? "Guardrail on: \(rule.title)"
            : "Guardrail off: \(rule.title)"
    }

    func refreshVolumes() {
        volumes = VolumeEnumerator.mountedVolumes()
        refreshAccessState()
        roots = AccessController.shared.scanRoots()
    }

    func refreshAccessState() {
        allowAllAccess = AccessController.shared.allowAllAccess
        hasFullDiskAccess = AccessController.shared.hasFullDiskAccess
    }

    /// Single allow-all gate — enables full app/volume scan scope and opens FDA settings once.
    func enableAllowAllAccess() {
        AccessController.shared.requestAllowAllAccess()
        refreshAccessState()
        roots = AccessController.shared.scanRoots()
        statusMessage = hasFullDiskAccess
            ? "Full access enabled — all apps and volumes"
            : "Enable MacStorage Studio under Full Disk Access, then return here"
        showAccessSheet = false
    }

    func disableAllowAllAccess() {
        AccessController.shared.revokeAllowAllAccess()
        refreshAccessState()
        roots = AccessController.shared.scanRoots()
        statusMessage = "Limited access — home and external volumes only"
    }

    func openFullDiskAccessSettings() {
        AccessController.shared.openFullDiskAccessSettings()
    }

    /// Call before scan: if allow-all not chosen, present sheet instead of per-path prompts.
    func prepareScanAccess() -> Bool {
        refreshAccessState()
        if !AccessController.shared.allowAllAccess {
            showAccessSheet = true
            return false
        }
        roots = AccessController.shared.scanRoots()
        return true
    }

    func loadLatestSession() async {
        do {
            if let latest = try store.latestSession() {
                session = latest
                try await reloadDerived(sessionID: latest.id)
            }
            allSessions = try store.allSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSession(id: UUID) async {
        do {
            guard let s = try store.session(id: id) else { return }
            session = s
            try await reloadDerived(sessionID: id)
            destination = .overview
            statusMessage = "Loaded scan from \(s.startedAt.formatted())"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startScan(resume: Bool = false) async {
        guard !isScanning else { return }
        guard let scanner else {
            errorMessage = ScannerClientError.workerNotFound.localizedDescription
            return
        }

        if !resume {
            // One allow-all consent instead of individual app/folder prompts
            guard prepareScanAccess() else { return }
        } else {
            roots = AccessController.shared.scanRoots()
        }

        isScanning = true
        errorMessage = nil
        lastCrashNote = nil
        progress = ScanProgress()
        statusMessage = "Starting scan…"
        entryBuffer.removeAll(keepingCapacity: true)

        let checkpoint = resume ? session?.checkpointPath : nil
        var session: ScanSession
        if resume, let existing = self.session {
            session = existing
            session.status = .running
        } else {
            session = ScanSession(status: .running, roots: roots)
        }
        self.session = session

        do {
            try store.upsertSession(session)
            if !resume {
                try store.deleteEntries(sessionID: session.id)
            }
        } catch {
            errorMessage = error.localizedDescription
            isScanning = false
            return
        }

        statusMessage = "Scanning…"
        let sessionID = session.id
        let classifier = self.classifier

        do {
            let result = try await scanner.scan(
                roots: SystemGuardrails.shared.filterRoots(roots),
                excludePrefixes: SystemGuardrails.shared.excludePrefixes(),
                checkpoint: checkpoint,
                onEntry: { record in
                    let category = classifier.classify(record)
                    let entry = FileEntry(
                        sessionID: sessionID,
                        path: record.path,
                        parentPath: record.parentPath,
                        name: record.name,
                        isDirectory: record.isDirectory,
                        size: record.size,
                        allocatedSize: record.allocatedSize,
                        createdAt: record.createdAt.map { Date(timeIntervalSince1970: $0) },
                        modifiedAt: record.modifiedAt.map { Date(timeIntervalSince1970: $0) },
                        accessedAt: record.accessedAt.map { Date(timeIntervalSince1970: $0) },
                        ownerID: record.ownerID,
                        permissions: record.permissions,
                        inode: record.inode,
                        device: record.device,
                        linkCount: record.linkCount,
                        isSymbolicLink: record.isSymbolicLink,
                        fileExtension: record.fileExtension,
                        category: category,
                        isPackage: record.isPackage
                    )
                    await self.bufferEntry(entry)
                },
                onProgress: { progress in
                    await self.applyProgress(progress)
                }
            )

            try await flushBuffer()
            try store.rollupDirectorySizes(sessionID: sessionID)
            session.status = .completed
            session.finishedAt = Date()
            session.filesScanned = result.scanned
            session.bytesScanned = result.bytes
            session.checkpointPath = result.checkpoint
            try store.upsertSession(session)
            self.session = session
            try await buildRecommendations(sessionID: sessionID)
            try await reloadDerived(sessionID: sessionID)
            await runOrphanAnalysis()
            await refreshHistory()
            statusMessage = "Scan complete — \(result.scanned) items"
        } catch let err as ScannerClientError {
            try? await flushBuffer()
            switch err {
            case .workerCrashed:
                session.status = .crashed
                session.errorMessage = err.localizedDescription
                session.checkpointPath = progress.currentPath.isEmpty ? session.checkpointPath : progress.currentPath
                session.filesScanned = progress.scanned
                session.bytesScanned = progress.bytes
                try? store.upsertSession(session)
                self.session = session
                lastCrashNote = err.localizedDescription
                statusMessage = "Scanner crashed — app still running. Resume when ready."
                errorMessage = err.localizedDescription
            case .cancelled:
                session.status = .cancelled
                session.finishedAt = Date()
                try? store.upsertSession(session)
                self.session = session
                statusMessage = "Scan cancelled"
            default:
                session.status = .failed
                session.errorMessage = err.localizedDescription
                session.finishedAt = Date()
                try? store.upsertSession(session)
                self.session = session
                errorMessage = err.localizedDescription
                statusMessage = "Scan failed"
            }
        } catch {
            try? await flushBuffer()
            session.status = .failed
            session.errorMessage = error.localizedDescription
            session.finishedAt = Date()
            try? store.upsertSession(session)
            self.session = session
            errorMessage = error.localizedDescription
            statusMessage = "Scan failed"
        }

        isScanning = false
        allSessions = (try? store.allSessions()) ?? allSessions
    }

    func resumeScan() async { await startScan(resume: true) }
    func cancelScan() async { await scanner?.cancel() }

    func testWorkerCrashIsolation() async {
        guard let scanner else {
            errorMessage = ScannerClientError.workerNotFound.localizedDescription
            return
        }
        do {
            try await scanner.runCrashTest()
            lastCrashNote = "Crash test returned cleanly (unexpected)."
        } catch let err as ScannerClientError {
            lastCrashNote = "Isolation OK — \(err.localizedDescription)"
            statusMessage = "Worker crash contained"
        } catch {
            lastCrashNote = error.localizedDescription
        }
    }

    func loadChildren(of path: String?) async {
        guard let session else { return }
        do {
            hierarchy = try store.children(sessionID: session.id, parentPath: path)
            selectedPath = path
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runSearch() async {
        guard let session else { return }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            return
        }
        do {
            searchResults = try store.search(sessionID: session.id, query: q)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trash(recommendation: CleanupRecommendation) async {
        await trashPath(recommendation.path, bytes: recommendation.reclaimableBytes)
        recommendations.removeAll { $0.id == recommendation.id }
    }

    func trashPath(_ path: String, bytes: Int64) async {
        do {
            let result = try cleanupEngine.trash(path: path, reclaimableBytes: bytes)
            statusMessage = "Moved to Trash: \(result.path)"
            var orphans = orphanReport
            orphans.orphans.removeAll { $0.path == path }
            orphanReport = orphans
            duplicateGroups = duplicateGroups.compactMap { group in
                var g = group
                g.paths.removeAll { $0 == path }
                return g.paths.count >= 2 ? g : nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runOrphanAnalysis() async {
        guard let session else { return }
        isAnalyzingOrphans = true
        defer { isAnalyzingOrphans = false }
        do {
            let dirs = try store.largestDirectories(sessionID: session.id, limit: 5_000)
            // also pull library-ish entries via search heuristics is heavy; use largest + category samples
            var pool = dirs
            for cat: StorageCategory in [.cache, .applications, .unknown, .hidden] {
                pool.append(contentsOf: try store.entries(sessionID: session.id, category: cat).prefix(500))
            }
            var seen = Set<String>()
            pool = pool.filter { seen.insert($0.path).inserted }
            orphanReport = orphanMapper.analyze(sessionID: session.id, entries: pool)
            rebuildGraph()
            statusMessage = "Orphan analysis: \(orphanReport.orphans.count) candidates"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runDuplicateDetection(minimumBytes: Int64 = 100_000) async {
        guard let session else { return }
        isFindingDuplicates = true
        defer { isFindingDuplicates = false }
        do {
            let files = try store.largestEntries(sessionID: session.id, limit: 8_000)
            let detector = DuplicateDetector(minimumFileBytes: minimumBytes, maxFilesToHash: 2_500)
            duplicateGroups = await detector.findDuplicates(files: files)
            statusMessage = "Duplicates: \(duplicateGroups.count) groups"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshHistory() async {
        do {
            let sessions = try store.allSessions()
            allSessions = sessions
            var map: [UUID: [(StorageCategory, Int64, Int)]] = [:]
            // Only compute breakdown for recent sessions to stay snappy
            for s in sessions.prefix(12) {
                map[s.id] = (try? store.categoryBreakdown(sessionID: s.id)) ?? []
            }
            historyReport = historyAnalytics.buildReport(sessions: sessions, categoryBySession: map)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildGraph() {
        let tops = (try? store.largestDirectories(sessionID: session?.id ?? UUID(), limit: 30)) ?? []
        dependencyGraph = graphBuilder.build(
            volumes: volumes,
            session: session,
            topDirectories: tops,
            apps: orphanReport.applications,
            orphans: orphanReport.orphans,
            categoryBreakdown: categoryBreakdown
        )
    }

    private func applyProgress(_ progress: ScanProgress) {
        self.progress = progress
        lastSkippedSystem = progress.skippedSystem
        var status = "Scanned \(progress.scanned) · \(ByteFormat.string(progress.bytes))"
        if progress.skippedSystem > 0 {
            status += " · \(progress.skippedSystem) system paths skipped"
        }
        statusMessage = status
        if progress.workerRestarts > 0 {
            lastCrashNote = "Scanner worker restarted \(progress.workerRestarts)× — resume automatic."
        }
    }

    private func bufferEntry(_ entry: FileEntry) async {
        entryBuffer.append(entry)
        if entryBuffer.count >= bufferLimit {
            try? await flushBuffer()
        }
    }

    private func flushBuffer() async throws {
        guard !entryBuffer.isEmpty else { return }
        let batch = entryBuffer
        entryBuffer.removeAll(keepingCapacity: true)
        try store.insertEntries(batch)
    }

    private func buildRecommendations(sessionID: UUID) async throws {
        var pool = try store.largestDirectories(sessionID: sessionID, limit: 200)
        pool.append(contentsOf: try store.largestEntries(sessionID: sessionID, limit: 200))
        for cat: StorageCategory in [.developerCache, .cache, .browserCache, .buildArtifacts, .logs, .downloads, .archives, .temporary] {
            pool.append(contentsOf: try store.entries(sessionID: sessionID, category: cat).prefix(200))
        }
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0.path).inserted }
        let recs = recommendationEngine.recommendations(sessionID: sessionID, entries: pool)
            .filter { !SystemGuardrails.shared.isProtected($0.path) }
        try store.replaceRecommendations(recs, sessionID: sessionID)
        recommendations = recs
    }

    private func reloadDerived(sessionID: UUID) async throws {
        categoryBreakdown = try store.categoryBreakdown(sessionID: sessionID)
        largestFiles = try store.largestEntries(sessionID: sessionID, limit: 40)
        recommendations = try store.recommendations(sessionID: sessionID)
        if let root = session?.roots.first {
            hierarchy = try store.children(sessionID: sessionID, parentPath: root)
            if hierarchy.isEmpty {
                hierarchy = try store.children(sessionID: sessionID, parentPath: nil)
            }
            selectedPath = root
        }
        rebuildGraph()
    }
}
