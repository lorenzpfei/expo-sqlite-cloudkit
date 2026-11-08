import Foundation

struct Applier {
  enum Outcome: Equatable {
    case applied
    case keptLocal(PendingChange)
    case ignored
  }

  let db: SQLiteConnection
  let schema: SyncSchema
  let outbox: Outbox
  let systemFields: SystemFieldsStore

  func applySave(_ incoming: SyncRecord) throws -> Outcome {
    let id = incoming.id
    guard let table = schema.table(named: id.table), id.primaryKey.count == table.primaryKey.count else {
      return .ignored
    }
    if let data = incoming.systemFields {
      try systemFields.set(id, data)
    }
    let pending = try outbox.entry(for: id)
    if pending?.operation == .delete {
      return .keptLocal(.delete(id))
    }
    if let local = try row(for: id, in: table),
      Self.localWins(local: local, incoming: incoming.fields, table: table, pendingUpsert: pending != nil)
    {
      try outbox.enqueueUpsert(id)
      return .keptLocal(.save(id))
    }

    var names: [String] = []
    var values: [SyncValue] = []
    for column in try columns(of: table) {
      if let index = table.primaryKey.firstIndex(of: column.name) {
        values.append(.text(id.primaryKey[index]))
      } else if let value = incoming.fields[column.name] {
        values.append(value)
      } else if column.notNull {
        continue
      } else {
        values.append(.null)
      }
      names.append(column.name)
    }
    let updates = names.filter { !table.primaryKey.contains($0) }.map { "\(quote($0)) = excluded.\(quote($0))" }
    try db.execute(
      """
      INSERT INTO \(quote(table.name)) (\(names.map(quote).joined(separator: ", ")))
      VALUES (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))
      ON CONFLICT (\(table.primaryKey.map(quote).joined(separator: ", "))) \(updates.isEmpty ? "DO NOTHING" : "DO UPDATE SET \(updates.joined(separator: ", "))")
      """,
      values)
    try outbox.remove(id)
    return .applied
  }

  func applyDelete(_ id: RecordID) throws -> Bool {
    guard let table = schema.table(named: id.table), id.primaryKey.count == table.primaryKey.count else {
      return false
    }
    try db.execute("DELETE FROM \(quote(table.name)) WHERE \(keyCondition(table))", keyValues(id))
    try outbox.remove(id)
    try systemFields.remove(id)
    return true
  }

  func row(for id: RecordID, in table: SyncTable) throws -> Row? {
    try db.query("SELECT * FROM \(quote(table.name)) WHERE \(keyCondition(table))", keyValues(id)).first
  }

  static func localWins(local: Row, incoming: [String: SyncValue], table: SyncTable, pendingUpsert: Bool) -> Bool {
    let localTime = local[table.updatedAtColumn]?.timestamp ?? -.infinity
    let incomingTime = incoming[table.updatedAtColumn]?.timestamp ?? -.infinity
    if localTime != incomingTime { return localTime > incomingTime }
    if let deletedAt = table.deletedAtColumn {
      let localDeleted = !(local[deletedAt] ?? .null).isNull
      let incomingDeleted = !(incoming[deletedAt] ?? .null).isNull
      if localDeleted != incomingDeleted { return localDeleted }
    }
    return pendingUpsert
  }

  private func columns(of table: SyncTable) throws -> [(name: String, notNull: Bool)] {
    try db.query("SELECT name, \"notnull\" AS not_null FROM pragma_table_info(?)", [.text(table.name)]).compactMap { row in
      guard case .text(let name)? = row["name"] else { return nil }
      return (name, row["not_null"] == .integer(1))
    }
  }

  private func keyCondition(_ table: SyncTable) -> String {
    table.primaryKey.map { "\(quote($0)) = ?" }.joined(separator: " AND ")
  }

  private func keyValues(_ id: RecordID) -> [SyncValue] {
    id.primaryKey.map(SyncValue.text)
  }
}

func quote(_ identifier: String) -> String {
  "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
}
