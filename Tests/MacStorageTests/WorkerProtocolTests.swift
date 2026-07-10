import XCTest
import MacStorageCore

final class WorkerProtocolTests: XCTestCase {
    func testRoundTrip() throws {
        let messages: [WorkerMessage] = [
            .hello(version: 1),
            .progress(scanned: 10, bytes: 100, path: "/tmp", skippedSystem: 3, skippedPermission: 1),
            .done(scanned: 10, bytes: 100, errors: 0, checkpoint: "/tmp/x"),
            .error(message: "nope", recoverable: true),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for message in messages {
            let data = try encoder.encode(message)
            let decoded = try decoder.decode(WorkerMessage.self, from: data)
            XCTAssertEqual(decoded, message)
        }
    }
}
