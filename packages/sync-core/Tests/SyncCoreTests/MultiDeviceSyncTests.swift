import Foundation
import SyncCore
import XCTest

final class MultiDeviceSyncTests: XCTestCase {
  private var server: InMemoryServer!
  private var notes: Fixture!

  override func setUpWithError() throws {
    server = InMemoryServer()
    notes = try Fixture.load("notes")
  }

  private func device(_ name: String, seed: [String] = []) throws -> Device {
    try Device(name, fixture: notes, server: server, seed: seed)
  }

  private func titles(_ device: Device) throws -> [String] {
    try device.rows("SELECT id, title FROM notes ORDER BY id").map { row in
      guard case .text(let id)? = row["id"], case .text(let title)? = row["title"] else { return "?" }
      return "\(id):\(title)"
    }
  }

  func testInsertReachesOtherDevices() async throws {
    let a = try device("a")
    let b = try device("b")
    let c = try device("c")
    try a.exec("INSERT INTO notes (id, title, body, updated_at) VALUES ('n1', 'Groceries', 'Milk', 1)")

    try await syncAll(a, b, c)

    XCTAssertEqual(try titles(b), ["n1:Groceries"])
    XCTAssertEqual(try titles(c), ["n1:Groceries"])
    XCTAssertEqual(try a.outboxCount(), 0)
    XCTAssertEqual(try b.outboxCount(), 0)
    XCTAssertEqual(b.changedTables, [["notes"]])
  }

  func testConcurrentEditsKeepTheNewestUpdatedAt() async throws {
    let a = try device("a")
    let b = try device("b")
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Draft', 1)")
    try await syncAll(a, b)

    try a.exec("UPDATE notes SET title = 'From A', updated_at = 30 WHERE id = 'n1'")
    try b.exec("UPDATE notes SET title = 'From B', updated_at = 20 WHERE id = 'n1'")
    try await syncAll(b, a)

    XCTAssertEqual(try titles(a), ["n1:From A"])
    XCTAssertEqual(try titles(b), ["n1:From A"])

    try a.exec("UPDATE notes SET title = 'A again', updated_at = 40 WHERE id = 'n1'")
    try b.exec("UPDATE notes SET title = 'B wins', updated_at = 50 WHERE id = 'n1'")
    try await syncAll(a, b)

    XCTAssertEqual(try titles(a), ["n1:B wins"])
    XCTAssertEqual(try titles(b), ["n1:B wins"])
    XCTAssertEqual(try a.outboxCount() + b.outboxCount(), 0)
  }

  func testEqualTimestampsConvergeOnTheLastSyncedEdit() async throws {
    let a = try device("a")
    let b = try device("b")
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Draft', 1)")
    try await syncAll(a, b)

    try a.exec("UPDATE notes SET title = 'From A', updated_at = 7 WHERE id = 'n1'")
    try b.exec("UPDATE notes SET title = 'From B', updated_at = 7 WHERE id = 'n1'")
    try await syncAll(a, b)

    XCTAssertEqual(try titles(a), try titles(b))
    XCTAssertEqual(try titles(a), ["n1:From B"])
  }

  func testAPendingEditInTheSameSecondSurvivesItsOwnEcho() async throws {
    let a = try device("a")
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'First', 5)")
    try await a.sync()
    try a.exec("UPDATE notes SET title = 'Second', updated_at = 5 WHERE id = 'n1'")
    try await a.sync()

