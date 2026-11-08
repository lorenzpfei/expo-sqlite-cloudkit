#if canImport(CloudKit)
import CloudKit
#if canImport(SyncCore)
import SyncCore
#endif

public enum CloudKitRecordMapper {
  public static let zoneID = CKRecordZone.ID(zoneName: "SQLiteSync", ownerName: CKCurrentUserDefaultName)

  public static func recordID(_ id: RecordID, zoneID: CKRecordZone.ID = zoneID) -> CKRecord.ID {
    CKRecord.ID(recordName: id.recordName, zoneID: zoneID)
  }

  public static func record(_ record: SyncRecord, zoneID: CKRecordZone.ID = zoneID) -> CKRecord {
    let ckRecordID = recordID(record.id, zoneID: zoneID)
    let ckRecord = record.systemFields
      .flatMap(decodeSystemFields)
      .flatMap { $0.recordID == ckRecordID && $0.recordType == record.recordType ? $0 : nil }
      ?? CKRecord(recordType: record.recordType, recordID: ckRecordID)
    for (key, value) in record.fields {
      if record.encryptedFields.contains(key) {
        ckRecord.encryptedValues[key] = ckValue(value)
      } else {
        ckRecord[key] = ckValue(value)
      }
    }
    return ckRecord
  }

  public static func syncRecord(_ ckRecord: CKRecord) -> SyncRecord? {
    guard let id = RecordID(recordName: ckRecord.recordID.recordName), id.table == ckRecord.recordType else {
      return nil
    }
    let encryptedKeys = Set(ckRecord.encryptedValues.allKeys())
    var fields: [String: SyncValue] = [:]
    for key in Set(ckRecord.allKeys()).subtracting(encryptedKeys) {
      fields[key] = syncValue(ckRecord[key])
    }
    for key in encryptedKeys {
      fields[key] = syncValue(ckRecord.encryptedValues[key])
    }
    return SyncRecord(
      id: id,
      fields: fields.compactMapValues { $0 },
      encryptedFields: encryptedKeys,
      systemFields: encodeSystemFields(ckRecord))
  }

  public static func ckValue(_ value: SyncValue) -> CKRecordValue? {
    switch value {
    case .null: return nil
    case .integer(let number): return NSNumber(value: number)
    case .real(let number): return NSNumber(value: number)
    case .text(let text): return text as NSString
    case .blob(let data): return data as NSData
    }
  }

  public static func syncValue(_ value: CKRecordValue?) -> SyncValue? {
    switch value {
    case let number as NSNumber:
      return CFNumberIsFloatType(number) ? .real(number.doubleValue) : .integer(number.int64Value)
    case let text as String:
      return .text(text)
    case let data as Data:
      return .blob(data)
    case nil:
      return .null
    default:
      return nil
    }
  }

  public static func encodeSystemFields(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  public static func decodeSystemFields(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    defer { coder.finishDecoding() }
    return CKRecord(coder: coder)
  }
}

public enum CloudKitErrorPolicy {
  public static func isReportedPerRecord(_ error: Error) -> Bool {
    (error as? CKError)?.code == .partialFailure
  }

  public static func failure(for error: Error) -> SendFailure {
    guard let error = error as? CKError else { return .rejected("\(error)") }
    switch error.code {
    case .serverRecordChanged:
      guard let server = error.serverRecord.flatMap(CloudKitRecordMapper.syncRecord) else { return .retryLater }
      return .serverRecordChanged(server)
    case .zoneNotFound, .userDeletedZone:
      return .zoneNotFound
    case .unknownItem:
      return .unknownItem
    case .quotaExceeded:
      return .quotaExceeded
    case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy,
      .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled, .batchRequestFailed:
      return .retryLater
    default:
      return .rejected("CloudKit error \(error.code.rawValue): \(error.localizedDescription)")
    }
  }
}
#endif
