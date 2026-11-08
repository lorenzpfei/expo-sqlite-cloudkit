import Foundation

public struct OutboxEntry: Hashable, Sendable {
  public enum Operation: String, Sendable {
    case upsert
    case delete
  }

  public let id: RecordID
  public let operation: Operation
  public let version: Int64
}

public struct Outbox {
  let db: SQLiteConnection

  public init(db: SQLiteConnection) {
    self.db = db
  }

  public func entries() throws -> [OutboxEntry] {
    try db.query("SELECT table_name, pk_json, op, version FROM _sync_outbox ORDER BY changed_at, table_name, pk_json")
      .compactMap(Self.entry)
  }

  public func entry(for id: RecordID) throws -> OutboxEntry? {
    try db.query(
      "SELECT table_name, pk_json, op, version FROM _sync_outbox WHERE table_name = ? AND pk_json = \(Self.jsonArray(id))",
      [.text(id.table)] + id.primaryKey.map(SyncValue.text)
    ).first.flatMap(Self.entry)
  }

  public func count() throws -> Int {
    guard case .integer(let count)? = try db.query("SELECT count(*) AS n FROM _sync_outbox").first?["n"] else { return 0 }
    return Int(count)
  }

  public func remove(_ id: RecordID, version: Int64? = nil) throws {
    var sql = "DELETE FROM _sync_outbox WHERE table_name = ? AND pk_json = \(Self.jsonArray(id))"
    var parameters = [SyncValue.text(id.table)] + id.primaryKey.map(SyncValue.text)
    if let version {
      sql += " AND version = ?"
      parameters.append(.integer(version))
    }
    try db.execute(sql, parameters)
  }

  public func enqueueUpsert(_ id: RecordID) throws {
    try db.execute(
      """
      INSERT INTO _sync_outbox (table_name, pk_json, op, changed_at)
      VALUES (?, \(Self.jsonArray(id)), 'upsert', CAST(unixepoch('subsec') * 1000 AS INTEGER))
      ON CONFLICT (table_name, pk_json) DO UPDATE SET op = 'upsert', changed_at = excluded.changed_at, version = version + 1
      """,
      [.text(id.table)] + id.primaryKey.map(SyncValue.text)
    )
  }

  private static func jsonArray(_ id: RecordID) -> String {
    "json_array(\(Array(repeating: "?", count: id.primaryKey.count).joined(separator: ", ")))"
  }

  private static func entry(_ row: Row) -> OutboxEntry? {
    guard
      case .text(let table)? = row["table_name"],
      case .text(let json)? = row["pk_json"],
      case .text(let op)? = row["op"],
      case .integer(let version)? = row["version"],
      let operation = OutboxEntry.Operation(rawValue: op),
      let keys = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
    else { return nil }
    return OutboxEntry(id: RecordID(table: table, primaryKey: keys), operation: operation, version: version)
  }
}

struct Metadata {
  let db: SQLiteConnection

  func value(_ key: String) throws -> String? {
    guard case .text(let value)? = try db.query("SELECT value FROM _sync_meta WHERE key = ?", [.text(key)]).first?["value"]
    else { return nil }
    return value
  }

  func set(_ key: String, _ value: String?) throws {
    if let value {
      try db.execute(
        "INSERT INTO _sync_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        [.text(key), .text(value)])
    } else {
      try db.execute("DELETE FROM _sync_meta WHERE key = ?", [.text(key)])
    }
  }
}

struct SystemFieldsStore {
  let db: SQLiteConnection

  func get(_ id: RecordID) throws -> Data? {
    guard case .blob(let data)? = try db.query(
      "SELECT system_fields FROM _sync_records WHERE record_name = ?", [.text(id.recordName)]
    ).first?["system_fields"] else { return nil }
    return data
  }

  func set(_ id: RecordID, _ data: Data?) throws {
    guard let data else { return try remove(id) }
    try db.execute(
      """
      INSERT INTO _sync_records (record_name, table_name, system_fields) VALUES (?, ?, ?)
      ON CONFLICT (record_name) DO UPDATE SET system_fields = excluded.system_fields
      """,
      [.text(id.recordName), .text(id.table), .blob(data)])
  }

  func remove(_ id: RecordID) throws {
    try db.execute("DELETE FROM _sync_records WHERE record_name = ?", [.text(id.recordName)])
  }

  func removeAll() throws {
    try db.execute("DELETE FROM _sync_records")
  }
}
