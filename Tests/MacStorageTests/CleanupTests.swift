import XCTest
@testable import CleanupEngine

final class CleanupTests: XCTestCase {
    func testProtectsRootAndHome() {
        let engine = CleanupEngine()
        XCTAssertTrue(engine.isProtected("/"))
        XCTAssertTrue(engine.isProtected("/System"))
        XCTAssertTrue(engine.isProtected(NSHomeDirectory()))
    }

    func testTrashTempFile() throws {
        let engine = CleanupEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mss-trash-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        let result = try engine.trash(path: url.path, reclaimableBytes: 5)
        XCTAssertEqual(result.bytesReclaimed, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
