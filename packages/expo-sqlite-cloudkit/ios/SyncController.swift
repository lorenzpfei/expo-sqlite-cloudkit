import CloudKit
import Foundation

@available(iOS 17.0, *)
final class SyncController: @unchecked Sendable {
  let container: CKContainer
  var onChange: (([String]) -> Void)?
  var onStatus: (([String: Any]) -> Void)?

  private let db: SQLiteConnection
  private let coordinator: SyncCoordinator
  private var transport: CloudKitTransport!
  private let lock = NSLock()
  private var account = "unknown"
  private var paused = false
  private var manualSync = false
  private var fetching = false
  private var sending = false
  private var lastSyncAt: Date?
  private var lastError: String?
  private var pollTask: Task<Void, Never>?

  init(databasePath: String, containerIdentifier: String, schema: SyncSchema) throws {
    container = CKContainer(identifier: containerIdentifier)
    db = try SQLiteConnection(path: databasePath, api: .expoSQLite)
    coordinator = SyncCoordinator(connection: db, schema: schema)
    coordinator.onTablesChanged = { [weak self] tables in
      self?.onChange?(tables.sorted())
    }
    try connect(state: coordinator.savedTransportState())
    startPolling()
  }

  deinit {
    pollTask?.cancel()
  }

  func stop() {
    pollTask?.cancel()
  }

  func refreshAccountStatus() async -> String {
    let status: String
    do {
      status = Self.name(of: try await container.accountStatus())
    } catch {
      status = "couldNotDetermine"
    }
    lock.withLock { account = status }
    emitStatus()
    return status
  }

  func syncNow() async throws {
    guard !lock.withLock({ paused }) else { return }
    setManualSync(true)
    defer { setManualSync(false) }
    do {
      try await coordinator.sync()
      lock.withLock {
        lastSyncAt = Date()
        lastError = nil
      }
    } catch {
      lock.withLock { lastError = "\(error)" }
      emitStatus()
      throw error
    }
  }

  func reset() throws {
    try coordinator.resetSyncState()
    try connect(state: nil)
    emitStatus()
  }

  func status() -> [String: Any] {
    let pending = (try? coordinator.pendingCount()) ?? 0
    return lock.withLock {
      [
        "configured": true,
        "account": account,
        "syncing": manualSync || fetching || sending,
        "pendingChanges": pending,
        "lastSyncAt": lastSyncAt.map { $0.timeIntervalSince1970 * 1000 as Any } ?? NSNull(),
        "lastError": (lastError ?? coordinator.lastError).map { $0 as Any } ?? NSNull(),
      ]
    }
  }

  private func connect(state: Data?) throws {
    let transport = CloudKitTransport(database: container.privateCloudDatabase, state: state)
    transport.onAccountChange = { [weak self] change in self?.handleAccountChange(change) }
    transport.onZoneDeleted = { [weak self] in self?.handleZoneDeleted() }
    transport.onActivity = { [weak self] activity, active in self?.handleActivity(activity, active) }
    transport.onFetchCompleted = { [weak self] in try? self?.coordinator.enqueuePendingChanges() }
    transport.onError = { [weak self] error in
      self?.lock.withLock { self?.lastError = "\(error)" }
      self?.emitStatus()
    }
    coordinator.attach(transport)
    self.transport = transport
    try coordinator.enqueuePendingChanges()
  }

  private func handleAccountChange(_ change: AccountChange) {
    Task {
      do {
        switch try coordinator.handleAccountChange(change) {
        case .pause:
          lock.withLock { paused = true }
        case .resume:
          lock.withLock { paused = false }
          try coordinator.enqueuePendingChanges()
        case .resetAndReupload:
          lock.withLock { paused = false }
          try connect(state: nil)
        }
      } catch {
        lock.withLock { lastError = "\(error)" }
      }
      _ = await refreshAccountStatus()
    }
  }

  private func handleZoneDeleted() {
    Task {
      do {
        try reset()
      } catch {
        lock.withLock { lastError = "\(error)" }
        emitStatus()
      }
    }
  }

  private func handleActivity(_ activity: CloudKitTransport.Activity, _ active: Bool) {
    lock.withLock {
      switch activity {
      case .fetch: fetching = active
      case .send: sending = active
      }
      if !active { lastSyncAt = Date() }
    }
    emitStatus()
  }

  private func setManualSync(_ active: Bool) {
    lock.withLock { manualSync = active }
    emitStatus()
  }

  private func emitStatus() {
    onStatus?(status())
  }

  private func startPolling() {
    pollTask = Task { [weak self] in
      var lastVersion: SyncValue?
      while !Task.isCancelled {
        if let self, let version = try? self.db.query("PRAGMA data_version").first?["data_version"] {
          if lastVersion != nil, version != lastVersion, !self.lock.withLock({ self.paused }) {
            try? self.coordinator.enqueuePendingChanges()
            self.emitStatus()
          }
          lastVersion = version
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
  }

  private static func name(of status: CKAccountStatus) -> String {
    switch status {
    case .available: return "available"
    case .noAccount: return "noAccount"
    case .restricted: return "restricted"
    case .temporarilyUnavailable: return "temporarilyUnavailable"
    default: return "couldNotDetermine"
    }
  }
}
