import XCTest
@testable import Analysis
import MacStorageCore

final class AnalysisTests: XCTestCase {
    func testDuplicateHashGroupsIdenticalContent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mss-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        let payload = Data(repeating: 0xAB, count: 200_000)
        try payload.write(to: a)
        try payload.write(to: b)

        let session = UUID()
        let files = [
            FileEntry(sessionID: session, path: a.path, parentPath: dir.path, name: "a.bin", isDirectory: false, size: Int64(payload.count), allocatedSize: Int64(payload.count)),
            FileEntry(sessionID: session, path: b.path, parentPath: dir.path, name: "b.bin", isDirectory: false, size: Int64(payload.count), allocatedSize: Int64(payload.count)),
        ]
        let groups = await DuplicateDetector(minimumFileBytes: 1_000).findDuplicates(files: files)
        XCTAssertFalse(groups.isEmpty)
        XCTAssertEqual(groups[0].paths.count, 2)
        XCTAssertEqual(groups[0].matchKind, .contentHash)
        XCTAssertGreaterThan(groups[0].wastedBytes, 0)
    }

    func testHistoryDelta() {
        let s1 = ScanSession(id: UUID(), startedAt: Date().addingTimeInterval(-3600), finishedAt: Date().addingTimeInterval(-3500), status: .completed, roots: ["/"], filesScanned: 10, bytesScanned: 1000)
        let s2 = ScanSession(id: UUID(), startedAt: Date().addingTimeInterval(-100), finishedAt: Date(), status: .completed, roots: ["/"], filesScanned: 12, bytesScanned: 2000)
        let map: [UUID: [(StorageCategory, Int64, Int)]] = [
            s1.id: [(.cache, 500, 3)],
            s2.id: [(.cache, 800, 4), (.downloads, 400, 2)],
        ]
        let report = HistoryAnalytics().buildReport(sessions: [s1, s2], categoryBySession: map)
        XCTAssertEqual(report.trend.count, 2)
        XCTAssertFalse(report.categoryDeltas.isEmpty)
        XCTAssertTrue(report.largestGrowth.contains { $0.category == .cache && $0.deltaBytes == 300 })
    }

    func testGraphBuilderProducesNodes() {
        let graph = GraphBuilder().build(
            volumes: [VolumeInfo(name: "Macintosh HD", path: "/", totalCapacity: 100, availableCapacity: 40, isInternal: true, isEjectable: false)],
            session: ScanSession(roots: [NSHomeDirectory()], filesScanned: 10, bytesScanned: 999),
            topDirectories: [
                FileEntry(sessionID: UUID(), path: NSHomeDirectory() + "/Library/Caches", parentPath: NSHomeDirectory() + "/Library", name: "Caches", isDirectory: true, size: 500, allocatedSize: 500, category: .cache)
            ],
            apps: [InstalledApplication(name: "Safari", path: "/Applications/Safari.app", bundleID: "com.apple.Safari")],
            orphans: [],
            categoryBreakdown: [(.cache, 500, 1)]
        )
        XCTAssertFalse(graph.nodes.isEmpty)
        XCTAssertTrue(graph.nodes.contains { $0.kind == .volume })
    }

    func testOrphanMapperFindsUnmatchedSupport() {
        let home = NSHomeDirectory()
        let session = UUID()
        let entries = [
            FileEntry(
                sessionID: session,
                path: home + "/Library/Application Support/TotallyFakeAppXYZ",
                parentPath: home + "/Library/Application Support",
                name: "TotallyFakeAppXYZ",
                isDirectory: true,
                size: 5_000_000,
                allocatedSize: 5_000_000
            )
        ]
        let report = OrphanMapper().analyze(sessionID: session, home: home, entries: entries)
        XCTAssertTrue(report.orphans.contains { $0.name == "TotallyFakeAppXYZ" })
    }
}
