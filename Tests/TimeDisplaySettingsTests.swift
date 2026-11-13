import XCTest

final class TimeDisplaySettingsTests: XCTestCase {
    func testLegacySnapshotKeepsSecondsEnabled() throws {
        let data = Data(#"{"accounts":[],"generatedAt":"2026-11-13T12:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(QuotaSnapshot.self, from: data)
        XCTAssertNil(snapshot.showSeconds)
        XCTAssertTrue(snapshot.showSeconds ?? true)
    }

    func testSnapshotPreservesBothSecondsChoices() throws {
        for enabled in [false, true] {
            let snapshot = QuotaSnapshot(accounts: [], generatedAt: Date(), showSeconds: enabled)
            let data = try JSONEncoder().encode(snapshot)
            XCTAssertEqual(try JSONDecoder().decode(QuotaSnapshot.self, from: data).showSeconds, enabled)
        }
    }
}
