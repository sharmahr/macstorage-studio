import XCTest
import MacStorageCore

final class GuardrailTests: XCTestCase {
    func testSystemPathAlwaysProtected() {
        let g = SystemGuardrails.shared
        XCTAssertTrue(g.isProtected("/System/Library/CoreServices"))
        XCTAssertTrue(g.isProtected("/bin/zsh"))
        XCTAssertTrue(g.isProtected("/usr/lib/libSystem.B.dylib"))
        XCTAssertTrue(g.evaluation(for: "/System").isMandatory)
    }

    func testUserLibraryNotBlockedBySystemLibraryRule() {
        let g = SystemGuardrails.shared
        let homeLib = NSHomeDirectory() + "/Library/Caches"
        XCTAssertFalse(g.isProtected(homeLib) && g.evaluation(for: homeLib).matchedRuleIDs.contains("system-library"))
    }

    func testMandatoryCannotDisable() {
        let g = SystemGuardrails.shared
        let rule = g.catalog.first { $0.id == "os-system" }!
        g.setEnabled(rule, enabled: false)
        XCTAssertTrue(g.isEnabled(rule))
    }

    func testRecommendedToggle() {
        let g = SystemGuardrails.shared
        let rule = g.catalog.first { $0.id == "system-library" }!
        let previous = g.isEnabled(rule)
        g.setEnabled(rule, enabled: false)
        XCTAssertFalse(g.isEnabled(rule))
        g.setEnabled(rule, enabled: true)
        XCTAssertTrue(g.isEnabled(rule))
        g.setEnabled(rule, enabled: previous)
    }

    func testFilterRootsDropsSystem() {
        let roots = SystemGuardrails.shared.filterRoots(["/System", NSHomeDirectory(), "/Applications"])
        XCTAssertFalse(roots.contains("/System"))
        XCTAssertTrue(roots.contains(NSHomeDirectory()))
    }

    func testHomeIsScannableButNotDeletable() {
        let g = SystemGuardrails.shared
        let home = NSHomeDirectory()
        XCTAssertTrue(g.isDeleteProtected(home), "must not trash home root")
        XCTAssertFalse(g.isScanExcluded(home), "must scan home root")
        XCTAssertFalse(g.isScanExcluded(home + "/Documents"))
        XCTAssertTrue(g.isScanExcluded("/System/Library"))
        XCTAssertFalse(g.isScanExcluded("/Applications"))
    }
}
