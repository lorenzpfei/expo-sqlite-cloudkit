import SyncCore
import XCTest

final class RecordCodecTests: XCTestCase {
  func testRecordNameJoinsTableAndEscapedKeys() {
    let id = RecordID(table: "intake_items", primaryKey: ["local", "a|b%c/ü 1"])
    XCTAssertEqual(id.recordName, "intake_items|local|a%7Cb%25c%2F%C3%BC%201")
    XCTAssertEqual(RecordID(recordName: id.recordName), id)
  }

  func testRecordNameIsAsciiAndRoundTripsEmptyKeys() {
    let id = RecordID(table: "notes", primaryKey: ["", "😀"])
    XCTAssertTrue(id.recordName.allSatisfy(\.isASCII))
    XCTAssertEqual(RecordID(recordName: id.recordName), id)
  }

  func testTablesWithTheSameKeyGetDistinctNames() {
    let health = RecordID(table: "health_days", primaryKey: ["local", "2026-11-07"])
    let sleep = RecordID(table: "sleep_days", primaryKey: ["local", "2026-11-07"])
    XCTAssertNotEqual(health.recordName, sleep.recordName)
  }

  func testMalformedRecordNamesAreRejected() {
    XCTAssertNil(RecordID(recordName: "notes"))
    XCTAssertNil(RecordID(recordName: "|n1"))
    XCTAssertNil(RecordID(recordName: "notes|%E0%A4%A"))
  }

  func testEncryptedColumnsDecodeFromBothShapes() throws {
    let all = try JSONDecoder().decode([EncryptedColumns].self, from: Data(#"["all", ["body"], []]"#.utf8))
    XCTAssertEqual(all, [.all, .some(["body"]), .some([])])
    XCTAssertTrue(EncryptedColumns.all.contains("anything"))
    XCTAssertFalse(EncryptedColumns.some(["body"]).contains("title"))
  }
}
