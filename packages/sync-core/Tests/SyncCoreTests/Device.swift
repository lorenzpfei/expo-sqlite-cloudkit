import Foundation
import SyncCore
import SystemSQLite
import XCTest

struct Fixture: Decodable {
  let ddl: [String]
  let schema: SyncSchema

  static func load(_ name: String) throws -> Fixture {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
}

final class Device {
  let name: String
  let path: String
  let fixture: Fixture
  let server: InMemoryServer
  private(set) var db: SQLiteConnection
  private(set) var coordinator: SyncCoordinator
  private(set) var transport: InMemoryTransport
  private(set) var changedTables: [Set<String>] = []

  init(_ name: String, fixture: Fixture, server: InMemoryServer, seed: [String] = []) throws {
    self.name = name
    self.fixture = fixture
    self.server = server
    path = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-core-\(name)-\(UUID().uuidString).sqlite").path
    let db = try SQLiteConnection(path: path, api: .system)
    for statement in fixture.ddl + seed {
      try db.execute(statement)
    }
    try db.transaction {
      for statement in fixture.schema.installSql {
        try db.execute(statement)
      }
    }
    self.db = db
    (coordinator, transport) = try Self.connect(db: db, schema: fixture.schema, server: server)
    observe()
  }

  deinit {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: path + suffix)
    }
  }

  func restart() throws {
    db = try SQLiteConnection(path: path, api: .system)
    (coordinator, transport) = try Self.connect(db: db, schema: fixture.schema, server: server)
    observe()
  }

  func switchServer(to server: InMemoryServer) throws {
    let transport = InMemoryTransport(server: server, state: try coordinator.savedTransportState())
    coordinator.attach(transport)
    self.transport = transport
  }

  func sync() async throws {
    try await coordinator.sync()
  }

  func exec(_ sql: String, _ parameters: [SyncValue] = []) throws {
    try db.execute(sql, parameters)
  }

  func rows(_ sql: String) throws -> [Row] {
    try db.query(sql)
  }

  func outboxCount() throws -> Int {
    try coordinator.pendingCount()
  }

  private func observe() {
    coordinator.onTablesChanged = { [weak self] tables in self?.changedTables.append(tables) }
  }

  private static func connect(db: SQLiteConnection, schema: SyncSchema, server: InMemoryServer) throws -> (SyncCoordinator, InMemoryTransport) {
    let coordinator = SyncCoordinator(connection: db, schema: schema)
    let transport = InMemoryTransport(server: server, state: try coordinator.savedTransportState())
    coordinator.attach(transport)
    return (coordinator, transport)
  }
}

func syncAll(_ devices: Device...) async throws {
  for _ in 0..<2 {
    for device in devices {
      try await device.sync()
    }
  }
}
