#if canImport(CloudKit)
import CloudKit
import SyncCloudKit
import SyncCore
import XCTest

final class CloudKitRecordMapperTests: XCTestCase {
  private let id = RecordID(table: "pain_episodes", primaryKey: ["local", "p1"])

  private func sample() -> SyncRecord {
    SyncRecord(
      id: id,
      fields: [
        "user_id": .text("local"),
        "id": .text("p1"),
        "intensity": .integer(7),
        "duration_hours": .real(1.5),
        "notes": .text("left side"),
        "photo": .blob(Data([0, 1, 2])),
        "ended_at": .null,
      ],
      encryptedFields: ["notes"])
  }

  func testRecordUsesTableAsTypeAndCustomZone() {
    let record = CloudKitRecordMapper.record(sample())
    XCTAssertEqual(record.recordType, "pain_episodes")
    XCTAssertEqual(record.recordID.recordName, "pain_episodes|local|p1")
    XCTAssertEqual(record.recordID.zoneID.zoneName, "SQLiteSync")
  }

  func testFieldsRoundTripWithTheirTypes() throws {
    let record = CloudKitRecordMapper.record(sample())
    XCTAssertEqual(record["intensity"] as? Int64, 7)
    XCTAssertNil(record["ended_at"])
    XCTAssertNil(record["notes"] as? String)
    XCTAssertEqual(record.encryptedValues["notes"] as? String, "left side")

    let decoded = try XCTUnwrap(CloudKitRecordMapper.syncRecord(record))
    var expected = sample().fields
    expected["ended_at"] = nil
    XCTAssertEqual(decoded.fields, expected)
    XCTAssertEqual(decoded.encryptedFields, ["notes"])
    XCTAssertEqual(decoded.id, id)
  }

  func testIntegralDoublesStayReal() {
    XCTAssertEqual(CloudKitRecordMapper.syncValue(NSNumber(value: 72.0)), .real(72))
    XCTAssertEqual(CloudKitRecordMapper.syncValue(NSNumber(value: Int64(72))), .integer(72))
  }

  func testNullClearsAPreviouslySetField() {
    var record = sample()
    record.fields["intensity"] = .null
    let ckRecord = CloudKitRecordMapper.record(record)
    XCTAssertTrue(ckRecord.changedKeys().contains("intensity"))
    XCTAssertNil(ckRecord["intensity"])
  }

  func testSystemFieldsKeepTheRecordIdentity() throws {
    let original = CloudKitRecordMapper.record(sample())
    var record = sample()
    record.systemFields = CloudKitRecordMapper.encodeSystemFields(original)
    let restored = CloudKitRecordMapper.record(record)
    XCTAssertEqual(restored.recordID, original.recordID)
    XCTAssertEqual(restored["intensity"] as? Int64, 7)
  }

  func testSystemFieldsOfAnotherRecordAreIgnored() {
    let other = CloudKitRecordMapper.record(
      SyncRecord(id: RecordID(table: "pain_episodes", primaryKey: ["local", "p2"]), fields: [:]))
    var record = sample()
    record.systemFields = CloudKitRecordMapper.encodeSystemFields(other)
    XCTAssertEqual(CloudKitRecordMapper.record(record).recordID.recordName, "pain_episodes|local|p1")
  }

  func testRecordsFromForeignTypesAreSkipped() {
    let foreign = CKRecord(recordType: "Other", recordID: CKRecord.ID(recordName: "pain_episodes|local|p1"))
    XCTAssertNil(CloudKitRecordMapper.syncRecord(foreign))
    let unparsable = CKRecord(recordType: "notes", recordID: CKRecord.ID(recordName: "no-separator"))
    XCTAssertNil(CloudKitRecordMapper.syncRecord(unparsable))
  }
}

final class CloudKitErrorPolicyTests: XCTestCase {
  func testServerRecordChangedCarriesTheServerCopy() throws {
    let server = CKRecord(recordType: "notes", recordID: CKRecord.ID(recordName: "notes|n1"))
    server["title"] = "Server" as NSString
    let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
    guard case .serverRecordChanged(let record) = CloudKitErrorPolicy.failure(for: error) else {
      return XCTFail("expected serverRecordChanged")
    }
    XCTAssertEqual(record.fields["title"], .text("Server"))
    XCTAssertNotNil(record.systemFields)
  }

  func testServerRecordChangedWithoutServerCopyIsRetried() {
    XCTAssertEqual(CloudKitErrorPolicy.failure(for: CKError(.serverRecordChanged)), .retryLater)
  }

  func testErrorCodesMapToDecisions() {
    let expectations: [(CKError.Code, SendFailure)] = [
      (.zoneNotFound, .zoneNotFound),
      (.userDeletedZone, .zoneNotFound),
      (.unknownItem, .unknownItem),
      (.quotaExceeded, .quotaExceeded),
      (.networkFailure, .retryLater),
      (.networkUnavailable, .retryLater),
      (.serviceUnavailable, .retryLater),
      (.requestRateLimited, .retryLater),
      (.zoneBusy, .retryLater),
      (.notAuthenticated, .retryLater),
      (.batchRequestFailed, .retryLater),
    ]
    for (code, failure) in expectations {
      XCTAssertEqual(CloudKitErrorPolicy.failure(for: CKError(code)), failure, "\(code)")
    }
  }

  func testOnlyPartialFailuresAreReportedPerRecord() {
    XCTAssertTrue(CloudKitErrorPolicy.isReportedPerRecord(CKError(.partialFailure)))
    XCTAssertFalse(CloudKitErrorPolicy.isReportedPerRecord(CKError(.networkFailure)))
    XCTAssertFalse(CloudKitErrorPolicy.isReportedPerRecord(CocoaError(.fileNoSuchFile)))
  }

  func testUnexpectedErrorsAreRejectedWithAMessage() {
    guard case .rejected(let message) = CloudKitErrorPolicy.failure(for: CKError(.invalidArguments)) else {
      return XCTFail("expected rejected")
    }
    XCTAssertTrue(message.contains("CloudKit error 12"), message)
  }
}
#endif
