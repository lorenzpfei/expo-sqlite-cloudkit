import Foundation

public final class InMemoryServer: @unchecked Sendable {
  public var batchLimit = 400
  public var failSavesAfter: Int?
  public var beforeModify: (() -> Void)?

  private struct Stored {
    var record: SyncRecord
    var tag: Int
    var sequence: Int
  }

  private let lock = NSRecursiveLock()
  private var records: [String: Stored] = [:]
  private var tombstones: [String: (id: RecordID, sequence: Int)] = [:]
  private var sequence = 0
  private var nextTag = 0

  public init() {}

  public var allRecords: [SyncRecord] {
    lock.withLock { records.values.map(\.record).sorted { $0.id.recordName < $1.id.recordName } }
  }

  public func modify(saves: [SyncRecord], deletes: [RecordID]) -> SendResult {
    beforeModify?()
    return lock.withLock {
      var result = SendResult()
      for (index, record) in saves.enumerated() {
        let name = record.id.recordName
        if let limit = failSavesAfter, index >= limit {
          result.failed.append(FailedChange(change: .save(record.id), failure: .retryLater))
          continue
        }
        let clientTag = record.systemFields.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        if let existing = records[name], existing.tag != clientTag {
          var server = existing.record
          server.systemFields = Self.encode(existing.tag)
          result.failed.append(FailedChange(change: .save(record.id), failure: .serverRecordChanged(server)))
          continue
        }
        if records[name] == nil, clientTag != nil {
          result.failed.append(FailedChange(change: .save(record.id), failure: .unknownItem))
          continue
        }
        nextTag += 1
        sequence += 1
        var stored = record
        stored.systemFields = nil
        records[name] = Stored(record: stored, tag: nextTag, sequence: sequence)
        tombstones[name] = nil
        stored.systemFields = Self.encode(nextTag)
        result.saved.append(stored)
      }
      failSavesAfter = nil
      for id in deletes {
        sequence += 1
        records[id.recordName] = nil
        tombstones[id.recordName] = (id, sequence)
        result.deleted.append(id)
      }
      return result
    }
  }

  public func changes(since token: Int, limit: Int) -> (saves: [SyncRecord], deletes: [RecordID], token: Int, moreComing: Bool) {
    lock.withLock {
      enum Change {
        case save(SyncRecord)
        case delete(RecordID)
      }
      var changes: [(sequence: Int, change: Change)] = records.values.filter { $0.sequence > token }.map {
        var record = $0.record
        record.systemFields = Self.encode($0.tag)
        return ($0.sequence, .save(record))
      }
      changes += tombstones.values.filter { $0.sequence > token }.map { ($0.sequence, .delete($0.id)) }
      changes.sort { $0.sequence < $1.sequence }
      let page = changes.prefix(limit)
      var saves: [SyncRecord] = []
      var deletes: [RecordID] = []
      for item in page {
        switch item.change {
        case .save(let record): saves.append(record)
        case .delete(let id): deletes.append(id)
        }
      }
      return (saves, deletes, page.last?.sequence ?? token, changes.count > page.count)
    }
  }

  private static func encode(_ tag: Int) -> Data {
    Data(String(tag).utf8)
  }
}

public enum InMemoryTransportError: Error, Equatable {
  case offline
  case retryLater
}

public final class InMemoryTransport: CloudTransport, @unchecked Sendable {
  public weak var delegate: CloudTransportDelegate?
  public var isOnline = true
  public private(set) var pending: [PendingChange] = []

  private struct State: Codable {
    var token: Int
    var pending: [Pending]
  }

  private struct Pending: Codable {
    var delete: Bool
    var id: RecordID
  }

  private let server: InMemoryServer
  private var token = 0

  public init(server: InMemoryServer, state: Data?) {
    self.server = server
    if let state, let decoded = try? JSONDecoder().decode(State.self, from: state) {
      token = decoded.token
      pending = decoded.pending.map { $0.delete ? .delete($0.id) : .save($0.id) }
    }
  }

  public func add(_ changes: [PendingChange]) {
    var known = Set(pending)
    for change in changes where known.insert(change).inserted {
      pending.append(change)
    }
    persist()
  }

  public func fetchChanges() async throws {
    guard isOnline else { throw InMemoryTransportError.offline }
    var moreComing = true
    while moreComing {
      let page = server.changes(since: token, limit: server.batchLimit)
      try delegate?.transport(didFetchSaves: page.saves, deletes: page.deletes)
      token = page.token
      moreComing = page.moreComing
      persist()
    }
  }

  public func sendChanges() async throws {
    guard isOnline else { throw InMemoryTransportError.offline }
    while !pending.isEmpty {
      let batch = Array(pending.prefix(server.batchLimit))
      pending.removeFirst(batch.count)
      var saves: [SyncRecord] = []
      var deletes: [RecordID] = []
      for change in batch {
        switch change {
        case .save(let id):
          if let record = delegate?.record(for: id) { saves.append(record) }
        case .delete(let id):
          deletes.append(id)
        }
      }
      let result = server.modify(saves: saves, deletes: deletes)
      let retry = result.failed.filter { $0.failure == .retryLater }.map(\.change)
      pending.insert(contentsOf: retry, at: 0)
      add(try delegate?.transport(didSend: result) ?? [])
      if !retry.isEmpty { throw InMemoryTransportError.retryLater }
    }
  }

  private func persist() {
    let state = State(
      token: token,
      pending: pending.map { change in
        switch change {
        case .save(let id): return Pending(delete: false, id: id)
        case .delete(let id): return Pending(delete: true, id: id)
        }
      })
    if let data = try? JSONEncoder().encode(state) {
      delegate?.transport(didUpdateState: data)
    }
  }
}
