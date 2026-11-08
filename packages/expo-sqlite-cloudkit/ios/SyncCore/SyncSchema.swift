import Foundation

public struct SyncSchema: Codable, Sendable {
  public var version: String
  public var tables: [SyncTable]
  public var installSql: [String]
  public var resetSql: [String]

  public func table(named name: String) -> SyncTable? {
    tables.first { $0.name == name }
  }
}

public struct SyncTable: Codable, Sendable, Equatable {
  public var name: String
  public var primaryKey: [String]
  public var updatedAtColumn: String
  public var deletedAtColumn: String?
  public var encryptedColumns: EncryptedColumns
}

public enum EncryptedColumns: Codable, Sendable, Equatable {
  case all
  case some([String])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self), value == "all" {
      self = .all
    } else {
      self = .some(try container.decode([String].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .all: try container.encode("all")
    case .some(let columns): try container.encode(columns)
    }
  }

  public func contains(_ column: String) -> Bool {
    switch self {
    case .all: return true
    case .some(let columns): return columns.contains(column)
    }
  }
}
