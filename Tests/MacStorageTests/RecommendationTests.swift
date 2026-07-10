import XCTest
@testable import Recommendations
import MacStorageCore

final class RecommendationTests: XCTestCase {
    func testDerivedDataRecommendation() {
        let engine = RecommendationEngine()
        let sessionID = UUID()
        let entries = [
            FileEntry(
                sessionID: sessionID,
                path: "/Users/x/Library/Developer/Xcode/DerivedData",
                parentPath: "/Users/x/Library/Developer/Xcode",
                name: "DerivedData",
                isDirectory: true,
                size: 5_000_000_000,
                allocatedSize: 5_000_000_000,
                category: .developerCache
            )
        ]
        let recs = engine.recommendations(sessionID: sessionID, entries: entries, minimumBytes: 1_000_000)
        XCTAssertFalse(recs.isEmpty)
        XCTAssertEqual(recs[0].risk, .safe)
        XCTAssertTrue(recs[0].regenerable)
        XCTAssertFalse(recs[0].explanation.isEmpty)
        XCTAssertGreaterThan(recs[0].confidence, 0.5)
    }
}
