import SyncCore
import XCTest

final class CommitHealthTests: XCTestCase {
  func testCompositeKeysAcrossTablesSyncBetweenDevices() async throws {
    let fixture = try Fixture.load("commit-health")
    let server = InMemoryServer()
    let phone = try Device("phone", fixture: fixture, server: server, seed: [
      "INSERT INTO health_days (user_id, day, steps, updated_at) VALUES ('local', '2026-11-07', 9120, 1762500000)",
      "INSERT INTO sleep_days (user_id, day, core_ms, updated_at) VALUES ('local', '2026-11-07', 14400000, 1762500000)",
    ])
    let ipad = try Device("ipad", fixture: fixture, server: server)

    try phone.exec("INSERT INTO intake_items (user_id, id, name, unit, kind, important, updated_at) VALUES ('local', 'ibu', 'Ibuprofen', 'mg', 'medication', 1, 1762500100)")
    try phone.exec("INSERT INTO pain_episodes (user_id, id, type, day, started_at, notes, updated_at) VALUES ('local', 'p1', 'migraine', '2026-11-07', '2026-11-07T08:00:00Z', 'left side', 1762500200)")
    try phone.exec("INSERT INTO diary_entries (user_id, id, day, written_at, body, updated_at) VALUES ('local', 'd1', '2026-11-07', '2026-11-07T21:00:00Z', 'Long walk', 1762500300)")
    try await syncAll(phone, ipad)

    XCTAssertEqual(try ipad.rows("SELECT steps FROM health_days").first?["steps"], .integer(9120))
    XCTAssertEqual(try ipad.rows("SELECT core_ms FROM sleep_days").first?["core_ms"], .integer(14_400_000))
    XCTAssertEqual(try ipad.rows("SELECT important FROM intake_items WHERE id = 'ibu'").first?["important"], .integer(1))
    XCTAssertEqual(server.allRecords.count, 5)

    let pain = try XCTUnwrap(server.allRecords.first { $0.recordType == "pain_episodes" })
    XCTAssertEqual(pain.encryptedFields, ["notes"])
    let diary = try XCTUnwrap(server.allRecords.first { $0.recordType == "diary_entries" })
    XCTAssertEqual(diary.encryptedFields, Set(diary.fields.keys))

    try ipad.exec("UPDATE intake_items SET deleted_at = 1762600000, updated_at = 1762600000 WHERE id = 'ibu'")
    try ipad.exec("DELETE FROM diary_entries WHERE id = 'd1'")
    try await syncAll(ipad, phone)

    XCTAssertEqual(try phone.rows("SELECT deleted_at FROM intake_items WHERE id = 'ibu'").first?["deleted_at"], .integer(1_762_600_000))
    XCTAssertEqual(try phone.rows("SELECT count(*) AS n FROM diary_entries").first?["n"], .integer(0))
    XCTAssertEqual(try phone.outboxCount() + ipad.outboxCount(), 0)
  }
}
