import XCTest
@testable import Solas

final class ModelStoreTests: XCTestCase {
    func testCuratePutsFreeDefaultFirstAndCapsAt12() {
        var all = [ModelStore.freeDefault]
        for i in 0..<20 { all.append("opencode/model-\(i)-free") }
        all.append("some/paid-model")
        let curated = ModelStore.curate(all)
        XCTAssertEqual(curated.first, ModelStore.freeDefault)
        XCTAssertLessThanOrEqual(curated.count, 12)
        XCTAssertFalse(curated.contains("some/paid-model"))
    }

    func testCurateWithoutFreeDefault() {
        let curated = ModelStore.curate(["a/spark-x", "b/paid"])
        XCTAssertTrue(curated.contains("a/spark-x"))
        XCTAssertFalse(curated.contains("b/paid"))
    }

    func testDisplayName() {
        XCTAssertEqual(ModelStore.displayName(for: "opencode/muse-spark-1.3-contributor-free"), "Muse Spark 1.3")
        XCTAssertEqual(ModelStore.displayName(for: "provider/gpt-4-free"), "Gpt 4")
    }

    func testIsFreeTier() {
        XCTAssertTrue(ModelStore.isFreeTier("opencode/muse-spark-1.3-contributor-free"))
        XCTAssertTrue(ModelStore.isFreeTier("x/zen-model"))
        XCTAssertFalse(ModelStore.isFreeTier("openai/gpt-4"))
    }
}
