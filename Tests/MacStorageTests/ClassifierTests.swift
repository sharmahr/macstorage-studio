import XCTest
@testable import Classifier
import MacStorageCore

final class ClassifierTests: XCTestCase {
    let classifier = StorageClassifier()

    func testDerivedData() {
        let cat = classifier.classify(
            path: "/Users/x/Library/Developer/Xcode/DerivedData/Foo",
            isDirectory: true,
            fileExtension: nil,
            isPackage: false
        )
        XCTAssertEqual(cat, .developerCache)
    }

    func testNodeModules() {
        let cat = classifier.classify(
            path: "/Users/x/Projects/app/node_modules",
            isDirectory: true,
            fileExtension: nil,
            isPackage: false
        )
        XCTAssertEqual(cat, .buildArtifacts)
    }

    func testImage() {
        let cat = classifier.classify(
            path: "/Users/x/Pictures/a.heic",
            isDirectory: false,
            fileExtension: "heic",
            isPackage: false
        )
        XCTAssertEqual(cat, .images)
    }

    func testBrowserCache() {
        let cat = classifier.classify(
            path: "/Users/x/Library/Caches/Google/Chrome/Default/Cache",
            isDirectory: true,
            fileExtension: nil,
            isPackage: false
        )
        XCTAssertEqual(cat, .browserCache)
    }
}
