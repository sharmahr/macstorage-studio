import XCTest
@testable import MetadataStore
import MacStorageCore

final class MetadataStoreTests: XCTestCase {
    func testSessionAndEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mss-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try MetadataStore(databaseURL: url)
        let session = ScanSession(roots: ["/tmp"])
        try store.upsertSession(session)

        let entry = FileEntry(
            sessionID: session.id,
            path: "/tmp/foo.txt",
            parentPath: "/tmp",
            name: "foo.txt",
            isDirectory: false,
            size: 1234,
            allocatedSize: 4096,
            fileExtension: "txt",
            category: .documents
        )
        try store.insertEntries([entry])

        let children = try store.children(sessionID: session.id, parentPath: "/tmp")
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0].size, 1234)

        let latest = try store.latestSession()
        XCTAssertEqual(latest?.id, session.id)
    }

    func testDirectoryRollup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mss-rollup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MetadataStore(databaseURL: url)
        let session = ScanSession(roots: ["/tmp/tree"])
        try store.upsertSession(session)
        try store.insertEntries([
            FileEntry(sessionID: session.id, path: "/tmp/tree", parentPath: "/tmp", name: "tree", isDirectory: true, size: 0, allocatedSize: 0),
            FileEntry(sessionID: session.id, path: "/tmp/tree/a.txt", parentPath: "/tmp/tree", name: "a.txt", isDirectory: false, size: 100, allocatedSize: 100),
            FileEntry(sessionID: session.id, path: "/tmp/tree/b.txt", parentPath: "/tmp/tree", name: "b.txt", isDirectory: false, size: 50, allocatedSize: 50),
        ])
        try store.rollupDirectorySizes(sessionID: session.id)
        let found = try store.search(sessionID: session.id, query: "tree")
        let dir = found.first { $0.path == "/tmp/tree" }
        XCTAssertEqual(dir?.size, 150)
    }
}
