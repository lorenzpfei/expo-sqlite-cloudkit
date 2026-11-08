import Foundation

public struct RecordID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let table: String
  public let primaryKey: [String]

  public init(table: String, primaryKey: [String]) {
    self.table = table
    self.primaryKey = primaryKey
  }

  public init?(recordName: String) {
    let parts = recordName.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else { return nil }
    let decoded = parts.compactMap { $0.removingPercentEncoding }
    guard decoded.count == parts.count, !decoded[0].isEmpty else { return nil }
    self.table = decoded[0]
    self.primaryKey = Array(decoded.dropFirst())
  }

  public var recordName: String {
    ([table] + primaryKey).map(RecordCodec.escape).joined(separator: "|")
  }

  public var description: String { recordName }
}

public struct SyncRecord: Equatable, Sendable {
  public var id: RecordID
  public var fields: [String: SyncValue]
  public var encryptedFields: Set<String>
  public var systemFields: Data?

  public init(id: RecordID, fields: [String: SyncValue], encryptedFields: Set<String> = [], systemFields: Data? = nil) {
    self.id = id
    self.fields = fields
    self.encryptedFields = encryptedFields
    self.systemFields = systemFields
  }

  public var recordType: String { id.table }
}

public enum RecordCodec {
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  public static func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }

  public static func record(id: RecordID, row: Row, table: SyncTable, systemFields: Data?) -> SyncRecord {
    let encrypted = Set(row.keys.filter { table.encryptedColumns.contains($0) })
    return SyncRecord(id: id, fields: row, encryptedFields: encrypted, systemFields: systemFields)
  }
}
