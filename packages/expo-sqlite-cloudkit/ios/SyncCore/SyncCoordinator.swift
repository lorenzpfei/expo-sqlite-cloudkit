import Foundation

public final class SyncCoordinator: CloudTransportDelegate, @unchecked Sendable {
  public let schema: SyncSchema
  public var onTablesChanged: ((Set<String>) -> Void)?
  public private(set) var lastError: String?
  public private(set) weak var transport: CloudTransport?

  private let db: SQLiteConnection
  private let outbox: Outbox
  private let metadata: Metadata
  private let systemFields: SystemFieldsStore
  private let lock = NSRecursiveLock()
  private var inflight: [RecordID: Int64] = [:]

  private static let stateKey = "engine_state"
  private static let accountKey = "account_user"

  public init(connection: SQLiteConnection, schema: SyncSchema) {
    self.db = connection
    self.schema = schema
    self.outbox = Outbox(db: connection)
    self.metadata = Metadata(db: connection)
    self.systemFields = SystemFieldsStore(db: connection)
  }

  public func attach(_ transport: CloudTransport) {
    lock.withLock {
      self.transport = transport
      inflight = [:]
    }
    transport.delegate = self
  }

  public func savedTransportState() throws -> Data? {
    try metadata.value(Self.stateKey).flatMap { Data(base64Encoded: $0) }
  }

  public func pendingCount() throws -> Int {
    try outbox.count()
  }

  public func enqueuePendingChanges() throws {
    let changes: [PendingChange] = try lock.withLock {
      try outbox.entries().map { entry in
        switch entry.operation {
        case .upsert:
          return .save(entry.id)
        case .delete:
          inflight[entry.id] = entry.version
          return .delete(entry.id)
        }
      }
    }
    transport?.add(changes)
  }

  public func sync() async throws {
    guard let transport else { return }
    try await transport.fetchChanges()
    try enqueuePendingChanges()
    try await transport.sendChanges()
  }

  public func handleAccountChange(_ change: AccountChange) throws -> AccountAction {
    try lock.withLock {
      switch change {
      case .signOut:
        return .pause
      case .signIn(let userID):
        let previous = try metadata.value(Self.accountKey)
        try metadata.set(Self.accountKey, userID)
        if previous == nil || previous == userID { return .resume }
        try resetSyncState()
        return .resetAndReupload
      case .switchAccounts(let userID):
        try metadata.set(Self.accountKey, userID)
        try resetSyncState()
        return .resetAndReupload
      }
    }
  }

  public func resetSyncState() throws {
    try lock.withLock {
      try db.transaction {
        for statement in schema.resetSql {
          try db.execute(statement)
        }
        try metadata.set(Self.stateKey, nil)
      }
      inflight = [:]
      lastError = nil
    }
  }

  public func record(for id: RecordID) -> SyncRecord? {
    lock.withLock {
      do {
        guard
          let table = schema.table(named: id.table),
          let entry = try outbox.entry(for: id), entry.operation == .upsert,
          let row = try applier.row(for: id, in: table)
        else { return nil }
        inflight[id] = entry.version
        return RecordCodec.record(id: id, row: row, table: table, systemFields: try systemFields.get(id))
      } catch {
        lastError = "\(error)"
        return nil
      }
    }
  }

  public func transport(didFetchSaves saves: [SyncRecord], deletes: [RecordID]) throws {
    var changed = Set<String>()
    let requeue: [PendingChange] = try lock.withLock {
      try applying {
        var requeue: [PendingChange] = []
        for record in saves {
          switch try applier.applySave(record) {
          case .applied: changed.insert(record.id.table)
          case .keptLocal(let change): requeue.append(change)
          case .ignored: break
          }
        }
        for id in deletes where try applier.applyDelete(id) {
          changed.insert(id.table)
        }
        return requeue
      }
    }
    transport?.add(requeue)
    notify(changed)
  }

  public func transport(didSend result: SendResult) throws -> [PendingChange] {
    var changed = Set<String>()
    let requeue: [PendingChange] = try lock.withLock {
      try applying {
        for record in result.saved {
          try systemFields.set(record.id, record.systemFields)
          try confirm(record.id)
        }
        for id in result.deleted {
          try systemFields.remove(id)
          try confirm(id)
        }
        var requeue: [PendingChange] = []
        for failed in result.failed {
          if let change = try handle(failed, changed: &changed) {
            requeue.append(change)
          }
        }
        return requeue
      }
    }
    notify(changed)
    return requeue
  }

  public func transport(didUpdateState state: Data) {
    lock.withLock {
      do {
        try metadata.set(Self.stateKey, state.base64EncodedString())
      } catch {
        lastError = "\(error)"
      }
    }
  }

  private var applier: Applier {
    Applier(db: db, schema: schema, outbox: outbox, systemFields: systemFields)
  }

  private func handle(_ failed: FailedChange, changed: inout Set<String>) throws -> PendingChange? {
    let id = failed.change.id
    switch (failed.change, failed.failure) {
    case (.save, .serverRecordChanged(let server)):
      inflight[id] = nil
      switch try applier.applySave(server) {
      case .applied:
        changed.insert(id.table)
        return nil
      case .keptLocal(let change):
        return change
      case .ignored:
        return nil
      }
    case (.save, .zoneNotFound):
      inflight[id] = nil
      try systemFields.removeAll()
      return failed.change
    case (.save, .unknownItem):
      inflight[id] = nil
      try systemFields.remove(id)
      return nil
    case (.delete, .unknownItem), (.delete, .zoneNotFound):
      try systemFields.remove(id)
      try confirm(id)
      return nil
    case (_, .quotaExceeded):
      inflight[id] = nil
      lastError = "quotaExceeded"
      return nil
    case (_, .rejected(let message)):
      inflight[id] = nil
      lastError = message
      return nil
    case (_, .retryLater), (.delete, .serverRecordChanged):
      return nil
    }
  }

  private func confirm(_ id: RecordID) throws {
    guard let version = inflight.removeValue(forKey: id) else { return }
    try outbox.remove(id, version: version)
  }

  private func applying<T>(_ body: () throws -> T) throws -> T {
    try db.transaction {
      try db.execute("UPDATE _sync_meta SET value = '1' WHERE key = 'applying'")
      let result = try body()
      try db.execute("UPDATE _sync_meta SET value = '0' WHERE key = 'applying'")
      return result
    }
  }

  private func notify(_ tables: Set<String>) {
    guard !tables.isEmpty else { return }
    onTablesChanged?(tables)
  }
}