    XCTAssertEqual(try titles(a), ["n1:Second"])
    XCTAssertEqual(server.allRecords.first?.fields["title"], .text("Second"))
  }

  func testHardDeleteWinsOverConcurrentEdit() async throws {
    for deleterSyncsFirst in [true, false] {
      server = InMemoryServer()
      let a = try device("a")
      let b = try device("b")
      try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Shared', 1)")
      try await syncAll(a, b)

      try a.exec("DELETE FROM notes WHERE id = 'n1'")
      try b.exec("UPDATE notes SET title = 'Edited later', updated_at = 99 WHERE id = 'n1'")
      if deleterSyncsFirst {
        try await syncAll(a, b)
      } else {
        try await syncAll(b, a)
      }

      XCTAssertEqual(try titles(a), [], "deleter first: \(deleterSyncsFirst)")
      XCTAssertEqual(try titles(b), [], "deleter first: \(deleterSyncsFirst)")
      XCTAssertEqual(server.allRecords, [])
      XCTAssertEqual(try a.outboxCount() + b.outboxCount(), 0)
    }
  }

  func testSoftDeleteIsAnUpdateThatWinsTies() async throws {
    let a = try device("a")
    let b = try device("b")
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Shared', 1)")
    try await syncAll(a, b)

    try a.exec("UPDATE notes SET deleted_at = 9, updated_at = 9 WHERE id = 'n1'")
    try b.exec("UPDATE notes SET title = 'Same second', updated_at = 9 WHERE id = 'n1'")
    try await syncAll(b, a)

    for device in [a, b] {
      let row = try XCTUnwrap(device.rows("SELECT deleted_at FROM notes WHERE id = 'n1'").first)
      XCTAssertEqual(row["deleted_at"], .integer(9), device.name)
    }
  }

  func testOfflineChangesQueueUntilTheNextSync() async throws {
    let a = try device("a")
    let b = try device("b")
    a.transport.isOnline = false
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'One', 1), ('n2', 'Two', 1), ('n3', 'Three', 1)")
    try a.exec("UPDATE notes SET title = 'Two edited', updated_at = 2 WHERE id = 'n2'")
    try a.exec("DELETE FROM notes WHERE id = 'n3'")

    do {
      try await a.sync()
      XCTFail("sync should fail while offline")
    } catch {
      XCTAssertEqual(error as? InMemoryTransportError, .offline)
    }
    XCTAssertEqual(try a.outboxCount(), 3)

    try a.restart()
    try await syncAll(a, b)

    XCTAssertEqual(try titles(b), ["n1:One", "n2:Two edited"])
    XCTAssertEqual(try a.outboxCount(), 0)
  }

  func testDevicesWithExistingDataMergeOnFirstSync() async throws {
    let a = try device("a", seed: ["INSERT INTO notes (id, title, updated_at) VALUES ('a1', 'Only on A', 1), ('shared', 'A copy', 10)"])
    let b = try device("b", seed: ["INSERT INTO notes (id, title, updated_at) VALUES ('b1', 'Only on B', 1), ('shared', 'B copy', 20)"])
    XCTAssertEqual(try a.outboxCount(), 2)

    try await syncAll(a, b)

    XCTAssertEqual(try titles(a), ["a1:Only on A", "b1:Only on B", "shared:B copy"])
    XCTAssertEqual(try titles(b), try titles(a))
    XCTAssertEqual(server.allRecords.count, 3)
  }

  func testColumnAddedLaterOnOneDevice() async throws {
    let a = try device("a")
    let b = try device("b")
    try a.exec("ALTER TABLE notes ADD COLUMN color TEXT")
    try a.exec("ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
    try a.exec("INSERT INTO notes (id, title, updated_at, color, pinned) VALUES ('n1', 'Colored', 1, 'red', 1)")
    try await syncAll(a, b)

    XCTAssertEqual(try titles(b), ["n1:Colored"])
    XCTAssertNil(try b.rows("SELECT * FROM notes").first?["color"])

    try b.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n2', 'Old app', 2)")
    try await syncAll(b, a)
    let fromOldApp = try XCTUnwrap(a.rows("SELECT color, pinned FROM notes WHERE id = 'n2'").first)
    XCTAssertEqual(fromOldApp["color"], .null)
    XCTAssertEqual(fromOldApp["pinned"], .integer(0))

    try b.exec("ALTER TABLE notes ADD COLUMN color TEXT")
    try a.exec("UPDATE notes SET color = 'blue', updated_at = 3 WHERE id = 'n1'")
    try await syncAll(a, b)
    XCTAssertEqual(try b.rows("SELECT color FROM notes WHERE id = 'n1'").first?["color"], .text("blue"))
  }

  func testLargeBatchOfFiveThousandRows() async throws {
    let a = try device("a")
    let b = try device("b")
    try a.db.transaction {
      for index in 0..<5_000 {
        try a.exec(
          "INSERT INTO notes (id, title, body, updated_at) VALUES (?, ?, ?, 1)",
          [.text(String(format: "n%05d", index)), .text("Note \(index)"), .text(String(repeating: "x", count: 200))])
      }
    }

    try await syncAll(a, b)

    XCTAssertEqual(try b.rows("SELECT count(*) AS n FROM notes").first?["n"], .integer(5_000))
    XCTAssertEqual(server.allRecords.count, 5_000)
    XCTAssertEqual(try a.outboxCount(), 0)
    XCTAssertEqual(try b.outboxCount(), 0)
  }

  func testFailureInTheMiddleOfABatchIsRetried() async throws {
    let a = try device("a")
    let b = try device("b")
    try a.db.transaction {
      for index in 0..<1_000 {
        try a.exec("INSERT INTO notes (id, title, updated_at) VALUES (?, 'x', 1)", [.text(String(format: "n%04d", index))])
      }
    }
    server.failSavesAfter = 150

    do {
      try await a.sync()
      XCTFail("sync should report the partial failure")
    } catch {
      XCTAssertEqual(error as? InMemoryTransportError, .retryLater)
    }
    XCTAssertEqual(server.allRecords.count, 150)
    XCTAssertEqual(try a.outboxCount(), 850)

    try await syncAll(a, b)

    XCTAssertEqual(server.allRecords.count, 1_000)
    XCTAssertEqual(try a.outboxCount(), 0)
    XCTAssertEqual(try b.rows("SELECT count(*) AS n FROM notes").first?["n"], .integer(1_000))
  }

  func testEditWhileARecordIsInFlightIsNotLost() async throws {
    let a = try device("a")
    let b = try device("b")
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Sent', 1)")
    server.beforeModify = { [unowned a] in
      try? a.exec("UPDATE notes SET title = 'Typed during upload', updated_at = 2 WHERE id = 'n1'")
    }
    try await a.sync()
    server.beforeModify = nil

    XCTAssertEqual(try a.outboxCount(), 1)
    try await syncAll(a, b)
    XCTAssertEqual(try titles(b), ["n1:Typed during upload"])
  }

  func testRestartResumesFromThePersistedChangeToken() async throws {
    let a = try device("a")
    let b = try device("b")
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'One', 1)")
    try await syncAll(a, b)
    XCTAssertEqual(b.changedTables.count, 1)

    try b.restart()
    try await b.sync()
    XCTAssertEqual(b.changedTables.count, 1)

    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n2', 'Two', 1)")
    try await syncAll(a, b)
    XCTAssertEqual(try titles(b), ["n1:One", "n2:Two"])
    XCTAssertEqual(b.changedTables.count, 2)
  }

  func testSignOutKeepsLocalDataAndSignInResumes() async throws {
    let a = try device("a")
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Kept', 1)")
    XCTAssertEqual(try a.coordinator.handleAccountChange(.signIn(userID: "alice")), .resume)
    try await a.sync()

    XCTAssertEqual(try a.coordinator.handleAccountChange(.signOut), .pause)
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n2', 'Offline', 1)")
    XCTAssertEqual(try titles(a), ["n1:Kept", "n2:Offline"])
    XCTAssertEqual(try a.outboxCount(), 1)

    XCTAssertEqual(try a.coordinator.handleAccountChange(.signIn(userID: "alice")), .resume)
    try await a.sync()
    XCTAssertEqual(server.allRecords.count, 2)
  }

  func testDifferentAccountResetsSyncStateAndUploadsEverything() async throws {
    let a = try device("a")
    try a.exec("INSERT INTO notes (id, title, updated_at) VALUES ('n1', 'Mine', 1), ('n2', 'Also mine', 1)")
    _ = try a.coordinator.handleAccountChange(.signIn(userID: "alice"))
    try await a.sync()
    XCTAssertEqual(try a.outboxCount(), 0)

    _ = try a.coordinator.handleAccountChange(.signOut)
    XCTAssertEqual(try a.coordinator.handleAccountChange(.signIn(userID: "bob")), .resetAndReupload)
    XCTAssertEqual(try a.outboxCount(), 2)
    XCTAssertNil(try a.coordinator.savedTransportState())

    let bobServer = InMemoryServer()
    try a.switchServer(to: bobServer)
    try await a.sync()
    XCTAssertEqual(bobServer.allRecords.count, 2)
    XCTAssertEqual(try titles(a), ["n1:Mine", "n2:Also mine"])
    XCTAssertEqual(try a.coordinator.handleAccountChange(.switchAccounts(userID: "carol")), .resetAndReupload)
  }

  func testEncryptedColumnsAreMarked() async throws {
    let a = try device("a")
    try a.exec("INSERT INTO notes (id, title, body, updated_at) VALUES ('n1', 'Public title', 'Secret body', 1)")
    try await a.sync()

    let record = try XCTUnwrap(server.allRecords.first)
    XCTAssertEqual(record.encryptedFields, ["body"])
    XCTAssertEqual(record.recordType, "notes")
    XCTAssertEqual(record.id.recordName, "notes|n1")
  }
}
