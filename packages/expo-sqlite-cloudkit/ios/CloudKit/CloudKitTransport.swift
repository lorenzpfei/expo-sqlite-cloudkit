#if canImport(CloudKit)
import CloudKit
import OSLog
#if canImport(SyncCore)
import SyncCore

#endif

@available(iOS 17.0, macOS 14.0, *)
public final class CloudKitTransport: CloudTransport, CKSyncEngineDelegate, @unchecked Sendable {
  public enum Activity: Sendable {
    case fetch
    case send
  }

  public weak var delegate: CloudTransportDelegate?
  public var onAccountChange: ((AccountChange) -> Void)?
  public var onZoneDeleted: (() -> Void)?
  public var onActivity: ((Activity, Bool) -> Void)?
  public var onFetchCompleted: (() -> Void)?
  public var onError: ((Error) -> Void)?

  private let zoneID: CKRecordZone.ID
  private let database: CKDatabase
  private var engine: CKSyncEngine!
  private var persisted: SavedState
  private let stateLock = NSLock()
  private let log = Logger(subsystem: "expo-sqlite-cloudkit", category: "engine")
  private let instance = String(UUID().uuidString.prefix(8))

  public init(database: CKDatabase, state: Data?, zoneID: CKRecordZone.ID = CloudKitRecordMapper.zoneID) {
    self.zoneID = zoneID
    self.database = database
    persisted = state.flatMap(SavedState.decode) ?? SavedState()
    let serialization = persisted.engine
    engine = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: self))
    if serialization == nil {
      engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }
    log.info("[\(self.instance, privacy: .public)] engine created, restored state: \(serialization != nil)")
  }

  deinit {
    log.info("[\(self.instance, privacy: .public)] engine released")
  }

  public func add(_ changes: [PendingChange]) {
    let existing = Set(engine.state.pendingRecordZoneChanges)
    let new = changes.map(pendingRecordZoneChange).filter { !existing.contains($0) }
    if !new.isEmpty {
      engine.state.add(pendingRecordZoneChanges: new)
      log.info("[\(self.instance, privacy: .public)] queued \(new.count) changes, \(self.engine.state.pendingRecordZoneChanges.count) pending")
    }
  }

  public func fetchChanges() async throws {
    log.info("[\(self.instance, privacy: .public)] fetchChanges started")
    do {
      try await engine.fetchChanges()
      try await fetchZoneChanges()
      log.info("[\(self.instance, privacy: .public)] fetchChanges finished")
    } catch {
      log.error("[\(self.instance, privacy: .public)] fetchChanges failed: \(String(describing: error), privacy: .public)")
      throw error
    }
  }

  private func fetchZoneChanges() async throws {
    var token = stateLock.withLock { persisted.zoneChangeToken }.flatMap(Self.decodeToken)
    var moreComing = true
    while moreComing {
      do {
        let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
        let saves = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
          .compactMap(CloudKitRecordMapper.syncRecord)
        let deletes = changes.deletions.compactMap { RecordID(recordName: $0.recordID.recordName) }
        log.info("[\(self.instance, privacy: .public)] zone fetch modified=\(saves.count) deleted=\(deletes.count)")
        try delegate?.transport(didFetchSaves: saves, deletes: deletes)
        token = changes.changeToken
        stateLock.withLock { persisted.zoneChangeToken = Self.encodeToken(changes.changeToken) }
        persist()
        moreComing = changes.moreComing
      } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
        token = nil
      } catch let error as CKError where error.code == .zoneNotFound {
        return
      }
    }
  }

  public func sendChanges() async throws {
    log.info("[\(self.instance, privacy: .public)] sendChanges started")
    do {
      try await engine.sendChanges()
      log.info("[\(self.instance, privacy: .public)] sendChanges finished")
    } catch where CloudKitErrorPolicy.isReportedPerRecord(error) {
      log.info("[\(self.instance, privacy: .public)] sendChanges finished with per-record failures")
    } catch {
      log.error("[\(self.instance, privacy: .public)] sendChanges failed: \(String(describing: error), privacy: .public)")
      throw error
    }
  }

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    log.info("[\(self.instance, privacy: .public)] event \(Self.describe(event), privacy: .public)")
    switch event {
    case .stateUpdate(let update):
      stateLock.withLock { persisted.engine = update.stateSerialization }
      persist()
    case .accountChange(let change):
      switch change.changeType {
      case .signIn(let currentUser):
        onAccountChange?(.signIn(userID: currentUser.recordName))
      case .switchAccounts(_, let currentUser):
        onAccountChange?(.switchAccounts(userID: currentUser.recordName))
      case .signOut:
        onAccountChange?(.signOut)
      @unknown default:
        break
      }
    case .fetchedDatabaseChanges(let changes):
      if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
        onZoneDeleted?()
      }
    case .fetchedRecordZoneChanges(let changes):
      let saves = changes.modifications.compactMap { CloudKitRecordMapper.syncRecord($0.record) }
      let deletes = changes.deletions.compactMap { RecordID(recordName: $0.recordID.recordName) }
      do {
        try delegate?.transport(didFetchSaves: saves, deletes: deletes)
      } catch {
        onError?(error)
      }
    case .sentRecordZoneChanges(let sent):
      handleSent(sent)
    case .sentDatabaseChanges(let sent):
      for failure in sent.failedZoneSaves {
        onError?(failure.error)
      }
    case .willFetchChanges:
      onActivity?(.fetch, true)
    case .willSendChanges:
      onActivity?(.send, true)
    case .didFetchChanges:
      onActivity?(.fetch, false)
      onFetchCompleted?()
    case .didSendChanges:
      onActivity?(.send, false)
    default:
      break
    }
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
      guard let self, let id = RecordID(recordName: recordID.recordName), let record = self.delegate?.record(for: id) else {
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
      }
      return CloudKitRecordMapper.record(record, zoneID: self.zoneID)
    }
  }

  private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
    var result = SendResult()
    result.saved = sent.savedRecords.compactMap(CloudKitRecordMapper.syncRecord)
    result.deleted = sent.deletedRecordIDs.compactMap { RecordID(recordName: $0.recordName) }
    for failed in sent.failedRecordSaves {
      guard let id = RecordID(recordName: failed.record.recordID.recordName) else { continue }
      result.failed.append(FailedChange(change: .save(id), failure: CloudKitErrorPolicy.failure(for: failed.error)))
    }
    for (recordID, error) in sent.failedRecordDeletes {
      guard let id = RecordID(recordName: recordID.recordName) else { continue }
      result.failed.append(FailedChange(change: .delete(id), failure: CloudKitErrorPolicy.failure(for: error)))
    }

    if result.failed.contains(where: { $0.failure == .zoneNotFound }) {
      engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }
    let retry = result.failed.filter { $0.failure == .retryLater }.map(\.change)
    do {
      add(try (delegate?.transport(didSend: result) ?? []) + retry)
    } catch {
      onError?(error)
    }
  }

  private struct SavedState: Codable {
    var engine: CKSyncEngine.State.Serialization?
    var zoneChangeToken: Data?

    static func decode(_ data: Data) -> SavedState? {
      let decoder = JSONDecoder()
      if let state = try? decoder.decode(SavedState.self, from: data), state.engine != nil || state.zoneChangeToken != nil {
        return state
      }
      return (try? decoder.decode(CKSyncEngine.State.Serialization.self, from: data)).map { SavedState(engine: $0) }
    }
  }

  private func persist() {
    if let data = stateLock.withLock({ try? JSONEncoder().encode(persisted) }) {
      delegate?.transport(didUpdateState: data)
    }
  }

  private static func encodeToken(_ token: CKServerChangeToken) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
  }

  private static func decodeToken(_ data: Data) -> CKServerChangeToken? {
    try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
  }

  private static func describe(_ event: CKSyncEngine.Event) -> String {
    switch event {
    case .stateUpdate: return "stateUpdate"
    case .accountChange(let change): return "accountChange \(change.changeType)"
    case .fetchedDatabaseChanges(let changes):
      return "fetchedDatabaseChanges modified=\(changes.modifications.count) deleted=\(changes.deletions.count)"
    case .fetchedRecordZoneChanges(let changes):
      return "fetchedRecordZoneChanges modified=\(changes.modifications.count) deleted=\(changes.deletions.count)"
    case .sentDatabaseChanges(let sent):
      return "sentDatabaseChanges saved=\(sent.savedZones.count) failed=\(sent.failedZoneSaves.map { $0.error.code.rawValue })"
    case .sentRecordZoneChanges(let sent):
      return "sentRecordZoneChanges saved=\(sent.savedRecords.count) deleted=\(sent.deletedRecordIDs.count) failed=\(sent.failedRecordSaves.map { $0.error.code.rawValue }) failedDeletes=\(sent.failedRecordDeletes.values.map { $0.code.rawValue })"
    default: return "\(event)"
    }
  }

  private func pendingRecordZoneChange(_ change: PendingChange) -> CKSyncEngine.PendingRecordZoneChange {
    switch change {
    case .save(let id): return .saveRecord(CloudKitRecordMapper.recordID(id, zoneID: zoneID))
    case .delete(let id): return .deleteRecord(CloudKitRecordMapper.recordID(id, zoneID: zoneID))
    }
  }
}

#endif
