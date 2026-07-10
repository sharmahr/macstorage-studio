import XCTest
import MacStorageCore

final class AccessTests: XCTestCase {
    func testFullAccessRootsIncludeApplications() {
        let roots = VolumeEnumerator.fullAccessScanRoots()
        XCTAssertTrue(roots.contains(NSHomeDirectory()) || roots.contains { $0 == NSHomeDirectory() })
        // /Applications exists on all Macs
        XCTAssertTrue(roots.contains("/Applications") || roots.contains { $0.hasPrefix("/Applications") } || FileManager.default.fileExists(atPath: "/Applications") == false || roots.contains("/Applications"))
        XCTAssertTrue(roots.contains("/Applications") || !FileManager.default.fileExists(atPath: "/Applications"))
    }

    func testAllowAllPreferenceRoundTrip() {
        let c = AccessController.shared
        let previous = c.allowAllAccess
        c.allowAllAccess = true
        XCTAssertTrue(AccessController.shared.allowAllAccess)
        c.allowAllAccess = false
        XCTAssertFalse(AccessController.shared.allowAllAccess)
        c.allowAllAccess = previous
    }
}
