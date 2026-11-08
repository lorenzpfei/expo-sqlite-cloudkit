import Foundation

public enum PendingChange: Hashable, Sendable {
  case save(RecordID)
  case delete(RecordID)

  public var id: RecordID {
    switch self {
    case .save(let id), .delete(let id): return id
    }
  }
}

public enum SendFailure: Equatable, Sendable {
  case serverRecordChanged(SyncRecord)
  case zoneNotFound
  case unknownItem
  case quotaExceeded
  case retryLater
  case rejected(String)
}

public struct FailedChange: Equatable, Sendable {
  public var change: PendingChange
  public var failure: SendFailure

  public init(change: PendingChange, failure: SendFailure) {
    self.change = change
    self.failure = failure
  }
}

public struct SendResult: Equatable, Sendable {
  public var saved: [SyncRecord]
  public var deleted: [RecordID]
  public var failed: [FailedChange]

  public init(saved: [SyncRecord] = [], deleted: [RecordID] = [], failed: [FailedChange] = []) {
    self.saved = saved
    self.deleted = deleted
    self.failed = failed
  }
}

public enum AccountChange: Equatable, Sendable {
  case signIn(userID: String)
  case signOut
  case switchAccounts(userID: String)
}

public enum AccountAction: Equatable, Sendable {
  case resume
  case pause
  case resetAndReupload
}

public protocol CloudTransport: AnyObject {
  var delegate: CloudTransportDelegate? { get set }
  func add(_ changes: [PendingChange])
  func fetchChanges() async throws
  func sendChanges() async throws
}

public protocol CloudTransportDelegate: AnyObject {
  func record(for id: RecordID) -> SyncRecord?
  func transport(didFetchSaves saves: [SyncRecord], deletes: [RecordID]) throws
  func transport(didSend result: SendResult) throws -> [PendingChange]
  func transport(didUpdateState state: Data)
}
