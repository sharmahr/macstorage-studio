import XCTest
@testable import ScannerClient
import MacStorageCore

final class ScannerIsolationTests: XCTestCase {
    func testWorkerCrashDoesNotAbortHost() async throws {
        guard let worker = ScannerClient.locateWorker() else {
            throw XCTSkip("ScannerWorker not built — run swift build first")
        }
        let client = ScannerClient(workerURL: worker)
        do {
            try await client.runCrashTest()
            XCTFail("Expected worker crash error")
        } catch let error as ScannerClientError {
            guard case .workerCrashed = error else {
                XCTFail("Unexpected error \(error)")
                return
            }
            // Host process reached here — isolation works
            XCTAssertTrue(true)
        }
    }

    func testWorkerScansTempDirectory() async throws {
        guard let worker = ScannerClient.locateWorker() else {
            throw XCTSkip("ScannerWorker not built")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mss-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = ScannerClient(workerURL: worker)
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let counter = Counter()
        let result = try await client.scan(roots: [dir.path], maxWorkerRestarts: 0) { _ in
            counter.value += 1
        }
        XCTAssertGreaterThanOrEqual(result.scanned, 1)
        XCTAssertGreaterThanOrEqual(counter.value, 1)
    }
}
